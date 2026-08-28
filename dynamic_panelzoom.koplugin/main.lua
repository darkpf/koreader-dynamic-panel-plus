local Device = require("device")
local Event = require("ui/event")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PanelViewer = require("panel_viewer")
local PanelDetect = require("panel_detect")
local _ = require("gettext")
local logger = require("logger")

-- Long side of the downscaled render used for panel analysis.
-- Keep in sync with ANALYSIS_PX in test/run_tests.py.
local ANALYSIS_TARGET_PX = 1300
local BASIC_BOUNDS_TARGET_PX = 640
local PANEL_CLEAR_REFRESH_MODE = "flashui"
local PANEL_DRAW_REFRESH_MODE = "ui"
local PANEL_CLEAR_EPDC_SLEEP_US = 0
local PANEL_CLEAR_LUMA = 128
local PANEL_FORCE_DRAW_REPAINT = false
local PANEL_DIRECT_CLEAR = true
local PANEL_FULL_SCREEN_TRANSITION = true
-- A single native full refresh paints the final panel through KOReader's
-- normal widget pipeline. It keeps the strong ghost-cleaning waveform while
-- avoiding the old blocking gray flash followed by a second color update.
local PANEL_SINGLE_FULL_DRAW = true
local PANEL_SINGLE_REFRESH_MODE = "full"
-- Start lookahead while the current e-ink transition is still settling, so
-- the next panel is normally ready before the reader taps again. The preload
-- remains cancellable and identity-checked.
local PANEL_PRELOAD_IDLE_DELAY = 0.20
local PANEL_CHAINED_PRELOAD_DELAY = 0.10
-- Keep the legacy key so existing users retain their enabled/disabled choice
-- when the mode moves from three to four detail views.
local BASIC_THREE_PANEL_SETTING = "advanced_panel_zoom_basic_three_panel_mode"

local READER_DEFAULTS = {
    rotation_mode = Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE,
    trim_page = 3, -- Page crop: none
    zoom_mode = "page", -- Page fit: full
    zoom_mode_genus = 4, -- page
    zoom_mode_type = 2, -- full
    page_scroll = 0, -- View mode: page
    contrast = 2.0,
    dithering = 1,
}

local PanelZoomIntegration = WidgetContainer:extend{
    name = "dynamic_panelzoom",
    integration_mode = false,
    current_panels = {},
    current_panel_index = 1,
    last_page_seen = -1,
    tap_navigation_enabled = true,
    tap_zones = { left = 0.3, right = 0.7 },
    _panel_cache = {}, -- Cache JSON per document
    _preloaded_image = nil, -- Pre-rendered next panel
    _preloaded_panel_index = nil, -- Index of preloaded panel
    _preloaded_panel_screen_rect = nil,
    _preloaded_key = nil,
    _preload_action = nil,
    _preload_generation = 0,
    _panel_layout_generation = 0,
    _is_switching = false, -- Debounce guard to prevent fast tap issues
    _is_changing_page = false, -- True while a page change is in progress
    _page_change_diff = nil, -- Direction of current page change (+1 or -1)
    _original_panel_zoom_handler = nil, -- Store original panel zoom handler
    _original_ocr_handler = nil, -- Store original OCR handler
    _original_ocr_menu_enabled = nil, -- Store original OCR menu state
    _original_genPanelZoomMenu = nil, -- Store original panel zoom menu function
    _original_highlight_addToMainMenu = nil, -- Store original KOReader menu inserter
    _json_available = false, -- Track if JSON is available for current document
    reading_direction_override = nil, -- User override for reading direction (rtl/ltr)
    zoom_margin_percent = 0.02, -- Default 2% extra margin for the free zoom mode
    standard_margin_percent = 0.0, -- Default 0% extra margin for standard panel-by-panel navigation
    show_adjacent_panels = true,   -- Show adjacent content (Smart Fill)
    -- Keep standard panel crops at the screen aspect. Lower values make the
    -- crop tighter, but they also leave visible bands because the rendered
    -- image no longer fills the screen.
    smart_fill_strength = 1.0,
    zoom_initial_scale = 2.0, -- Default 2.0x initial software scale for the free zoom mode
    panelzoom_tap_forward_zone = "auto", -- auto, left, or right
    apply_koreader_defaults = true,
    plugin_enabled = true,
    hold_to_zoom_enabled = true,
    basic_three_panel_mode = false,
    single_giant_detail_enabled = true,
    single_giant_detail_count = 4,
    single_giant_detail_min_area = 0.55,
    single_giant_detail_min_w = 0.70,
    single_giant_detail_min_h = 0.50,
}

