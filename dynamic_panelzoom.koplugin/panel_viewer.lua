--[[
PanelViewer - A custom image viewer designed specifically for panel navigation

This viewer is built from scratch using KOReader's widget system and APIs,
inspired by modern image rendering patterns. It provides optimized panel
viewing with custom padding, gesture handling, and smooth transitions.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local PanelViewer = InputContainer:extend{
    -- Core properties
    name = "PanelViewer",
    
    -- Image source (BlitBuffer or file path)
    image = nil,
    file = nil,
    
    -- Display properties
    fullscreen = true,
    covers_fullscreen = true,  -- Prevents UIManager from repainting widgets below us (avoids E-Ink flash on page change)
    buttons_visible = false,
    
    -- Panel-specific properties
    reading_direction = "ltr",
    panel_screen_rect = nil,

    -- Callbacks for navigation
    onNext = nil,
    onPrev = nil,
    onClose = nil,
    onHold = nil,
    
    -- Internal state
    _image_bb = nil,
    _rendered_size = nil,
    _display_rect = nil,
    _previous_display_rect = nil,
    _panel_screen_rect = nil,
    _previous_panel_screen_rect = nil,
    _scaled_image_bb = nil, -- Cached scaled image for display
    _is_dirty = false,
    _clear_only = false,
    _clear_luma = 255,
}

local function copyGeom(rect)
    if not rect then return nil end
    return Geom:new{
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
    }
end

function PanelViewer:init()
    -- Initialize touch zones for navigation
    self:setupTouchZones()
    
    -- Load and process the image
    self:loadImage()
    
    -- Calculate display dimensions
    self:calculateDisplayRect()

    if self.panel_screen_rect then
        self._panel_screen_rect = copyGeom(self.panel_screen_rect)
    end
    
    logger.info(string.format("PanelViewer: Initialized with image %dx%d", 
        self._rendered_size and self._rendered_size.w or 0,
        self._rendered_size and self._rendered_size.h or 0))
end

function PanelViewer:setupTouchZones()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    
    -- Define tap zones: Left 30% (prev), Right 30% (next), Center 40% (close)
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = screen_width,
                    h = screen_height
                }
            }
        },
        Hold = {
            GestureRange:new{
                ges = "hold",
                range = Geom:new{
                    x = 0, y = 0,
                    w = screen_width,
                    h = screen_height
                }
            }
        }
    }

    -- Register hardware keys (Boox, Kindle, Kobo, etc.).
    -- Using input groups rather than raw key names keeps this device-agnostic
    -- and automatically honors the user's "Invert page-turn buttons" setting.
    -- KeyClose is essential on touchless Kindles (K4 NT, K2/K3 Keyboard) where
    -- the center-tap exit is unreachable.
    -- Event names are prefixed Key* so they cannot collide with the onNext/
    -- onPrev/onClose *callback* fields the class exposes for tap dispatch.
    if Device:hasKeys() then
        self.key_events = {
            KeyNext  = { { Device.input.group.PgFwd } },
            KeyPrev  = { { Device.input.group.PgBack } },
            KeyClose = { { Device.input.group.Back } },
        }
    end
end

function PanelViewer:loadImage()
    if not self.image and not self.file then
        logger.warn("PanelViewer: No image or file provided")
        return false
    end
    
    local image_bb = nil
    
    -- Load from BlitBuffer
    if self.image then
        image_bb = self.image
        logger.info("PanelViewer: Using provided BlitBuffer")
    -- Load from file with screen-size decoding for sharp rendering
    elseif self.file then
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        logger.info(string.format("PanelViewer: Loading image file at screen size %dx%d with dithering: %s", screen_w, screen_h, self.file))
        -- Pass screen dimensions to MuPDF for high-quality scaling during decode
        image_bb = RenderImage:renderImageFile(self.file, false, screen_w, screen_h)
        if not image_bb then
            logger.error("PanelViewer: Failed to load image file")
            return false
        end
    end
    
    self._image_bb = image_bb
    self._rendered_size = {
        w = image_bb:getWidth(),
        h = image_bb:getHeight()
    }
    
    return true
end

function PanelViewer:calculateDisplayRect()
    if not self._image_bb then return end

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local img_w = self._image_bb:getWidth()
    local img_h = self._image_bb:getHeight()

    local function round(x)
        return math.floor(x + 0.5)
    end

    -- ðŸ”’ Center-lock mode (panel center matching)
    if self.custom_position then
        self._display_rect = {
            x = self.custom_position.x,
            y = self.custom_position.y,
            w = img_w,
            h = img_h
        }
        self._scaled_image_bb = self._image_bb
        return
    end

    -- Default: centered image
    local display_x = round((screen_w - img_w) / 2)
    local display_y = round((screen_h - img_h) / 2)

    self._display_rect = {
        x = display_x,
        y = display_y,
        w = img_w,
        h = img_h
    }

    

    logger.info(string.format(
        "PanelViewer: Display rect %dx%d at (%d,%d) (1:1 blit)",
        img_w, img_h, display_x, display_y
    ))