function PanelZoomIntegration:init()
    self.current_panels = {}
    self._panel_cache = {}
    self._preload_generation = 0
    self._panel_layout_generation = 0
    self._preload_action = nil
    self._preloaded_key = nil
    -- Everything goes to crash.log (via KOReader's logger). We create NO
    -- separate log files: crash.log survives restarts, so dumped diagnostics
    -- cannot be lost, and there is a single file to hand over.
    --
    -- Debug output is opt-in. When enabled from the KOReader menu, both panel
    -- logs and embedded PGM dumps go to crash.log; no sidecar files are used.
    self.debug_log_panels = false
    self.dump_analysis_pgm = false
    if G_reader_settings and G_reader_settings.readSetting then
        self.basic_three_panel_mode = G_reader_settings:readSetting(
            BASIC_THREE_PANEL_SETTING, false) == true
    end

    -- ReaderReady is KOReader's real "document is loaded and rendered" event.
    self.onReaderReady = function()
        self:applyPreferredReaderDefaults()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Page change handler: event-driven panel transitions
    -- KOReader dispatches PageUpdate as: handler(self, new_page_no, orig_mode)
    -- When _is_changing_page is true, the event was triggered by our changePage()
    -- call to onGotoViewRel(), so we handle the panel transition.
    -- Otherwise it's a normal page change (user swipe, menu, etc.)
    self.onPageUpdate = function(_, new_page_no)
        if self._is_changing_page then
            self:_onPageChangeComplete(new_page_no)
        else
            self:cancelPanelPreload()
            self:applyPreferredReaderDefaults()
            self:checkAndIntegratePanelZoom()
        end
    end
    
    -- Optional: Re-render current panel if document settings change
    self.onSettingsUpdate = function()
        if self._current_imgviewer and self.integration_mode then
            logger.info("PanelZoom: Settings changed, refreshing current panel")
            self:cancelPanelPreload()
            self:displayCurrentPanel()
        end
    end
    
    -- Integrate with existing panel zoom menu
    self:setupPanelZoomMenuIntegration()
end

-- Get effective reading direction (override takes precedence over JSON)
function PanelZoomIntegration:getEffectiveReadingDirection()
    -- No longer use a non-existent JSON property. Default is ltr unless overridden.
    if self.reading_direction_override then
        return self.reading_direction_override
    end
    return "ltr"
end

local function saveSetting(settings, key, value)
    if settings and settings.saveSetting then
        settings:saveSetting(key, value)
    end
end

local function saveGlobalSetting(key, value)
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting(key, value)
    end
end

local function setGlobalBoolean(key, value)
    if not G_reader_settings then return end
    if value and G_reader_settings.makeTrue then
        G_reader_settings:makeTrue(key)
    elseif not value and G_reader_settings.makeFalse then
        G_reader_settings:makeFalse(key)
    else
        saveGlobalSetting(key, value)
    end
end

-- Apply the reader defaults this plugin is tuned for. These are KOReader's own
-- settings/events, not detector thresholds.
function PanelZoomIntegration:applyPreferredReaderDefaults()
    if not self.plugin_enabled then return end
    if not self.apply_koreader_defaults then return end
    if not self.ui or not self.ui.document or not self.ui.paging then return end

    local document = self.ui.document
    local doc_path = document.file or tostring(document)
    if self._reader_defaults_doc_path == doc_path then return end
    self._reader_defaults_doc_path = doc_path

    local cfg = document.configurable
    if not cfg then return end

    local d = READER_DEFAULTS
    local doc_settings = self.ui.doc_settings

    saveGlobalSetting("kopt_rotation_mode", d.rotation_mode)
    saveGlobalSetting("kopt_trim_page", d.trim_page)
    saveGlobalSetting("kopt_zoom_mode_genus", d.zoom_mode_genus)
    saveGlobalSetting("kopt_zoom_mode_type", d.zoom_mode_type)
    saveGlobalSetting("kopt_page_scroll", d.page_scroll)
    saveGlobalSetting("kopt_contrast", d.contrast)

    saveSetting(doc_settings, "kopt_rotation_mode", d.rotation_mode)
    saveSetting(doc_settings, "kopt_trim_page", d.trim_page)
    saveSetting(doc_settings, "zoom_mode", d.zoom_mode)
    saveSetting(doc_settings, "normal_zoom_mode", d.zoom_mode)
    saveSetting(doc_settings, "kopt_zoom_mode_genus", d.zoom_mode_genus)
    saveSetting(doc_settings, "kopt_zoom_mode_type", d.zoom_mode_type)
    saveSetting(doc_settings, "kopt_page_scroll", d.page_scroll)
    saveSetting(doc_settings, "kopt_contrast", d.contrast)

    cfg.trim_page = d.trim_page
    cfg.zoom_mode_genus = d.zoom_mode_genus
    cfg.zoom_mode_type = d.zoom_mode_type
    cfg.page_scroll = d.page_scroll
    cfg.contrast = d.contrast

    if Device:hasEinkScreen() then
        if Device:canHWDither() then
            setGlobalBoolean("dev_no_hw_dither", false)
            setGlobalBoolean("dev_no_sw_dither", true)
            if not Screen.hw_dithering and Screen.toggleHWDithering then
                Screen:toggleHWDithering(true)
            end
            if Screen.sw_dithering and Screen.toggleSWDithering then
                Screen:toggleSWDithering(false)
            end
            saveGlobalSetting("kopt_hw_dithering", d.dithering)
            saveSetting(doc_settings, "kopt_hw_dithering", d.dithering)
            cfg.hw_dithering = d.dithering
            document.hw_dithering = true
            document.sw_dithering = false
        elseif Screen.fb_bpp == 8 then
            setGlobalBoolean("dev_no_sw_dither", false)
            if not Screen.sw_dithering and Screen.toggleSWDithering then
                Screen:toggleSWDithering(true)
            end
            saveGlobalSetting("kopt_sw_dithering", d.dithering)
            saveSetting(doc_settings, "kopt_sw_dithering", d.dithering)
            cfg.sw_dithering = d.dithering
            document.sw_dithering = true
        end
    end

    self.ui:handleEvent(Event:new("SetRotationMode", d.rotation_mode))
    self.ui:handleEvent(Event:new("SetScrollMode", false))
    self.ui:handleEvent(Event:new("SetZoomMode", d.zoom_mode))
    self.ui:handleEvent(Event:new("GammaUpdate", d.contrast, true))
    self.ui:handleEvent(Event:new("PageCrop", "none"))
    self.ui:handleEvent(Event:new("DitheringUpdate"))

    logger.info(string.format(
        "DynamicPanelZoom: Applied KOReader defaults rotation=%s crop=none fit=full view=page contrast=%.1f dithering=on",
        tostring(d.rotation_mode), d.contrast))
end

-- Check if document is compatible and integrate with Panel Zoom automatically
function PanelZoomIntegration:checkAndIntegratePanelZoom()
    if not self.ui.document then return end
    -- Page-based documents only (PDF/DjVu/CBZ...). Rolling documents (EPUB)
    -- have no panel geometry and must keep their normal hold behavior.
    if not self.ui.paging then return end

    local doc_path = self.ui.document.file
    if not doc_path then return end

    if not self.plugin_enabled then
        self._json_available = false
        logger.info("DynamicPanelZoom: Plugin disabled; keeping original panel zoom behavior")
        return
    end
    
    -- Dynamic Panel Zoom is always available, we just integrate it
    self._json_available = true -- we fake it to keep the integration flag happy
    self:integrateWithPanelZoom()
    logger.info("DynamicPanelZoom: Auto-integration enabled")
end

-- Integrate with built-in Panel Zoom
function PanelZoomIntegration:integrateWithPanelZoom()
    if not self.ui.highlight then return end
    
    -- Store the original handler if not already stored
    if not self._original_panel_zoom_handler then
        self._original_panel_zoom_handler = self.ui.highlight.onPanelZoom
    end
    
    -- Store the original panel zoom enabled state
    if self._original_panel_zoom_enabled == nil then
        self._original_panel_zoom_enabled = self.ui.highlight.panel_zoom_enabled
    end
    
    -- Override Panel Zoom to use our JSON when available
    self.ui.highlight.onPanelZoom = function(inst, arg, ges)
        return self:onIntegratedPanelZoom(arg, ges)
    end
    
    self.integration_mode = true
    if self.ui.highlight then self.ui.highlight.panel_zoom_enabled = true end
    
    -- Block OCR when Panel Zoom integration is active
    self:blockOCR()
end

-- Restore original Panel Zoom behavior
function PanelZoomIntegration:restoreOriginalPanelZoom()
    if not self.ui.highlight then return end
    
    -- Restore the original handler
    if self._original_panel_zoom_handler then
        self.ui.highlight.onPanelZoom = self._original_panel_zoom_handler
    else
        self.ui.highlight.onPanelZoom = nil
    end
    
    -- Restore the original panel zoom enabled state
    if self._original_panel_zoom_enabled ~= nil then
        self.ui.highlight.panel_zoom_enabled = self._original_panel_zoom_enabled
    end
    
    self.integration_mode = false
    
    -- Restore OCR when Panel Zoom integration is disabled
    self:restoreOCR()
    
    -- Restore original panel zoom menu
    self:restorePanelZoomMenu()
end

-- Block OCR functionality when Panel Zoom is active
function PanelZoomIntegration:blockOCR()
    -- Store original OCR handler if not already stored
    if not self._original_ocr_handler and self.ui.ocr then
        self._original_ocr_handler = self.ui.ocr.onOCRText
    end
    
    -- Disable OCR by replacing the handler with a no-op function
    if self.ui.ocr then
        self.ui.ocr.onOCRText = function()
            logger.info("DynamicPanelZoom: OCR blocked - Panel Zoom integration is active")
            return false
        end
        logger.info("DynamicPanelZoom: OCR functionality blocked")
    end
    
    -- Also disable OCR menu items if available
    if self.ui.menu and self.ui.menu.ocr_menu then
        self._original_ocr_menu_enabled = self.ui.menu.ocr_menu.enabled
        self.ui.menu.ocr_menu.enabled = false
        logger.info("DynamicPanelZoom: OCR menu items disabled")
    end
end

-- Restore OCR functionality when Panel Zoom is disabled
function PanelZoomIntegration:restoreOCR()
    -- Guard against multiple restoration calls
    if not self._original_ocr_handler and (self._original_ocr_menu_enabled == nil) then
        return -- Already restored or never stored
    end
    
    -- Restore original OCR handler
    if self.ui.ocr and self._original_ocr_handler then
        self.ui.ocr.onOCRText = self._original_ocr_handler
        self._original_ocr_handler = nil
        logger.info("DynamicPanelZoom: OCR functionality restored")
    end
    
    -- Restore OCR menu items
    if self.ui.menu and self.ui.menu.ocr_menu and self._original_ocr_menu_enabled ~= nil then
        self.ui.menu.ocr_menu.enabled = self._original_ocr_menu_enabled
        self._original_ocr_menu_enabled = nil
        logger.info("DynamicPanelZoom: OCR menu items restored")
    end
end

function PanelZoomIntegration:setDebugLogsEnabled(enabled)
    self.debug_log_panels = enabled
    self.dump_analysis_pgm = enabled
    logger.info("DynamicPanelZoom: Debug logs set to " .. tostring(enabled))
    self._panel_cache = {}
    self:replaceCurrentPanels({})
end

function PanelZoomIntegration:setPluginEnabled(enabled)
    self.plugin_enabled = enabled
    self._panel_cache = {}
    self:replaceCurrentPanels({})

    if enabled then
        logger.info("DynamicPanelZoom: Plugin activated")
        self:checkAndIntegratePanelZoom()
        return
    end

    logger.info("DynamicPanelZoom: Plugin deactivated")
    self._json_available = false
    self.integration_mode = false
    if self._current_imgviewer then
        self:closeViewer()
    end
    if self.ui and self.ui.highlight then
        if self._original_panel_zoom_handler then
            self.ui.highlight.onPanelZoom = self._original_panel_zoom_handler
        end
        if self._original_panel_zoom_enabled ~= nil then
            self.ui.highlight.panel_zoom_enabled = self._original_panel_zoom_enabled
        end
    end
    self:restoreOCR()
end

function PanelZoomIntegration:setBasicThreePanelMode(enabled)
    self.basic_three_panel_mode = enabled == true
    saveGlobalSetting(BASIC_THREE_PANEL_SETTING, self.basic_three_panel_mode)
    self._panel_cache = {}
    self:replaceCurrentPanels({})
    self.current_panel_index = 1

    logger.info("DynamicPanelZoom: Basic 4 Panels Mode set to "
        .. tostring(self.basic_three_panel_mode))

    if self._current_imgviewer and self.integration_mode then
        self:importToggleZoomPanels()
        self.current_panel_index = 1
        self:displayCurrentPanel()
    end
end

function PanelZoomIntegration:getFallbackToTextSelection()
    return self.ui and self.ui.highlight and self.ui.highlight.panel_zoom_fallback_to_text_selection
end

function PanelZoomIntegration:toggleFallbackToTextSelection()
    if not (self.ui and self.ui.highlight) then return end
    if self.ui.highlight.onToggleFallbackTextSelection then
        self.ui.highlight:onToggleFallbackTextSelection()
    else
        self.ui.highlight.panel_zoom_fallback_to_text_selection = not self.ui.highlight.panel_zoom_fallback_to_text_selection
    end
end

-- Callback methods for PanelViewer
-- Spatial navigation methods for PanelViewer
function PanelZoomIntegration:handleTapRight()
    if self._is_switching or self._is_changing_page then return end
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    local tap_forward_zone = self.panelzoom_tap_forward_zone or "auto"
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    logger.info(string.format("DynamicPanelZoom: handleTapRight index=%d, is_rtl=%s, reading_dir=%s", 
        self.current_panel_index, tostring(is_rtl), reading_dir))
    
    local intent_forward = false
    if tap_forward_zone == "right" then
        intent_forward = true
    elseif tap_forward_zone == "left" then
        intent_forward = false
    else
        intent_forward = not is_rtl
    end
    
    if intent_forward then
        -- Forward Flow
        -- Check preload first for Next
        if self:hasValidPreloadedPanel(self.current_panel_index + 1) then
            logger.info("PanelZoom: Using preloaded panel for instant switch (Forward)")
            self.current_panel_index = self.current_panel_index + 1
            if not self:displayPreloadedPanel() then self:displayCurrentPanel() end
            return
        end
        
        if self.current_panel_index < #self.current_panels then
            self.current_panel_index = self.current_panel_index + 1
            self:displayCurrentPanel()
        else
            -- End of page, go to next page
            logger.info("PanelZoom: End of page reached, jumping to next page")
            self:changePage(1)
        end
    else
        -- Backward Flow
        if self.current_panel_index > 1 then
            self.current_panel_index = self.current_panel_index - 1
            self:displayCurrentPanel()
        else
            -- Top of page reached, go to previous page
            logger.info("PanelZoom: Top of page reached, jumping to previous page")
            self:changePage(-1)
        end
    end
end

function PanelZoomIntegration:handleTapLeft()
    if self._is_switching or self._is_changing_page then return end
    self._is_switching = true
    UIManager:scheduleIn(0.3, function() self._is_switching = false end)
    
    local tap_forward_zone = self.panelzoom_tap_forward_zone or "auto"
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    logger.info(string.format("DynamicPanelZoom: handleTapLeft index=%d, is_rtl=%s, reading_dir=%s", 
        self.current_panel_index, tostring(is_rtl), reading_dir))
    
    local intent_forward = false
    if tap_forward_zone == "left" then
        intent_forward = true
    elseif tap_forward_zone == "right" then
        intent_forward = false
    else
        intent_forward = is_rtl
    end
    
    if intent_forward then
        -- Forward Flow
        -- Check preload first for Next
        if self:hasValidPreloadedPanel(self.current_panel_index + 1) then
            logger.info("PanelZoom: Using preloaded panel for instant switch (Forward)")
            self.current_panel_index = self.current_panel_index + 1
            if not self:displayPreloadedPanel() then self:displayCurrentPanel() end
            return
        end
        
        if self.current_panel_index < #self.current_panels then
            self.current_panel_index = self.current_panel_index + 1
            self:displayCurrentPanel()
        else
            -- End of page, go to next page
            logger.info("PanelZoom: End of page reached, jumping to next page")
            self:changePage(1)
        end
    else
        -- Backward Flow
        if self.current_panel_index > 1 then
            self.current_panel_index = self.current_panel_index - 1
            self:displayCurrentPanel()
        else
            -- Top of page reached, go to previous page
            logger.info("PanelZoom: Top of page reached, jumping to previous page")
            self:changePage(-1)
        end
    end
end

local function preloadKeysEqual(a, b)
    return a ~= nil and b ~= nil
        and a.doc_path == b.doc_path
        and a.page == b.page
        and a.layout_generation == b.layout_generation
        and a.reading_direction == b.reading_direction
        and a.basic_three_panel_mode == b.basic_three_panel_mode
        and a.standard_margin_percent == b.standard_margin_percent
        and a.show_adjacent_panels == b.show_adjacent_panels
        and a.panel_index == b.panel_index
        and a.viewer == b.viewer
end

function PanelZoomIntegration:makePanelPreloadKey(panel_index)
    if not self.ui or not self.ui.document or not self._current_imgviewer then return nil end
    return {
        doc_path = self.ui.document.file or tostring(self.ui.document),
        page = self:getSafePageNumber(),
        layout_generation = self._panel_layout_generation or 0,
        reading_direction = self:getEffectiveReadingDirection(),
        basic_three_panel_mode = self.basic_three_panel_mode == true,
        standard_margin_percent = self.standard_margin_percent or 0,
        show_adjacent_panels = self.show_adjacent_panels == true,
        panel_index = panel_index,
        viewer = self._current_imgviewer,
    }
end

function PanelZoomIntegration:preloadContextMatches(key)
    if not key or not self.plugin_enabled or not self.integration_mode then return false end
    local current = self:makePanelPreloadKey(key.panel_index)
    return preloadKeysEqual(key, current)
end

function PanelZoomIntegration:cancelPanelPreload()
    self._preload_generation = (self._preload_generation or 0) + 1
    if self._preload_action then
        UIManager:unschedule(self._preload_action)
        self._preload_action = nil
    end
    self:cleanupPreloadedImage()
end

function PanelZoomIntegration:replaceCurrentPanels(panels)
    self:cancelPanelPreload()
    self._panel_layout_generation = (self._panel_layout_generation or 0) + 1
    self.current_panels = panels or {}
end

function PanelZoomIntegration:hasValidPreloadedPanel(panel_index)
    if not self._preloaded_image then return false end
    local expected = self:makePanelPreloadKey(panel_index)
    if preloadKeysEqual(self._preloaded_key, expected) then return true end
    logger.info("DynamicPanelZoom: Discarding stale preloaded panel")
    self:cleanupPreloadedImage()
    return false
end

function PanelZoomIntegration:closeViewer()
    self:cancelPanelPreload()
    if self._current_imgviewer then
        -- Ensure E-Ink refresh suppression is restored if we were mid-page-change
        if UIManager.currently_scrolling then
            UIManager.currently_scrolling = false
        end
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
        -- Restore OCR when panel viewer is closed
        self:restoreOCR()
    end
    -- Always clear in-flight page-change state on exit so re-entering panel
    -- view on a new page can't inherit a stuck _is_changing_page from a
    -- prior session where onPageUpdate didn't fire.
    self._is_changing_page = false
    self._page_change_diff = nil
end

-- KOReader has no safe worker-thread API for document rendering. Delay the
-- one-panel lookahead until the reader has been idle, and make it cancellable.
function PanelZoomIntegration:scheduleNextPanelPreload(delay)
    local next_panel_index = self.current_panel_index + 1
    if next_panel_index > #self.current_panels then
        self:cancelPanelPreload()
        return
    end

    local key = self:makePanelPreloadKey(next_panel_index)
    if not key then
        self:cancelPanelPreload()
        return
    end
    if self._preloaded_image and preloadKeysEqual(self._preloaded_key, key) then return end

    if self._preload_action then
        UIManager:unschedule(self._preload_action)
        self._preload_action = nil
    end
    self._preload_generation = (self._preload_generation or 0) + 1
    self:cleanupPreloadedImage()
    local generation = self._preload_generation
    local action
    action = function()
        if self._preload_action == action then self._preload_action = nil end
        if generation ~= self._preload_generation
            or not self:preloadContextMatches(key)
            or self.current_panel_index + 1 ~= key.panel_index then
            return
        end
        self:preloadNextPanel(key)
    end
    self._preload_action = action
    UIManager:scheduleIn(delay or PANEL_PRELOAD_IDLE_DELAY, action)
end

function PanelZoomIntegration:preloadNextPanel(key)
    if not self:preloadContextMatches(key)
        or self.current_panel_index + 1 ~= key.panel_index then
        return false
    end

    local next_panel = self.current_panels[key.panel_index]
    if not next_panel then return false end
    logger.info(string.format("DynamicPanelZoom: Idle-preloading panel %d", key.panel_index))

    local dim = self.ui.document:getNativePageDimensions(key.page)
    if not dim then return false end
    local center = self:calculatePanelCenter(next_panel, dim)
    local margin = self.standard_margin_percent or 0.0
    local rect = self:panelToRect(next_panel, dim, margin)
    local image, _, custom_position, panel_screen_rect =
        self:drawPagePartWithSettings(key.page, rect, center, next_panel, dim)
    if not image then
        logger.warn("DynamicPanelZoom: Failed to idle-preload next panel")
        return false
    end

    if not self:preloadContextMatches(key)
        or self.current_panel_index + 1 ~= key.panel_index then
        if image.free then image:free() end
        return false
    end

    self._preloaded_image = image
    self._preloaded_panel_index = key.panel_index
    self._preloaded_panel = next_panel
    self._preloaded_dim = dim
    self._preloaded_custom_position = custom_position
    self._preloaded_panel_screen_rect = panel_screen_rect
    self._preloaded_key = key
    logger.info("DynamicPanelZoom: Successfully idle-preloaded next panel")
    return true
end

function PanelZoomIntegration:refreshPanelViewer(panel_viewer)
    if not panel_viewer then return end

    local clear_region, had_previous_region, draw_region
    if panel_viewer.consumeTransitionClearRegion then
        clear_region, had_previous_region, draw_region = panel_viewer:consumeTransitionClearRegion()
    else
        clear_region = panel_viewer.dimen
        had_previous_region = false
    end
    draw_region = draw_region or (had_previous_region and clear_region) or panel_viewer.dimen

    if PANEL_FULL_SCREEN_TRANSITION then
        local full_region = Geom:new{
            x = 0,
            y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        clear_region = full_region
        draw_region = full_region
    end

    local screen_area = math.max(1, Screen:getWidth() * Screen:getHeight())
    local clear_pct = (clear_region.w * clear_region.h * 100) / screen_area
    local draw_pct = (draw_region.w * draw_region.h * 100) / screen_area

    logger.info(string.format(
        "DynamicPanelZoom: Performing transition refresh clear_mode=%s draw_mode=%s single_mode=%s luma=%d direct=%s force_draw=%s full_screen=%s single_full_draw=%s clear=%d,%d %dx%d area=%.1f%% draw=%d,%d %dx%d area=%.1f%%",
        PANEL_CLEAR_REFRESH_MODE,
        PANEL_DRAW_REFRESH_MODE,
        PANEL_SINGLE_REFRESH_MODE,
        PANEL_CLEAR_LUMA,
        tostring(PANEL_DIRECT_CLEAR),
        tostring(PANEL_FORCE_DRAW_REPAINT),
        tostring(PANEL_FULL_SCREEN_TRANSITION),
        tostring(PANEL_SINGLE_FULL_DRAW),
        clear_region.x, clear_region.y, clear_region.w, clear_region.h,
        clear_pct,
        draw_region.x, draw_region.y, draw_region.w, draw_region.h,
        draw_pct))

    if PANEL_SINGLE_FULL_DRAW
        and PANEL_FULL_SCREEN_TRANSITION then
        local refresh_dither = Screen.sw_dithering
            or (self.ui and self.ui.document and self.ui.document.hw_dithering)
        panel_viewer:setClearOnly(false)
        panel_viewer:update(PANEL_SINGLE_REFRESH_MODE, nil, refresh_dither)
        logger.info(string.format(
            "DynamicPanelZoom: Queued final panel with single %s refresh dither=%s",
            PANEL_SINGLE_REFRESH_MODE, tostring(refresh_dither)))
        return
    end

    if PANEL_DIRECT_CLEAR and Screen.bb then
        Screen.bb:paintRect(clear_region.x, clear_region.y, clear_region.w, clear_region.h,
            Blitbuffer.Color8(PANEL_CLEAR_LUMA))
        if PANEL_CLEAR_REFRESH_MODE == "full" and Screen.refreshFull then
            Screen:refreshFull(clear_region.x, clear_region.y, clear_region.w, clear_region.h)
        elseif PANEL_CLEAR_REFRESH_MODE == "flashui" and Screen.refreshFlashUI then
            Screen:refreshFlashUI(clear_region.x, clear_region.y, clear_region.w, clear_region.h)
        elseif PANEL_CLEAR_REFRESH_MODE == "ui" and Screen.refreshUI then
            Screen:refreshUI(clear_region.x, clear_region.y, clear_region.w, clear_region.h)
        elseif PANEL_CLEAR_REFRESH_MODE == "fast" and Screen.refreshFast then
            Screen:refreshFast(clear_region.x, clear_region.y, clear_region.w, clear_region.h)
        else
            panel_viewer:update(PANEL_CLEAR_REFRESH_MODE, clear_region, Screen.sw_dithering)
            if UIManager.forceRePaint then UIManager:forceRePaint() end
        end
    else
        panel_viewer:setClearOnly(true, PANEL_CLEAR_LUMA)
        panel_viewer:update(PANEL_CLEAR_REFRESH_MODE, clear_region, Screen.sw_dithering)
        if UIManager.forceRePaint then UIManager:forceRePaint() end
    end

    if PANEL_CLEAR_EPDC_SLEEP_US > 0 and UIManager.yieldToEPDC then
        UIManager:yieldToEPDC(PANEL_CLEAR_EPDC_SLEEP_US)
    end

    if self._current_imgviewer ~= panel_viewer then
        panel_viewer:setClearOnly(false)
        return
    end

    panel_viewer:setClearOnly(false)
    panel_viewer:update(PANEL_DRAW_REFRESH_MODE, draw_region, Screen.sw_dithering)
    if PANEL_FORCE_DRAW_REPAINT and UIManager.forceRePaint then UIManager:forceRePaint() end
end

-- Display preloaded panel instantly
function PanelZoomIntegration:displayPreloadedPanel()
    if not self._current_imgviewer
        or not self:hasValidPreloadedPanel(self.current_panel_index) then
        logger.warn("DynamicPanelZoom: No preloaded image or viewer available")
        return false
    end
    
    logger.info("DynamicPanelZoom: Displaying preloaded panel instantly")
    
    -- Update existing viewer with preloaded image using PanelViewer's method
    self._current_imgviewer:updateImage(self._preloaded_image)
    
    -- Get screen and image dimensions
    local Screen = require("device").screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local image_w = self._preloaded_image:getWidth()
    local image_h = self._preloaded_image:getHeight()
    
    -- Use the pre-calculated center-locked position instead of simple centering
    local custom_position = self._preloaded_custom_position or {
        x = math.floor(((screen_w - image_w) / 2) + 0.5),
        y = math.floor(((screen_h - image_h) / 2) + 0.5),
    }
    
    logger.info(string.format("PanelZoom: Using preloaded center-locked position - x:%d, y:%d (image:%dx%d, screen:%dx%d)", 
        custom_position.x, custom_position.y, image_w, image_h, screen_w, screen_h))
    
    self._current_imgviewer:updateCustomPosition(custom_position)
    if self._current_imgviewer.updatePanelScreenRect then
        self._current_imgviewer:updatePanelScreenRect(self._preloaded_panel_screen_rect)
    end
    logger.info(string.format("PanelZoom: Updated custom position for preloaded panel - x:%d, y:%d (image:%dx%d, screen:%dx%d)", 
        custom_position.x, custom_position.y, image_w, image_h, screen_w, screen_h))
    
    self:refreshPanelViewer(self._current_imgviewer)
    
    -- Clear preloaded data after use
    self._preloaded_image = nil
    self._preloaded_panel_index = nil
    self._preloaded_panel = nil
    self._preloaded_dim = nil
    self._preloaded_custom_position = nil
    self._preloaded_panel_screen_rect = nil
    self._preloaded_key = nil
    
    self:scheduleNextPanelPreload(PANEL_CHAINED_PRELOAD_DELAY)
    
    return true
end

-- Custom drawPagePart that applies document settings
function PanelZoomIntegration:drawPagePartWithSettings(pageno, rect, panel_center, panel, dim, scale_override)
    -- 1. Document & Screen Settings
    local doc_cfg = self.ui.document.info.config or {}
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    local contrast = doc_cfg.contrast or 1.0
    
    local Screen = require("device").screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Giant-panel overview/detail sequences own the whole screen. Their
    -- detail slices must fill the physical width without the normal 5px
    -- safety border; regular dynamically detected panels keep it.
    local giant_panel_step = panel and panel.giant_panel_mode ~= nil
    local force_width_fill = panel and panel.giant_panel_mode == "detail"
    local padding = giant_panel_step and 0 or 5
    local safe_w = screen_w - (padding * 2)
    local safe_h = screen_h - (padding * 2)

    -- 3. CALCULATE SCALE (Must fit inside Safe Zone)
    local final_scale = 1.0
    if scale_override then
        final_scale = scale_override
        logger.info(string.format("DynamicPanelZoom: Using override scale %.4f", final_scale))
    else
        local scale_w = safe_w / rect.w
        local scale_h = safe_h / rect.h
        final_scale = force_width_fill and scale_w or math.min(scale_w, scale_h)
    end

    -- Calculate final display dimensions
    local display_w = math.floor(rect.w * final_scale + 0.5)
    local display_h = math.floor(rect.h * final_scale + 0.5)

    -- 4. ORIGINAL CENTERING LOGIC
    -- We calculate the top-left to perfectly center the box on screen
    local pos_x = (screen_w - display_w) / 2
    local pos_y = (screen_h - display_h) / 2

    -- 5. CLAMPING TO ABSOLUTE LIMITS
    -- Regular panels keep their safety border; giant-panel steps may touch
    -- the screen edges and detail slices are positioned flush left/right.
    local custom_position = {
        x = math.floor(math.max(padding, math.min(pos_x, screen_w - display_w - padding)) + 0.5),
        y = math.floor(math.max(padding, math.min(pos_y, screen_h - display_h - padding)) + 0.5)
    }

    local panel_screen_rect
    if panel and dim and panel.x and panel.y and panel.w and panel.h then
        local panel_x0 = custom_position.x + ((panel.x * dim.w) - rect.x) * final_scale
        local panel_y0 = custom_position.y + ((panel.y * dim.h) - rect.y) * final_scale
        local panel_x1 = custom_position.x + (((panel.x + panel.w) * dim.w) - rect.x) * final_scale
        local panel_y1 = custom_position.y + (((panel.y + panel.h) * dim.h) - rect.y) * final_scale

        panel_screen_rect = {
            x = math.floor(panel_x0),
            y = math.floor(panel_y0),
            w = math.max(1, math.ceil(panel_x1) - math.floor(panel_x0)),
            h = math.max(1, math.ceil(panel_y1) - math.floor(panel_y0)),
        }

        logger.info(string.format(
            "DynamicPanelZoom: Semantic panel screen rect %d,%d %dx%d",
            panel_screen_rect.x,
            panel_screen_rect.y,
            panel_screen_rect.w,
            panel_screen_rect.h
        ))
    end

    -- 6. RENDER
    -- Attach the prescaled rect so Document:renderPage knows we handled the
    -- scaling ourselves (same contract as Document:drawPagePart).
    local geom_rect = Geom:new(rect)
    local scaled_rect = geom_rect:copy()
    scaled_rect:transformByScale(final_scale, final_scale)
    rect.scaled_rect = scaled_rect

    -- Current KOReader signature: renderPage(pageno, rect, zoom, rotation, gamma, saturation, hinting).
    local ok, tile = pcall(self.ui.document.renderPage, self.ui.document,
        pageno, rect, final_scale, 0, gamma, 1.0, true)
    if not ok or not tile or not tile.bb then
        logger.err("DynamicPanelZoom: renderPage failed: " .. tostring(tile))
        return nil
    end

    -- tile.bb belongs to KOReader's DocCache: it can be evicted and freed at
    -- any time, and mutating it would corrupt the shared cache. Hand out a
    -- private copy instead; the viewer owns and frees it.
    local image = tile.bb:copy()

    -- 7. POST-PROCESSING
    if image then
        if contrast ~= 1.0 and image.contrast then
            image:contrast(contrast)
        end
        if doc_cfg.invert and image.invert then
            image:invert()
        end
        
        logger.info(string.format(
            "DynamicPanelZoom: [Safe Zone %dpx edge_to_edge=%s width_fill=%s] Rendered %dx%d at (%d,%d)",
            padding, tostring(giant_panel_step), tostring(force_width_fill),
            display_w, display_h, custom_position.x, custom_position.y))
    end

    return image, false, custom_position, panel_screen_rect
end

-- Apply KOReader's contrast and gamma settings to image buffer
-- This can be used for preloaded images or manual refreshes
function PanelZoomIntegration:applyDocumentSettings(image)
    if not image then return false end
    
    local doc_cfg = self.ui.document.info.config or {}
    local contrast = doc_cfg.contrast or 1.0
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    
    -- Contrast
    if image.contrast and contrast ~= 1.0 then
        image:contrast(contrast)
        logger.info(string.format("DynamicPanelZoom: Applied contrast %.2f", contrast))
    end
    
    -- Gamma (if not handled during renderPage)
    if image.gamma and gamma ~= 1.0 then
        image:gamma(gamma)
        logger.info(string.format("DynamicPanelZoom: Applied gamma %.2f", gamma))
    end
    
    -- Invert
    if image.invert and doc_cfg.invert then
        image:invert()
        logger.info("DynamicPanelZoom: Applied image inversion")
    end
    
    return true
end

-- Clean up preloaded image to prevent memory leaks
function PanelZoomIntegration:cleanupPreloadedImage()
    if self._preloaded_image then
        logger.info("DynamicPanelZoom: Cleaning up preloaded image")
        -- The preloaded image is our own copy (drawPagePartWithSettings), so
        -- it must be freed when discarded without being displayed.
        if self._preloaded_image.free then
            self._preloaded_image:free()
        end
    end
    self._preloaded_image = nil
    self._preloaded_panel_index = nil
    self._preloaded_panel = nil
    self._preloaded_dim = nil
    self._preloaded_custom_position = nil
    self._preloaded_panel_screen_rect = nil
    self._preloaded_key = nil
end

function PanelZoomIntegration:changePage(diff)
    -- DO NOT close the current panel viewer immediately. 
    -- Leaving it open keeps the screen covered with the last panel 
    -- while KOReader renders the new full page in the background, 
    -- preventing the "flash of full page" spoiler.

    -- Cancel lookahead work immediately so it cannot cross a page boundary.
    self:cancelPanelPreload()

    -- Save current state for the event-driven flow
    self._is_changing_page = true
    self._page_change_diff = diff

    -- FLASH PREVENTION: Suppress E-Ink screen refreshes while KOReader
    -- renders the new page underneath our PanelViewer.
    -- `currently_scrolling = true` forces all refresh modes to "fast" (no flash).
    UIManager.currently_scrolling = true

    -- Safety net: if onPageUpdate never fires (legacy Kindle builds, missed
    -- events, etc.), _is_changing_page would stay true forever and silently
    -- drop every subsequent handleTapRight/Left/Key navigation, making the
    -- viewer look softlocked. Force-reset both the E-Ink refresh suppression
    -- and the page-change flag after 1s so the worst case is a 1s delay, not
    -- a permanent dead viewer.
    UIManager:scheduleIn(1.0, function()
        if UIManager.currently_scrolling then
            logger.warn("DynamicPanelZoom: Safety net restored currently_scrolling to false")
            UIManager.currently_scrolling = false
        end
        if self._is_changing_page then
            logger.warn("DynamicPanelZoom: Safety net forced _is_changing_page to false (onPageUpdate likely never fired)")
            self._is_changing_page = false
            self._page_change_diff = nil
        end
    end)

    -- Trigger page navigation.
    -- onGotoViewRel is SYNCHRONOUS: it calls _gotoPage() which emits PageUpdate
    -- before returning. Our onPageUpdate handler will detect _is_changing_page
    -- and call _onPageChangeComplete() via nextTick.
    if self.ui.paging and self.ui.paging.onGotoViewRel then
        self.ui.paging:onGotoViewRel(diff)
        logger.info(string.format("DynamicPanelZoom: Used ui.paging.onGotoViewRel(%d)", diff))
    else
        -- Fallback to key event — this path does NOT guarantee a PageUpdate event,
        -- so we handle it directly with nextTick as a safety measure.
        local key = diff > 0 and "Right" or "Left"
        UIManager:sendEvent({ key = key, modifiers = {} })
        logger.info(string.format("DynamicPanelZoom: Used %s key event as fallback", key))
        -- Since key events may not trigger onPageUpdate synchronously,
        -- schedule the completion handler ourselves.
        self:_onPageChangeComplete(nil)
    end
end

-- Handle page change completion. Called by onPageUpdate (event-driven) or
-- directly from changePage() fallback path. Uses nextTick to ensure all
-- other PageUpdate handlers (ReaderView, ReaderZooming, etc.) have finished
-- processing before we load our panel.
function PanelZoomIntegration:_onPageChangeComplete(new_page_no)
    UIManager:nextTick(function()
        -- Restore normal refresh behavior now that we're ready to show our panel
        UIManager.currently_scrolling = false
        -- Prevent the partial->full flash promotion counter from triggering
        UIManager:avoidFlashOnNextRepaint()

        local new_page = new_page_no or self:getSafePageNumber()
        local diff = self._page_change_diff or 1
        logger.info(string.format("DynamicPanelZoom: Page change complete - page %d (diff: %d)", new_page, diff))
        self.last_page_seen = new_page

        self:importToggleZoomPanels()

        if #self.current_panels > 0 then
            -- Moving Forward (diff > 0): Start at first panel of new page.
            -- Moving Backward (diff < 0): Start at last panel of previous page.
            self.current_panel_index = (diff > 0) and 1 or #self.current_panels
            self:displayCurrentPanel()
        else
            UIManager:show(InfoMessage:new{ text = _("No panels on this page"), timeout = 1 })
            self:closeViewer()
        end

        self._is_changing_page = false
        self._page_change_diff = nil
    end)
end

function PanelZoomIntegration:getSafePageNumber()
    if self.ui.paging and self.ui.paging.current_page and self.ui.paging.current_page > 0 then
        return self.ui.paging.current_page
    end
    if self.ui.view and self.ui.view.state and self.ui.view.state.page then
        return self.ui.view.state.page
    end
    return 1
end

function PanelZoomIntegration:onIntegratedPanelZoom(arg, ges)
    -- Ensure we have the gesture object
    local actual_ges = (type(arg) == "table" and arg.pos) and arg or ges

    if not self.plugin_enabled then
        logger.info("DynamicPanelZoom: Plugin disabled, using original Panel Zoom")
        if self._original_panel_zoom_handler then
            return self._original_panel_zoom_handler(self.ui.highlight, arg, ges)
        end
        return false
    end
    
    -- If JSON is not available, fall back to built-in Panel Zoom
    if not self._json_available then
        logger.info("DynamicPanelZoom: JSON not available, using built-in Panel Zoom")
        if self._original_panel_zoom_handler then
            return self._original_panel_zoom_handler(self.ui.highlight, arg, ges)
        end
        return false
    end
    
    local current_page = self:getSafePageNumber()
    logger.info(string.format("DynamicPanelZoom: onIntegratedPanelZoom called - current_page: %d, last_page_seen: %d, panels_count: %d", 
        current_page, self.last_page_seen or -1, #self.current_panels))
    
    -- Force import if page changed or panels empty
    if current_page ~= self.last_page_seen or #self.current_panels == 0 then
        logger.info(string.format("DynamicPanelZoom: Page changed or no panels - importing for page %d", current_page))
        self.last_page_seen = current_page
        self:importToggleZoomPanels()
    else
        logger.info(string.format("DynamicPanelZoom: Using cached panels for page %d", current_page))
    end

    if #self.current_panels > 0 then
        -- Initial launch of Panel Viewer on a page
        -- In LTR, start at index 1 (top-left). In RTL, start at index 1 (top-right).
        self.current_panel_index = 1
        return self:displayCurrentPanel()
    end

    logger.warn("DynamicPanelZoom: No panels found for this page in JSON.")
    return false
end

function PanelZoomIntegration:importToggleZoomPanels()
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    local page_idx = self:getSafePageNumber()
    local reading_dir = self:getEffectiveReadingDirection()
    
    -- The cache key must now include reading_dir, otherwise flipping direction
    -- uses the old cached layout where panel 1 meant LTR/top-left instead of RTL/top-right.
    if not self._panel_cache[doc_path] then self._panel_cache[doc_path] = {} end
    if not self._panel_cache[doc_path][reading_dir] then self._panel_cache[doc_path][reading_dir] = {} end
    
    -- Check if we already have panels for this page cached in memory FOR THIS READING DIR
    if self._panel_cache[doc_path][reading_dir][page_idx] then
        logger.info(string.format("DynamicPanelZoom: Using cached %s panels for page %d", reading_dir, page_idx))
        self:replaceCurrentPanels(self._panel_cache[doc_path][reading_dir][page_idx])
        return
    end
    
    self:debugLog(string.format("DynamicPanelZoom: Analyzing page %d for %s panels dynamically", page_idx, reading_dir))
    -- Detection is synchronous and can take up to ~1s on device: give the
    -- user immediate feedback instead of a frozen screen.
    local analyzing_msg = InfoMessage:new{ text = _("Analyzing page…") }
    UIManager:show(analyzing_msg)
    UIManager:forceRePaint()
    local panels, analysis_error = self:analyzePageForPanels(page_idx)
    self:replaceCurrentPanels(panels)
    UIManager:close(analyzing_msg)

    -- Cache the layout — but never cache an error fallback, so a transient
    -- failure doesn't poison the page until KOReader restarts.
    if not analysis_error then
        self._panel_cache[doc_path][reading_dir][page_idx] = self.current_panels
    end
    
    if #self.current_panels > 0 then
        logger.info(string.format("DynamicPanelZoom: SUCCESS! Detected %d panels for page %d (%s)", #self.current_panels, page_idx, reading_dir))
    else
        logger.warn(string.format("DynamicPanelZoom: No panels detected on page %d", page_idx))
    end
end

function PanelZoomIntegration:_extractRawBoxes(pageno, bounds_only)
    local ffi = require("ffi")
    local time_start = os.clock()

    local doc = self.ui.document
    if not doc or not doc._document then return {} end

    local page_size = doc:getNativePageDimensions(pageno)
    if not page_size then return {} end

    local bbox = {
        x0 = 0, y0 = 0,
        x1 = page_size.w,
        y1 = page_size.h,
    }

    -- Create the render context the same way KOReader's own panel detector
    -- does (koptinterface:getPanelFromPage), then downscale: ~1000px long
    -- side is enough for gutter geometry, suppresses halftone/texture noise,
    -- and keeps the per-pixel loops cheap on device.
    local kc
    if doc.koptinterface and doc.koptinterface.createContext then
        kc = doc.koptinterface:createContext(doc, pageno, bbox)
    else
        local KOPTContext = require("ffi/koptcontext")
        kc = KOPTContext.new()
        kc:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    end
    -- getNativePageDimensions returns POINTS for image-based documents (a
    -- 1920px CBZ page reports ~461), so the zoom may legitimately exceed 1.0:
    -- MuPDF then samples the full-resolution source down to our target size.
    local analysis_target = bounds_only and BASIC_BOUNDS_TARGET_PX or ANALYSIS_TARGET_PX
    local scale = analysis_target / math.max(page_size.w, page_size.h)
    scale = math.min(scale, 4.0)
    kc:setZoom(scale)

    local page = doc._document:openPage(pageno)
    if not page then
        if kc.free then kc:free() end
        return {}
    end

    local ok, panels, info = pcall(function()
        page:getPagePix(kc, doc.render_mode,
            doc.configurable and doc.configurable.background_cleanup)

        local src = kc.src
        local w, h, bpp = src.width, src.height, src.bpp
        if src.data == nil or w <= 0 or h <= 0 then
            error("empty render bitmap")
        end

        local bytes_px = math.floor(bpp / 8)
        if bytes_px < 1 then
            error("unsupported bitmap depth: " .. tostring(bpp))
        end
        local data = ffi.cast("uint8_t*", src.data)

        -- The analysis bitmap data is tightly packed. src.size_allocated is
        -- allocation capacity, not row pitch; treating it as padded stride
        -- shears odd-width 24bpp renders before the detector sees them.
        local tight = w * bytes_px
        local padded = math.ceil(tight / 4) * 4
        local stride = tight
        local alloc = tonumber(src.size_allocated) or 0
        self:debugLog(string.format(
            "DynamicPanelZoom: analysis render %dx%d bpp=%d stride=%d tight=%d padded=%d alloc=%d scale=%.3f",
            w, h, bpp, stride, tight, padded, alloc, scale))

        local pix
        if bytes_px == 1 then
            pix = function(x, y) return data[y * stride + x] end
        else
            -- Must return an INTEGER 0..255 (PanelDetect histograms by value).
            local rshift = require("bit").rshift
            pix = function(x, y)
                local off = y * stride + x * bytes_px
                return rshift(data[off] * 77 + data[off + 1] * 150 + data[off + 2] * 29, 8)
            end
        end

        -- Verbose diagnostics to crash.log: a luma histogram every analysis
        -- (cheap, always on with debug logging) and, when the dump is enabled,
        -- the EXACT grayscale buffer as base64 -- so a device render can be
        -- reproduced pixel-for-pixel in the desktop harness (which resamples
        -- the source JPG itself and cannot otherwise see MuPDF/eink dither or
        -- background_cleanup speckle).
        if self.debug_log_panels then
            self:logLumaHistogram(pix, w, h)
        end
        if self.dump_analysis_pgm then
            self:dumpAnalysisPGM(pageno, pix, w, h)
        end

        if bounds_only then
            return PanelDetect.findContentBounds(pix, w, h)
        end

        local detected, detection_info = PanelDetect.detect(pix, w, h)
        if #detected == 1 then
            local p = detected[1]
            if p.x <= 0.015 and p.x + p.w >= 0.985 then
                local bounds = PanelDetect.findContentBounds(pix, w, h)
                p.overview_x = bounds.x
                p.overview_y = bounds.y
                p.overview_w = bounds.w
                p.overview_h = bounds.h
                p.detail_x = bounds.x
                p.detail_y = bounds.y
                p.detail_w = bounds.w
                p.detail_h = bounds.h
            end
        end
        return detected, detection_info
    end)

    page:close()
    if kc.free then kc:free() end

    if not ok then
        logger.err("DynamicPanelZoom: analysis failed: " .. tostring(panels))
        if bounds_only then
            return { x = 0, y = 0, w = 1, h = 1 }, true
        end
        return { { x = 0, y = 0, w = 1, h = 1 } }, true
    end

    if bounds_only then
        logger.info(string.format(
            "DynamicPanelZoom: artwork bounds x=%.3f y=%.3f w=%.3f h=%.3f in %.0f ms",
            panels.x, panels.y, panels.w, panels.h,
            (os.clock() - time_start) * 1000))
        return panels, false
    end

    logger.info(string.format(
        "DynamicPanelZoom: detected %d panels in %.0f ms (bg=%d tol=%.3f raw=%d union=%.2f sum=%.2f max_iou=%.2f confidence=%s fallback=%s reason=%s rescue=%s attempts=%d regions=%d)",
        #panels, (os.clock() - time_start) * 1000,
        info.background or -1, info.tolerance_used or -1, info.raw_count or -1,
        info.union_coverage or info.coverage or 0, info.sum_coverage or 0,
        info.max_iou or 0, tostring(info.confidence or "unknown"),
        tostring(info.fallback), tostring(info.fallback_reason or "none"),
        tostring(info.structural_rescue_kind or "none"),
        info.structural_rescue_attempts or 0,
        info.structural_rescue_regions or 0))

    return panels
end

function PanelZoomIntegration:expandSingleGiantPanelSequence(panels, page_aspect)
    if not self.single_giant_detail_enabled or #panels == 0 then
        return panels
    end

    local function area(p)
        return (p.w or 0) * (p.h or 0)
    end

    local function isGiant(p)
        return area(p) >= self.single_giant_detail_min_area
            and (p.w or 0) >= self.single_giant_detail_min_w
            and (p.h or 0) >= self.single_giant_detail_min_h
    end

    local function makeSequence(p)
        local count = math.max(1, math.floor((self.single_giant_detail_count or 4) + 0.5))
        local detail_x = p.detail_x or p.x
        local detail_y = p.detail_y or p.y
        local detail_w = p.detail_w or p.w
        local detail_h = p.detail_h or p.h
        local screen_aspect = Screen:getWidth() / math.max(1, Screen:getHeight())
        local detail_views, sweep = PanelDetect.buildDetailViews({
            x = detail_x, y = detail_y, w = detail_w, h = detail_h,
        }, count, page_aspect, screen_aspect, self:getEffectiveReadingDirection())
        local overview_x = p.overview_x or p.x
        local overview_y = p.overview_y or p.y
        local overview_w = p.overview_w or p.w
        local overview_h = p.overview_h or p.h
        local out = {
            {
                x = overview_x,
                y = overview_y,
                w = overview_w,
                h = overview_h,
                giant_panel_mode = "full",
            },
        }
        for i = 1, count do
            local view = detail_views[i]
            out[#out + 1] = {
                x = view.x,
                y = view.y,
                w = view.w,
                h = view.h,
                giant_panel_mode = "detail",
                giant_panel_slice = i,
            }
        end
        logger.info(string.format(
            "DynamicPanelZoom: Expanded giant panel area=%.2f into trimmed overview + %d screen-filling detail views (%s sweep)",
            area(p), count, sweep))
        return out
    end

    if #panels == 1 then
        return isGiant(panels[1]) and makeSequence(panels[1]) or panels
    end

    local giant_i = 1
    for i = 2, #panels do
        if area(panels[i]) > area(panels[giant_i]) then giant_i = i end
    end
    local giant = panels[giant_i]
    if not isGiant(giant) or #panels > 3 then return panels end

    -- One short banner followed by an enormous lower composite: preserve the
    -- banner, then make the unreadable composite navigable at full width.
    if #panels == 2 then
        local other_i = giant_i == 1 and 2 or 1
        local other = panels[other_i]
        local vertical_gap = giant.y - (other.y + other.h)
        local x0 = math.min(giant.x, other.x)
        local y0 = math.min(giant.y, other.y)
        local x1 = math.max(giant.x + giant.w, other.x + other.w)
        local y1 = math.max(giant.y + giant.h, other.y + other.h)

        -- Cover/title pages often appear as one short title region followed
        -- by one near-full-page image. Treat the pair as one page so the
        -- automatic fallback matches Basic 4 Panels Mode: overview, then
        -- four screen-filling detail views.
        if area(giant) >= 0.65 and giant.h >= 0.68
            and giant.x <= 0.02 and giant.y + giant.h >= 0.98
            and other.w >= 0.75 and other.h >= 0.15 and other.h <= 0.28
            and other.y <= giant.y and vertical_gap >= -0.02 and vertical_gap <= 0.04
            and y1 - y0 >= 0.90 and (x1 - x0) * (y1 - y0) >= 0.85 then
            return makeSequence({
                x = 0, y = 0, w = 1, h = 1,
                detail_x = x0,
                detail_y = y0,
                detail_w = x1 - x0,
                detail_h = y1 - y0,
            })
        end

        if area(giant) >= 0.65 and giant.h >= 0.70
            and other.w >= 0.75 and other.h <= 0.25
            and other.y <= giant.y and vertical_gap <= 0.04 then
            local out = { other }
            for _, p in ipairs(makeSequence(giant)) do out[#out + 1] = p end
            return out
        end
        return panels
    end

    -- One dominant picture with two small embedded/inset detections is more
    -- useful as a single overview plus detail slices than as three odd crops.
    local extras_small = true
    local x0, y0 = giant.x, giant.y
    local x1, y1 = giant.x + giant.w, giant.y + giant.h
    for i, p in ipairs(panels) do
        if i ~= giant_i then
            local gap = p.y - (giant.y + giant.h)
            if area(p) > 0.12 or gap > 0.05 then extras_small = false end
            x0, y0 = math.min(x0, p.x), math.min(y0, p.y)
            x1, y1 = math.max(x1, p.x + p.w), math.max(y1, p.y + p.h)
        end
    end
    local union = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    if extras_small and area(union) >= 0.65 then
        return makeSequence(union)
    end
    return panels
end

function PanelZoomIntegration:analyzePageForPanels(pageno)
    local page_dim = self.ui.document:getNativePageDimensions(pageno)
        or self.ui.document:getPageSize(pageno)
    local page_aspect = page_dim and page_dim.h > 0
        and page_dim.w / page_dim.h or 1
    if self.basic_three_panel_mode then
        logger.info(string.format(
            "DynamicPanelZoom: Basic 4 Panels Mode active for page %d; scanning artwork bounds only",
            pageno))
        local bounds, bounds_error = self:_extractRawBoxes(pageno, true)
        return self:expandSingleGiantPanelSequence({
            {
                x = 0, y = 0, w = 1, h = 1,
                overview_x = bounds.x,
                overview_y = bounds.y,
                overview_w = bounds.w,
                overview_h = bounds.h,
                detail_x = bounds.x,
                detail_y = bounds.y,
                detail_w = bounds.w,
                detail_h = bounds.h,
            },
        }, page_aspect), bounds_error
    end

    local panels, analysis_error = self:_extractRawBoxes(pageno)
    panels = PanelDetect.sort(panels, self:getEffectiveReadingDirection())
    panels = self:expandSingleGiantPanelSequence(panels, page_aspect)
    panels = PanelDetect.addDisplayEdgeSafety(panels)

    if self.debug_log_panels then
        for i, p in ipairs(panels) do
            logger.info(string.format("  Panel %d: x=%.3f, y=%.3f, w=%.3f, h=%.3f", i, p.x, p.y, p.w, p.h))
        end
    end

    return panels, analysis_error
end

-- Log a diagnostic line to crash.log via KOReader's logger (the only sink;
-- no separate files). crash.log survives restarts and is the single file the
-- user hands over.
function PanelZoomIntegration:debugLog(msg)
    logger.info(msg)
end

-- Diagnostic: emit the EXACT analysis grayscale buffer into crash.log as a
-- base64 PGM, so a device mis-detection can be reproduced pixel-for-pixel in
-- the desktop harness (dither / background_cleanup speckle the harness cannot
-- otherwise see). Every line carries the sentinel "PZPGM" AFTER the logger's
-- timestamp prefix, so the harness parser strips the prefix by splitting on
-- the sentinel -- no dependence on the exact logger format.
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function PanelZoomIntegration:dumpAnalysisPGM(pageno, pix, w, h)
    local ok, err = pcall(function()
        -- 1. Pack the buffer row-major into a raw byte string, summing the
        -- pixel values as a cheap integrity checksum (exact: max ~3.3e8 < 2^53).
        local rows, row = {}, {}
        local checksum = 0
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local v = pix(x, y)
                row[x + 1] = string.char(v)
                checksum = checksum + v
            end
            rows[y + 1] = table.concat(row)
        end
        local raw = table.concat(rows)

        -- 2. Base64-encode (plain arithmetic, no bit-lib dependency).
        local b = B64_ALPHABET
        local out, oi, n = {}, 0, #raw
        for i = 1, n, 3 do
            local b1, b2, b3 = raw:byte(i, i + 2)
            local c1 = math.floor(b1 / 4)
            local c2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
            oi = oi + 1
            out[oi] = b:sub(c1 + 1, c1 + 1) .. b:sub(c2 + 1, c2 + 1)
                .. (b2 and b:sub((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0) + 1,
                              (b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0) + 1) or "=")
                .. (b3 and b:sub(b3 % 64 + 1, b3 % 64 + 1) or "=")
        end
        local b64 = table.concat(out)

        -- 3. Emit as delimited logger lines (-> crash.log). Each chunk line
        -- begins with the sentinel so the parser can strip the timestamp
        -- prefix; BEGIN carries bytes+b64len+checksum so the parser can VERIFY
        -- the reassembled bitmap is complete before wasting a reproduction.
        logger.info(string.format("PZPGM_BEGIN page=%d w=%d h=%d bytes=%d b64len=%d checksum=%d",
            pageno, w, h, n, #b64, checksum))
        for s = 1, #b64, 4000 do
            logger.info("PZPGM " .. b64:sub(s, s + 3999))
        end
        logger.info(string.format("PZPGM_END page=%d", pageno))
    end)
    if not ok then
        logger.warn("DynamicPanelZoom: could not dump analysis PGM: " .. tostring(err))
    end
end

-- Compact luma histogram (16 buckets) of the analysis buffer, logged to
-- crash.log. Dithered / speckled device renders show a very different (bimodal,
-- spiky) distribution than the harness's smooth resample -- visible at a glance
-- without decoding the full bitmap, and a strong first clue to the culprit.
function PanelZoomIntegration:logLumaHistogram(pix, w, h)
    local ok = pcall(function()
        local h16 = {}
        for i = 0, 15 do h16[i] = 0 end
        local step = 2  -- subsample; matches the detector's sampling density
        local total = 0
        for y = 0, h - 1, step do
            for x = 0, w - 1, step do
                local v = pix(x, y)
                local bkt = math.floor(v / 16)
                if bkt > 15 then bkt = 15 end
                h16[bkt] = h16[bkt] + 1
                total = total + 1
            end
        end
        local parts = {}
        for i = 0, 15 do
            parts[i + 1] = string.format("%d", h16[i])
        end
        logger.info(string.format(
            "DynamicPanelZoom: luma histogram (16x16-wide buckets, n=%d): %s",
            total, table.concat(parts, ",")))
    end)
    if not ok then return end
end

function PanelZoomIntegration:calculatePanelCenter(panel, dim)
    -- Calculate absolute center coordinates from panel JSON data
    -- Center_x = x + w/2, Center_y = y + h/2
    local center_x = panel.x + (panel.w / 2)
    local center_y = panel.y + (panel.h / 2)
    
    -- Convert to absolute pixel coordinates
    local abs_center_x = math.floor(center_x * dim.w + 0.5)
    local abs_center_y = math.floor(center_y * dim.h + 0.5)
    
    logger.info(string.format("PanelZoom: Panel center - normalized:(%.3f, %.3f), absolute:(%d, %d)", 
        center_x, center_y, abs_center_x, abs_center_y))
    
    return {
        x = center_x,
        y = center_y,
        abs_x = abs_center_x,
        abs_y = abs_center_y
    }
end

function PanelZoomIntegration:panelToRect(panel, dim, apply_margin_percent)
    -- Step 1: Compute panel center (NO padding involved) - semantic center only
    local panel_cx = (panel.x + panel.w / 2) * dim.w
    local panel_cy = (panel.y + panel.h / 2) * dim.h
    
    -- Step 2: Build a padded render rect (crop source)
    -- panel rect in page pixels
    local px = panel.x * dim.w
    local py = panel.y * dim.h
    local pw = panel.w * dim.w
    local ph = panel.h * dim.h
    
    local left_extension = 0
    local right_extension = 0
    local top_extension = 0
    local bottom_extension = 0
    local exact_detail_crop = panel.giant_panel_mode == "detail"

    if exact_detail_crop then
        -- Four-view detail crops already match the physical screen aspect and
        -- the detected artwork bounds. Expanding them would bring page
        -- whitespace back into view or create a visible screen band.
    elseif apply_margin_percent and apply_margin_percent > 0 then
        -- Zoom mode (or standard mode with custom margins): Apply constant absolute margin based on page size
        local base_dimension = math.max(dim.w, dim.h)
        local constant_margin = math.floor(base_dimension * apply_margin_percent + 0.5)
        
        left_extension = constant_margin
        right_extension = constant_margin
        top_extension = constant_margin
        bottom_extension = constant_margin
        logger.info(string.format("PanelZoom: Applying constant %.0fpx expanded margins", constant_margin))
    else
        -- Standard Panel Mode: Use default tight constraints
        left_extension = 2   -- Less extension on left side
        right_extension = 2 -- 4px + 5px more extension on right
        top_extension = 0.5
        bottom_extension = 2.5
    end
    
    local render_rect = {
        x = px - left_extension,
        y = py - top_extension,
        w = pw + left_extension + right_extension,
        h = ph + top_extension + bottom_extension,
    }
    
    -- Clamp to page bounds
    render_rect.w = math.min(render_rect.w, dim.w)
    render_rect.h = math.min(render_rect.h, dim.h)
    render_rect.x = math.max(0, math.min(render_rect.x, dim.w - render_rect.w))
    render_rect.y = math.max(0, math.min(render_rect.y, dim.h - render_rect.h))

    -- Step 3: Smart Fill (Aspect Ratio Expansion)
    if self.show_adjacent_panels and not exact_detail_crop then
        local screen_width = Screen:getWidth()
        local screen_height = Screen:getHeight()
        -- Handle landscape mode if orientation changed
        if self.view and self.view.mode == "landscape" then
            screen_width, screen_height = screen_height, screen_width
        end

        local screen_ratio = screen_width / screen_height
        local rect_ratio = render_rect.w / render_rect.h
        local smart_fill_strength = tonumber(self.smart_fill_strength) or 1.0
        smart_fill_strength = math.max(0, math.min(smart_fill_strength, 1))

        -- Some dark/full-bleed pages detect the dominant right-side ink but
        -- miss sparse left captions or ships in the same bottom panel. If a
        -- large panel reaches the page bottom and right edge, keep full-width
        -- context instead of slicing the left side.
        if panel.x > 0.25
            and panel.w > 0.55
            and panel.h > 0.40
            and panel.x + panel.w > 0.98
            and panel.y + panel.h > 0.98 then
            render_rect.x = 0
            render_rect.w = dim.w
            logger.info("PanelZoom: Applied full-width edge rescue for large bottom panel")
            rect_ratio = render_rect.w / render_rect.h
        end

        if rect_ratio > screen_ratio then
            -- Panel is wider than screen: Need to expand vertically (height)
            local target_new_h = render_rect.w / screen_ratio
            local total_expansion_needed = target_new_h - render_rect.h
            local expansion_per_side = (total_expansion_needed * smart_fill_strength) / 2
            
            render_rect.y = render_rect.y - expansion_per_side
            render_rect.h = render_rect.h + (expansion_per_side * 2)
            
        elseif rect_ratio < screen_ratio then
            -- Panel is taller than screen: Need to expand horizontally (width)
            local target_new_w = render_rect.h * screen_ratio
            local total_expansion_needed = target_new_w - render_rect.w
            local expansion_per_side = (total_expansion_needed * smart_fill_strength) / 2
            
            render_rect.x = render_rect.x - expansion_per_side
            render_rect.w = render_rect.w + (expansion_per_side * 2)
        end

        -- KOReader clips source pixels outside the page instead of padding
        -- them. Clamp the expanded Smart Fill rect back inside the document so
        -- edge panels do not lose usable screen area to off-page blank space.
        render_rect.w = math.min(render_rect.w, dim.w)
        render_rect.h = math.min(render_rect.h, dim.h)
        render_rect.x = math.max(0, math.min(render_rect.x, dim.w - render_rect.w))
        render_rect.y = math.max(0, math.min(render_rect.y, dim.h - render_rect.h))
    end
    
    logger.info(string.format("PanelZoom: Panel center:(%.1f,%.1f) render_rect:(%d,%d,%dx%d)", 
        panel_cx, panel_cy, render_rect.x, render_rect.y, render_rect.w, render_rect.h))
    
    -- Return render rect and panel center for later calculations
    return {
        x = render_rect.x,
        y = render_rect.y,
        w = render_rect.w,
        h = render_rect.h,
        panel_cx = panel_cx,  -- Semantic center (no padding)
        panel_cy = panel_cy   -- Semantic center (no padding)
    }
end


function PanelZoomIntegration:switchToZoomMode()
    logger.info("DynamicPanelZoom: Switching to Free Zoom Mode")
    
    local panel = self.current_panels[self.current_panel_index]
    if not panel then return false end

    local page = self:getSafePageNumber()
    local dim = self.ui.document:getNativePageDimensions(page) or self.ui.document:getPageSize(page)
    if not dim then return false end
    self:cancelPanelPreload()

    -- 1. Get expanded rect (margin for reading text that spills out)
    local margin = self.zoom_margin_percent or 0.05
    local expanded_rect = self:panelToRect(panel, dim, margin)
    local center = self:calculatePanelCenter(panel, dim)
    
    -- 2. DYNAMIC SCALING (To prevent Segmentation Fault)
    -- We cannot render arbitrary large images on E-Ink memory limits.
    -- We calculate the scale so the image buffer NEVER exceeds screen size + a small buffer
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    
    -- Safe memory rendering constraints
    -- E-ink displays can usually handle a buffer 2.5x to 3x their resolution
    -- before hitting SegFaults, but 1.5x is too blurry for comics text.
    -- We raise this to 2.5x to get crisp text while staying safely below the crash threshold.
    local max_buffer_w = screen_w * 2.5
    local max_buffer_h = screen_h * 2.5
    
    -- Find a safe base scale for the MuPDF render phase
    local scale_w = max_buffer_w / expanded_rect.w
    local scale_h = max_buffer_h / expanded_rect.h
    local safe_scale = math.min(scale_w, scale_h, 3.5) -- Raised the hard render scale cap to 3.5x
    
    logger.info(string.format("DynamicPanelZoom: Using safe memory render scale %.4f", safe_scale))

    -- 3. Generate safe expanded image
    local expanded_image, _, _ = self:drawPagePartWithSettings(page, expanded_rect, center, panel, dim, safe_scale)
    if not expanded_image then return false end

    -- Create native ImageViewer using safe dynamic loading
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok or type(ImageViewer) ~= "table" then
        logger.warn("DynamicPanelZoom: Failed to load imageviewer widget")
        return false
    end
    
    -- 4. APPLY SOFTWARE ZOOM OVER THE SAFE RENDER
    -- To prevent any visual "jump" when switching to 1.0x, we need to match the exact visual scale 
    -- the user was just looking at in the PanelViewer.
    -- First, calculate what the scale was in the normal PanelViewer:
    local standard_margin = self.standard_margin_percent or 0.0
    local normal_rect = self:panelToRect(panel, dim, standard_margin) -- Rect with standard panel margins
    local giant_panel_step = panel and panel.giant_panel_mode ~= nil
    local force_width_fill = panel and panel.giant_panel_mode == "detail"
    local padding = giant_panel_step and 0 or 5
    local safe_w = screen_w - (padding * 2)
    local safe_h = screen_h - (padding * 2)
    local normal_scale = force_width_fill
        and (safe_w / normal_rect.w)
        or math.min(safe_w / normal_rect.w, safe_h / normal_rect.h)
    
    -- The absolute scale we want to achieve on the physical screen (1 pixel image = 1 pixel screen at 1.0x)
    local target_absolute_scale = normal_scale / safe_scale
    
    -- IMPORTANT: ImageViewer doesn't treat scale_factor 1.0 as 1:1 pixels.
    -- It treats 1.0 as "Fit to screen" for the given image within its UI context.
    -- When buttons_visible = true, ImageViewer reserves space at the bottom (usually ~10-12% of screen height).
    local image_w = expanded_image:getWidth()
    local image_h = expanded_image:getHeight()
    
    -- Estimate ImageViewer's actual usable viewport (it reserves bottom space for buttons)
    local Size = require("ui/size")
    local button_bar_height = Size.bottom_menu_height or math.floor(screen_h * 0.1)
    local usable_h = screen_h - button_bar_height
    
    local fit_to_screen_scale = math.min(screen_w / image_w, usable_h / image_h)
    
    -- The software scale factor to pass to ImageViewer to achieve our target absolute scale
    -- Fix: ImageViewer uses explicit scale_factor as absolute scale on the image's native resolution, 
    -- not as a multiplier over fit_to_screen. Therefore, we pass target_absolute_scale directly.
    local base_visual_scale = target_absolute_scale
    
    -- Apply the user's zoom preference on top of that base scale
    local bump_factor = self.zoom_initial_scale or 1.2
    local initial_scale_factor = base_visual_scale * bump_factor
    
    logger.info(string.format("DynamicPanelZoom: ImageViewer usable height approx %d (screen %d)", usable_h, screen_h))
    logger.info(string.format("DynamicPanelZoom: ImageViewer Fit-to-screen scale is %.4f", fit_to_screen_scale))
    logger.info(string.format("DynamicPanelZoom: Required Absolute scale is %.4f", target_absolute_scale))
    logger.info(string.format("DynamicPanelZoom: Setting ImageViewer software scale factor to %.4f (bump: %.1fx)", initial_scale_factor, bump_factor))

    local image_viewer = ImageViewer:new{
        image = expanded_image,
        image_disposable = true, -- Our private copy: let ImageViewer free it on close
        fullscreen = true,
        with_title_bar = false,
        buttons_visible = true, -- Restored native UI buttons and minimap
        scale_factor = initial_scale_factor,
        
        -- Calculate the exact semantic center ratio of the panel inside our cropped expanded image
        -- This ensures the ImageViewer starts positioned right over the panel, compensating for asymmetrical margins near page edges.
        _center_x_ratio = (center.abs_x - expanded_rect.x) / expanded_rect.w,
        _center_y_ratio = (center.abs_y - expanded_rect.y) / expanded_rect.h,
    }

    -- We just push the image_viewer on top of the UI stack. 
    -- The PanelViewer stays underneath. When image_viewer is closed, PanelViewer is instantly revealed without flashing the background page.
    UIManager:show(image_viewer)
    return true
end

function PanelZoomIntegration:displayCurrentPanel()
    logger.info("DynamicPanelZoom: displayCurrentPanel called")
    local panel = self.current_panels[self.current_panel_index]
    if not panel then 
        logger.warn("DynamicPanelZoom: No panel data found for index " .. self.current_panel_index)
        return false 
    end

    local page = self:getSafePageNumber()
    
    -- Get dimensions from document for consistent coordinate space
    local dim = self.ui.document:getNativePageDimensions(page) or self.ui.document:getPageSize(page)
    if not dim then 
        logger.warn("DynamicPanelZoom: Could not get page dimensions")
        return false 
    end
    logger.info(string.format("DynamicPanelZoom: Using document dimensions - w:%d, h:%d", dim.w, dim.h))

    -- Use helper function for center-preserving quantization with dynamic frame
    local margin = self.standard_margin_percent or 0.0
    local rect = self:panelToRect(panel, dim, margin)
    
    -- Calculate and log panel center coordinates
    local center = self:calculatePanelCenter(panel, dim)
    
    logger.info(string.format("DynamicPanelZoom: Panel rect - x:%d, y:%d, w:%d, h:%d", rect.x, rect.y, rect.w, rect.h))
    
    -- Create new image for the panel with document settings
    local image, rotate, custom_position, panel_screen_rect = self:drawPagePartWithSettings(page, rect, center, panel, dim)
    if not image then
        logger.warn("DynamicPanelZoom: Could not draw page part")
        UIManager:show(InfoMessage:new{ text = _("Panel rendering failed — see crash.log"), timeout = 2 })
        return false
    end

    logger.info("DynamicPanelZoom: Successfully created panel image with document settings")

    -- Reuse existing viewer if available instead of closing to prevent flash of full page
    if self._current_imgviewer then
        logger.info("DynamicPanelZoom: Updating existing PanelViewer")
        self._current_imgviewer:updateReadingDirection(self:getEffectiveReadingDirection())
        self._current_imgviewer:updateBasicThreePanelMode(self.basic_three_panel_mode)
        self._current_imgviewer:updateCustomPosition(custom_position)
        self._current_imgviewer:updateImage(image)
        if self._current_imgviewer.updatePanelScreenRect then
            self._current_imgviewer:updatePanelScreenRect(panel_screen_rect)
        end
        self:refreshPanelViewer(self._current_imgviewer)
        
        self:scheduleNextPanelPreload()
        return true
    end
    
    -- Create new PanelViewer instance with our custom implementation
    logger.info("DynamicPanelZoom: Creating new PanelViewer instance")
    local panel_viewer = PanelViewer:new{
        image = image,
        fullscreen = true,
        buttons_visible = false,
        reading_direction = self:getEffectiveReadingDirection(),
        basic_three_panel_mode = self.basic_three_panel_mode,
        custom_position = custom_position,  -- Pass custom position for center matching
        panel_screen_rect = panel_screen_rect,
        onTapRight = function() self:handleTapRight() end,
        onTapLeft = function() self:handleTapLeft() end,
        onClose = function() 
            self:closeViewer()
            -- Restore OCR when panel viewer is closed
            self:restoreOCR()
        end,
        onHold = function()
            if self.hold_to_zoom_enabled then
                self:switchToZoomMode()
            end
        end,
        onToggleThreePanelMode = function()
            self:setBasicThreePanelMode(not self.basic_three_panel_mode)
        end,
    }
    
    self._current_imgviewer = panel_viewer
    logger.info("DynamicPanelZoom: Showing new PanelViewer")
    UIManager:show(panel_viewer)
    
    self:refreshPanelViewer(panel_viewer)
    
    logger.info("DynamicPanelZoom: New PanelViewer shown")
    
    self:scheduleNextPanelPreload()
    
    return true -- Success, new viewer created
end

function PanelZoomIntegration:buildAdvancedOptionsMenu()
    local function setStandardMargin(value)
        self.standard_margin_percent = value
        self:cancelPanelPreload()
        self:refreshCurrentPanelIfActive()
    end

    return {
        {
            text = _("Debug Logs"),
            checked_func = function() return self.debug_log_panels or self.dump_analysis_pgm end,
            callback = function()
                self:setDebugLogsEnabled(not (self.debug_log_panels or self.dump_analysis_pgm))
            end,
            separator = true,
        },
        {
            text = _("Reading direction"),
            sub_item_table = {
                {
                    text = _("Left-to-Right (LTR)"),
                    checked_func = function()
                        return self.reading_direction_override == "ltr" or self.reading_direction_override == nil
                    end,
                    callback = function()
                        self.reading_direction_override = "ltr"
                        logger.info("DynamicPanelZoom: Reading direction override set to LTR")
                        self._panel_cache = {}
                        self:cancelPanelPreload()
                        if self._current_imgviewer and #self.current_panels > 0 then
                            self:refreshCurrentPanelIfActive()
                        else
                            self:replaceCurrentPanels({})
                        end
                    end,
                },
                {
                    text = _("Right-to-Left (RTL)"),
                    checked_func = function()
                        return self.reading_direction_override == "rtl"
                    end,
                    callback = function()
                        self.reading_direction_override = "rtl"
                        logger.info("DynamicPanelZoom: Reading direction override set to RTL")
                        self._panel_cache = {}
                        self:cancelPanelPreload()
                        if self._current_imgviewer and #self.current_panels > 0 then
                            self:refreshCurrentPanelIfActive()
                        else
                            self:replaceCurrentPanels({})
                        end
                    end,
                },
            },
            separator = true,
        },
        {
            text = _("Next panel tap zone"),
            sub_item_table = {
                {
                    text = _("Auto (based on reading direction)"),
                    checked_func = function() return self.panelzoom_tap_forward_zone == "auto" end,
                    callback = function()
                        self.panelzoom_tap_forward_zone = "auto"
                        logger.info("DynamicPanelZoom: Tap forward zone set to auto")
                    end,
                },
                {
                    text = _("Left side"),
                    checked_func = function() return self.panelzoom_tap_forward_zone == "left" end,
                    callback = function()
                        self.panelzoom_tap_forward_zone = "left"
                        logger.info("DynamicPanelZoom: Tap forward zone set to left")
                    end,
                },
                {
                    text = _("Right side"),
                    checked_func = function() return self.panelzoom_tap_forward_zone == "right" end,
                    callback = function()
                        self.panelzoom_tap_forward_zone = "right"
                        logger.info("DynamicPanelZoom: Tap forward zone set to right")
                    end,
                },
            },
            separator = true,
        },
        {
            text = _("Standard panel settings"),
            sub_item_table = {
                {
                    text = _("Show adjacent page content"),
                    checked_func = function() return self.show_adjacent_panels end,
                    callback = function()
                        self.show_adjacent_panels = not self.show_adjacent_panels
                        self:cancelPanelPreload()
                        self:refreshCurrentPanelIfActive()
                    end,
                },
                {
                    text = _("Padding around panel"),
                    sub_item_table = {
                        {
                            text = _("0% (None)"),
                            checked_func = function() return self.standard_margin_percent == 0.0 end,
                            callback = function() setStandardMargin(0.0) end,
                        },
                        {
                            text = _("2% (Tight)"),
                            checked_func = function() return self.standard_margin_percent == 0.02 end,
                            callback = function() setStandardMargin(0.02) end,
                        },
                        {
                            text = _("5% (Normal)"),
                            checked_func = function() return self.standard_margin_percent == 0.05 end,
                            callback = function() setStandardMargin(0.05) end,
                        },
                        {
                            text = _("10% (Wide)"),
                            checked_func = function() return self.standard_margin_percent == 0.10 end,
                            callback = function() setStandardMargin(0.10) end,
                        },
                    },
                },
            },
            separator = true,
        },
        {
            text = _("Hold-to-zoom settings"),
            sub_item_table = {
                {
                    text = _("Allow panel Zoom"),
                    checked_func = function() return self.hold_to_zoom_enabled end,
                    callback = function()
                        self.hold_to_zoom_enabled = not self.hold_to_zoom_enabled
                        logger.info("DynamicPanelZoom: Hold-to-zoom set to " .. tostring(self.hold_to_zoom_enabled))
                    end,
                    separator = true,
                },
                {
                    text = _("Hold-to-Zoom padding"),
                    sub_item_table = {
                        {
                            text = _("2% (Tight)"),
                            checked_func = function() return self.zoom_margin_percent == 0.02 end,
                            callback = function() self.zoom_margin_percent = 0.02 end,
                        },
                        {
                            text = _("5% (Normal)"),
                            checked_func = function() return self.zoom_margin_percent == 0.05 end,
                            callback = function() self.zoom_margin_percent = 0.05 end,
                        },
                        {
                            text = _("10% (Wide)"),
                            checked_func = function() return self.zoom_margin_percent == 0.10 end,
                            callback = function() self.zoom_margin_percent = 0.10 end,
                        },
                        {
                            text = _("20% (Context)"),
                            checked_func = function() return self.zoom_margin_percent == 0.20 end,
                            callback = function() self.zoom_margin_percent = 0.20 end,
                        },
                    },
                },
                {
                    text = _("Initial zoom level"),
                    sub_item_table = {
                        {
                            text = _("Fit to screen (1.0x)"),
                            checked_func = function() return self.zoom_initial_scale == 1.0 end,
                            callback = function() self.zoom_initial_scale = 1.0 end,
                        },
                        {
                            text = _("Slight Zoom (1.2x)"),
                            checked_func = function() return self.zoom_initial_scale == 1.2 end,
                            callback = function() self.zoom_initial_scale = 1.2 end,
                        },
                        {
                            text = _("Medium Zoom (1.5x)"),
                            checked_func = function() return self.zoom_initial_scale == 1.5 end,
                            callback = function() self.zoom_initial_scale = 1.5 end,
                        },
                        {
                            text = _("Heavy Zoom (2.0x)"),
                            checked_func = function() return self.zoom_initial_scale == 2.0 end,
                            callback = function() self.zoom_initial_scale = 2.0 end,
                        },
                    },
                },
            },
            separator = true,
        },
        {
            text = _("Fall back to text selection"),
            checked_func = function() return self:getFallbackToTextSelection() end,
            callback = function()
                self:toggleFallbackToTextSelection()
            end,
        },
    }
end

function PanelZoomIntegration:buildHowToUseMenu()
    local function helpRow(text, separator)
        return {
            text = text,
            enabled_func = function() return false end,
            separator = separator,
        }
    end

    return {
        helpRow(_("Start: long-press a panel on the page."), true),
        helpRow(_("Next panel: tap the forward side.")),
        helpRow(_("Previous panel: tap the back side.")),
        helpRow(_("After last panel: tap forward for next page.")),
        helpRow(_("Before first panel: tap back for previous page."), true),
        helpRow(_("Basic mode: trimmed overview, then 4 detailed views."), true),
        helpRow(_("Tap the bottom-left icon to toggle Basic mode."), true),
        helpRow(_("Free zoom: long-press while viewing a panel.")),
        helpRow(_("If taps feel reversed, adjust direction.")),
        helpRow(_("Or adjust the next panel tap zone."), true),
        helpRow(_("Tested on Kobo Clara Colour.")),
        helpRow(_("Optimized for Kobo G2 colour profile."), true),
        helpRow(_("Koreader defaults when active:")),
        helpRow(_("Rotation: landscape")),
        helpRow(_("Page crop: none")),
        helpRow(_("Page fit: full")),
        helpRow(_("View mode: page")),
        helpRow(_("Contrast: 2")),
        helpRow(_("Dithering: on")),
    }
end

function PanelZoomIntegration:buildPanelZoomMenu()
    return {
        {
            text = _("Activate Plugin"),
            checked_func = function() return self.plugin_enabled end,
            callback = function()
                self:setPluginEnabled(not self.plugin_enabled)
            end,
        },
        {
            text = _("Basic 4 Panels Mode"),
            checked_func = function() return self.basic_three_panel_mode end,
            callback = function()
                self:setBasicThreePanelMode(not self.basic_three_panel_mode)
            end,
            separator = true,
        },
        {
            text = _("How to use"),
            sub_item_table = self:buildHowToUseMenu(),
            separator = true,
        },
        {
            text = _("Advanced Options"),
            sub_item_table = self:buildAdvancedOptionsMenu(),
        },
    }
end

function PanelZoomIntegration:patchPanelZoomMenuItem(menu_items)
    if not menu_items then return end
    menu_items.panel_zoom_options = menu_items.panel_zoom_options or {}
    menu_items.panel_zoom_options.text = _("Advanced Panel Zoom Plugin")
    menu_items.panel_zoom_options.sub_item_table = self:buildPanelZoomMenu()
end

function PanelZoomIntegration:addToMainMenu(menu_items)
    if self.ui and self.ui.paging then
        self:setupPanelZoomMenuIntegration()
        self:patchPanelZoomMenuItem(menu_items)
    end
end

-- Integrate with KOReader's existing panel zoom menu entry.
function PanelZoomIntegration:setupPanelZoomMenuIntegration()
    if not self._original_genPanelZoomMenu and self.ui.highlight and self.ui.highlight.genPanelZoomMenu then
        self._original_genPanelZoomMenu = self.ui.highlight.genPanelZoomMenu
        self.ui.highlight.genPanelZoomMenu = function()
            return self:buildPanelZoomMenu()
        end
        logger.info("DynamicPanelZoom: Integrated advanced panel zoom options into KOReader menu")
    end
    if not self._original_highlight_addToMainMenu and self.ui.highlight and self.ui.highlight.addToMainMenu then
        self._original_highlight_addToMainMenu = self.ui.highlight.addToMainMenu
        self.ui.highlight.addToMainMenu = function(highlight, menu_items)
            self._original_highlight_addToMainMenu(highlight, menu_items)
            self:patchPanelZoomMenuItem(menu_items)
        end
    end
    if self.ui and self.ui.menu and self.ui.menu.menu_items then
        self:patchPanelZoomMenuItem(self.ui.menu.menu_items)
    end
end

-- Restore original panel zoom menu when plugin is disabled
function PanelZoomIntegration:restorePanelZoomMenu()
    -- Guard against multiple restoration calls
    if not self._original_genPanelZoomMenu and not self._original_highlight_addToMainMenu then
        return -- Already restored or never stored
    end
    
    if self._original_genPanelZoomMenu and self.ui.highlight then
        self.ui.highlight.genPanelZoomMenu = self._original_genPanelZoomMenu
        self._original_genPanelZoomMenu = nil
        logger.info("DynamicPanelZoom: Restored original panel zoom menu")
    end
    if self._original_highlight_addToMainMenu and self.ui.highlight then
        self.ui.highlight.addToMainMenu = self._original_highlight_addToMainMenu
        self._original_highlight_addToMainMenu = nil
    end
end

-- Refresh current panel if viewer is active (for reading direction changes)
function PanelZoomIntegration:refreshCurrentPanelIfActive()
    if self._current_imgviewer and self.integration_mode and #self.current_panels > 0 then
        logger.info("DynamicPanelZoom: Refreshing panel viewer with new reading direction")
        
        -- To ensure correct spatial flow, we must re-sort the panels
        -- by the new reading direction and map the current panel to its new index
        local old_panel = self.current_panels[self.current_panel_index]
        
        -- Import will automatically use the NEW reading direction and 
        -- either generate a new layout or pull it from the direction-specific cache.
        self:importToggleZoomPanels()
        
        -- Find the old panel in the newly sorted array so we stay on the same physical panel
        if old_panel and #self.current_panels > 0 then
            for i, p in ipairs(self.current_panels) do
                -- Compare coordinates (allowing tiny float variations)
                if math.abs(p.x - old_panel.x) < 0.001 and math.abs(p.y - old_panel.y) < 0.001 then
                    self.current_panel_index = i
                    break
                end
            end
        end
        
        -- Propagate reading direction immediately
        if self._current_imgviewer.updateReadingDirection then
            self._current_imgviewer:updateReadingDirection(self:getEffectiveReadingDirection())
        end
        self:displayCurrentPanel()
    end
end

-- Helper function: Calculate position to move panel center exactly to screen center
function PanelZoomIntegration:panelCenterToScreenPosition(panel, rect, dim, zoom)
    if not panel or not rect or not dim or not zoom then
        logger.warn("DynamicPanelZoom: Invalid parameters in panelCenterToScreenPosition")
        -- Fallback to screen center
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        return {
            x = math.floor(screen_w / 2),
            y = math.floor(screen_h / 2),
        }
    end
    
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Absolute panel center (page space) from normalized JSON coordinates
    local panel_cx = (panel.x + panel.w / 2) * dim.w
    local panel_cy = (panel.y + panel.h / 2) * dim.h

    -- Center inside rect (page space)
    local cx_in_rect = panel_cx - rect.x
    local cy_in_rect = panel_cy - rect.y

    -- Scaled center (screen space)
    local cx_screen = cx_in_rect * zoom
    local cy_screen = cy_in_rect * zoom

    -- Translation to move center to screen center
    return {
        x = math.floor(screen_w / 2 - cx_screen + 0.5),
        y = math.floor(screen_h / 2 - cy_screen + 0.5),
    }
end

return PanelZoomIntegration