end

function PanelViewer:onTap(_, ges)
    if not ges or not ges.pos then return false end
    
    local screen_w = Screen:getWidth()
    local x_pct = ges.pos.x / screen_w
    
    if x_pct > 0.7 then
        logger.info("PanelViewer: Right tap detected")
        if self.onTapRight then self.onTapRight() end
        return true
    elseif x_pct < 0.3 then
        logger.info("PanelViewer: Left tap detected")
        if self.onTapLeft then self.onTapLeft() end
        return true
    end
    
    -- Center tap: Close the viewer
    logger.info("PanelViewer: Center tap detected, closing viewer")
    if self.onClose then self.onClose() end
    return true
end

function PanelViewer:onHold(_, ges)
    logger.info("PanelViewer: Hold gesture detected, triggering zoom mode")
    if self.onHold then self.onHold() end
    return true
end

function PanelViewer:onKeyNext()
    logger.info("PanelViewer: PgFwd key received, forwarding to next panel")
    if self.reading_direction == "rtl" then
        if self.onTapLeft then self.onTapLeft() end
    else
        if self.onTapRight then self.onTapRight() end
    end
    return true
end

function PanelViewer:onKeyPrev()
    logger.info("PanelViewer: PgBack key received, forwarding to previous panel")
    if self.reading_direction == "rtl" then
        if self.onTapRight then self.onTapRight() end
    else
        if self.onTapLeft then self.onTapLeft() end
    end
    return true
end

function PanelViewer:onKeyClose()
    logger.info("PanelViewer: Back key received, closing viewer")
    if self.onClose then self.onClose() end
    return true
end

function PanelViewer:paintTo(bb, x, y)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local bg_luma = self._clear_only and self._clear_luma or 255
    bb:paintRect(0, 0, screen_w, screen_h, Blitbuffer.Color8(bg_luma))

    if self._clear_only then
        self._is_dirty = false
        return
    end

    if not self._image_bb or not self._scaled_image_bb then return end

    -- Get screen-space rectangle (single source of truth)
    local screen_rect = self:getScreenRect()

    -- Dithering avoids banding artifacts on grayscale E-Ink displays.
    if Screen.sw_dithering then
        bb:ditherblitFrom(self._scaled_image_bb, screen_rect.x, screen_rect.y, 0, 0, screen_rect.w, screen_rect.h)
    else
        bb:blitFrom(self._scaled_image_bb, screen_rect.x, screen_rect.y, 0, 0, screen_rect.w, screen_rect.h)
    end

    self._is_dirty = false
end

local function unionRects(a, b)
    if not a then return copyGeom(b) end
    if not b then return copyGeom(a) end

    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)

    return Geom:new{
        x = x0,
        y = y0,
        w = x1 - x0,
        h = y1 - y0,
    }
end

local function paddedScreenRect(rect, padding)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    if not rect then
        return Geom:new{x = 0, y = 0, w = screen_w, h = screen_h}
    end

    local x0 = math.max(0, math.floor(rect.x - padding))
    local y0 = math.max(0, math.floor(rect.y - padding))
    local x1 = math.min(screen_w, math.ceil(rect.x + rect.w + padding))
    local y1 = math.min(screen_h, math.ceil(rect.y + rect.h + padding))

    if x1 <= x0 or y1 <= y0 then
        return Geom:new{x = 0, y = 0, w = screen_w, h = screen_h}
    end

    return Geom:new{x = x0, y = y0, w = x1 - x0, h = y1 - y0}
end

function PanelViewer:setClearOnly(clear_only, clear_luma)
    self._clear_only = clear_only and true or false
    self._clear_luma = self._clear_only and (clear_luma or 255) or 255
    self._is_dirty = true
end

function PanelViewer:getScreenRect()
    -- Single source of truth for screen-space coordinates
    -- Future-proof: supports animations, transforms, partial redraws
    if not self._display_rect then
        -- Fallback: full screen
        return {
            x = 0,
            y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight()
        }
    end
    
    return {
        x = self._display_rect.x,
        y = self._display_rect.y,
        w = self._display_rect.w,
        h = self._display_rect.h
    }
end

function PanelViewer:getSize()
    return Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight()
    }
end

function PanelViewer:updateImage(new_image)
    -- The viewer owns its image buffer (callers hand over private copies):
    -- free the previous one on replacement.
    if self._image_bb and self._image_bb ~= new_image and self._image_bb.free then
        self._image_bb:free()
    end

    self:rememberDisplayRect()

    self.image = new_image
    self._image_bb = new_image
    self:loadImage()
    self:calculateDisplayRect()
    self._is_dirty = true

    logger.info("PanelViewer: Image updated")
end

function PanelViewer:update(refresh_type, refresh_region, refresh_dither)
    refresh_type = refresh_type or "ui"
    if refresh_region == nil and refresh_type ~= "full" then
        refresh_region = self.dimen
    end
    if refresh_dither == nil then
        refresh_dither = Screen.sw_dithering
    end

    self._is_dirty = true
    UIManager:setDirty(self, function()
        return refresh_type, refresh_region, refresh_dither
    end)

    local region_desc = refresh_region and string.format(
        "%d,%d %dx%d",
        refresh_region.x, refresh_region.y, refresh_region.w, refresh_region.h
    ) or "full-screen"
    logger.info(string.format(
        "PanelViewer: Update called refresh=%s region=%s dither=%s",
        tostring(refresh_type), region_desc, tostring(refresh_dither)
    ))
end

function PanelViewer:updateReadingDirection(direction)
    self.reading_direction = direction or "ltr"
    logger.info(string.format("PanelViewer: Reading direction set to %s", self.reading_direction))
end

function PanelViewer:updateCustomPosition(custom_position)
    self:rememberDisplayRect()
    self.custom_position = custom_position
    -- Recalculate display rect with new position
    self:calculateDisplayRect()
    logger.info("PanelViewer: Custom position updated and display rect recalculated")
end

function PanelViewer:rememberDisplayRect()
    if not self._previous_display_rect and self._display_rect then
        self._previous_display_rect = copyGeom(self._display_rect)
    end
end

function PanelViewer:rememberPanelScreenRect()
    if not self._previous_panel_screen_rect and self._panel_screen_rect then
        self._previous_panel_screen_rect = copyGeom(self._panel_screen_rect)
    end
end

function PanelViewer:updatePanelScreenRect(panel_screen_rect)
    self:rememberPanelScreenRect()
    self._panel_screen_rect = copyGeom(panel_screen_rect)

    if self._panel_screen_rect then
        logger.info(string.format(
            "PanelViewer: Panel screen rect updated to %d,%d %dx%d",
            self._panel_screen_rect.x,
            self._panel_screen_rect.y,
            self._panel_screen_rect.w,
            self._panel_screen_rect.h
        ))
    end
end

function PanelViewer:consumeTransitionClearRegion()
    local previous_panel = self._previous_panel_screen_rect
    local current_panel = self._panel_screen_rect
    local previous_display = self._previous_display_rect

    self._previous_panel_screen_rect = nil
    self._previous_display_rect = nil

    local had_previous = previous_panel ~= nil or previous_display ~= nil
    local clear_rect = previous_panel or previous_display or current_panel or self:getScreenRect()
    local draw_rect = had_previous
        and unionRects(clear_rect, current_panel or self:getScreenRect())
        or self:getScreenRect()

    local padding = 16
    local clear_region = paddedScreenRect(clear_rect, padding)
    local draw_region = paddedScreenRect(draw_rect, padding)

    logger.info(string.format(
        "PanelViewer: Transition region previous=%s panel=%s clear=%d,%d %dx%d draw=%d,%d %dx%d",
        tostring(had_previous),
        tostring(previous_panel ~= nil),
        clear_region.x, clear_region.y, clear_region.w, clear_region.h,
        draw_region.x, draw_region.y, draw_region.w, draw_region.h
    ))

    return clear_region, had_previous, draw_region
end

function PanelViewer:freeResources()
    -- The viewer owns its image buffer; _scaled_image_bb only aliases it.
    if self._image_bb and self._image_bb.free then
        self._image_bb:free()
    end
    self._image_bb = nil
    self.image = nil
    self._scaled_image_bb = nil
    self._previous_display_rect = nil
    self._panel_screen_rect = nil
    self._previous_panel_screen_rect = nil
    self._clear_only = false
    self._clear_luma = 255
    logger.info("PanelViewer: Resources freed")
end

-- Called by UIManager when the widget is closed (UIManager:close()).
function PanelViewer:onCloseWidget()
    self:freeResources()
end

function PanelViewer:close()
    UIManager:close(self)
end

return PanelViewer
