--[[
PanelDetect - pure-Lua comic panel detection.

Detects panel rectangles on a comic page using background-polarity estimation
and a recursive X-Y cut over pixel projection profiles with an ink tolerance.

The module has zero KOReader/FFI/OS dependencies on purpose: the exact same
file runs on-device (with an accessor over the KOPTContext render bitmap) and
on a desktop (with an accessor over a byte string), so the algorithm can be
developed and regression-tested without a device round-trip.

Input image should be a small grayscale render of the page; a long side of
~1000px is the intended operating point (kills halftone noise, keeps the
per-pixel cost bounded).

Coordinate conventions:
- accessor: pix(x, y) -> luminance 0..255, with x in [0, w-1], y in [0, h-1]
- output panels: {x, y, w, h} normalized to 0..1 page coordinates
]]

local PanelDetect = {
    VERSION = "1.0",
}

local DEFAULTS = {
    ink_delta        = 60,    -- |lum - background| above this counts as ink
    gutter_ink_tol   = 0.015, -- rows/cols with <= this ink fraction are gutter material
    strict_ink_tol   = 0.005, -- near-empty rows/cols: qualify as gutter at ANY thickness
    pure_delta       = 25,    -- |lum - background| below this counts as pure background
    gutter_min_purity = 0.85, -- thin gutters need one line this close to pure background
    thin_min_segment = 0.09,  -- thin gutters may not slice off less than this
                              -- fraction of the page (rejects the white channel
                              -- between speech bubbles near a panel's edge;
                              -- 0.09 still admits real narrow strip panels
                              -- like 052's right column)
    relaxed_ink_tol  = 0.03,  -- retry tolerance when the strict pass fails validation
    min_gutter_frac  = 0.006, -- minimal gutter thickness, fraction of the page dimension
    pad_frac         = 0.01,  -- padding added around each panel's ink bounding box
    min_side_frac    = 0.05,  -- discard panels with a side thinner than this
    min_area_frac    = 0.02,  -- discard panels smaller than this fraction of page area
    merge_iou        = 0.4,   -- merge panels whose overlap IoU exceeds this
    -- Sliver rejoin: a wide white channel between speech bubbles inside one
    -- panel can pass every gutter test; the give-away is the result — two
    -- aligned fragments, at least one far too short/narrow to be a panel.
    sliver_max_side  = 0.14,  -- fragment side that is "too small to be a panel"
    sliver_max_gap   = 0.03,  -- max gap between fragments to rejoin
    sliver_max_total = 0.55,  -- rejoined panel must stay this size or less
    sliver_align     = 0.90,  -- required extent overlap on the shared axis
    header_merge_min_cover = 0.85, -- two+ short top fragments spanning the
                                   -- body width are one panel header band
    header_single_max_h = 0.09, -- one very short caption band directly above
                                -- its body may be merged when it shares the
                                -- same width; taller stacked panels stay split
    header_single_min_cover = 0.92,
    side_caption_max_w = 0.16, -- narrow page-edge text strip attached to a
                               -- wide row panel, not a standalone strip panel
    side_caption_body_min_w = 0.58,
    side_caption_min_union = 0.84,
    side_caption_y_align = 0.92,
    side_caption_max_gap = 0.025,
    strip_row_max_h = 0.17, -- short panoramic rows may be cut by speech
                            -- balloon whitespace into side-by-side fragments
    strip_row_min_union = 0.84,
    strip_row_y_align = 0.88,
    strip_row_max_gap = 0.025,
    stacked_top_max_h = 0.22, -- two+ top fragments sitting on a lower body
                              -- and spanning the same column are one panel
    stacked_top_min_cover = 0.85,
    stacked_top_single_cover = 0.92,
    stacked_top_min_boundary_ink = 0.15,
    stacked_top_y_align = 0.80,
    stacked_top_max_gap = 0.03,
    stacked_top_max_total = 0.55,
    composite_grid_min_w = 0.80, -- one large top block can hide a 2x2 grid
                                 -- when crossed captions defeat the first cut
    composite_grid_min_h = 0.42,
    composite_grid_max_h = 0.65,
    composite_grid_max_y = 0.15,
    composite_grid_tol = 0.08,
    composite_grid_min_pure = 0.85,
    composite_grid_min_seg = 0.22,
    bottom_caption_min_count = 3, -- bottom-row panels can have captions/art
                                  -- protruding above the detected body
    bottom_caption_min_y = 0.60,
    bottom_caption_max_expand = 0.08,
    bottom_caption_block = 8,
    bottom_caption_stop_ink = 0.68,
    bottom_caption_stop_max_pure = 0.25,
    bottom_caption_min_ink = 0.10,
    bottom_caption_min_expand = 0.025,
    false_split_min_union = 0.80, -- side-by-side boxes spanning most of a row
                                  -- with no ink at the seam are likely one
                                  -- borderless/splash panel, not two panels
    false_split_max_y = 0.12,
    false_split_y_align = 0.92,
    false_split_max_gap = 0.02,
    false_split_min_art_seam_ink = 0.05,
    false_split_max_seam_ink = 0.10,
    false_split_max_side_ink = 0.30,
    false_split_max_blank_side_ink = 0.05,
    false_split_min_other_side_ink = 0.10,
    top_cluster_min_count = 3, -- three+ top fragments cut through artwork,
                               -- not blank gutters, are one wide top panel
    top_cluster_min_union = 0.85,
    top_cluster_y_align = 0.90,
    top_cluster_max_gap = 0.03,
    top_cluster_min_seam_ink = 0.20,
    top_cluster_max_side_ink = 0.75,
    side_stack_body_min_w = 0.55, -- big panel with a narrow right strip split
    side_stack_body_min_h = 0.30, -- into two+ pieces: rejoin the strip
    side_stack_max_w = 0.25,
    side_stack_max_gap = 0.03,
    side_stack_min_y_cover = 0.85,
    rescue_max_gap   = 0.08,  -- max gap when gluing an undersized fragment
                              -- (one the size filter would drop) onto its
                              -- best-aligned neighbor instead of losing it
    rescue_min_align = 0.60,  -- enough shared extent to be a sliced caption;
                              -- avoids gluing decorative logos onto panels
    rescue_max_count = 3,     -- more undersized fragments than this (or more
                              -- than half the boxes) means a shattered page,
                              -- not sliced-off captions: skip the rescue
    -- Occluded gutters: a real gutter crossed by artwork or caption boxes.
    -- Qualifies when a low-ish ink band sits directly between two dense ink
    -- lines (the borders of the adjacent panels, eroded by downscale blur).
    -- Only tried on large regions where no clean gutter exists on that axis.
    occluded_ink_tol    = 0.35, -- max ink fraction inside an occluded gutter row
    occluded_min_run    = 2,    -- min thickness of an occluded gutter
    occluded_border_ink = 0.50, -- ink fraction that counts as a panel border line
    occluded_border_dist = 8,   -- how far (rows) to look for the border lines
    occluded_min_region  = 0.25, -- only cut regions at least this fraction of the page
    occluded_max_span   = 0.50, -- max fraction of the band's cross-lines carrying ink
    occluded_min_segment = 0.15, -- min segment size an occluded cut may produce
    -- Last-chance pass: when the page would otherwise fall back to a single
    -- full-page panel, retry once with these looser occluded thresholds.
    -- Confined to that case so it cannot destabilize pages that already cut.
    occluded_ink_tol_loose  = 0.45,
    occluded_max_span_loose = 0.80,
    relaxed_min_coverage    = 0.70, -- passes 2/3 must explain most of the page
                                    -- or they are shredding art, not cutting
                                    -- real (occluded) gutters
    single_panel_min_coverage = 0.70, -- one large detected region from
                                      -- multiple leaves is a splash page;
    single_panel_min_area = 0.65, -- accept it instead of relaxing into
                                  -- random balloon/art crops
    single_panel_min_side = 0.55,
    min_panels       = 2,     -- fewer than this is not a segmentation -> full page
    max_panels       = 20,    -- more than this is shattered -> full page
    min_coverage     = 0.45,  -- accepted panels must cover this much of the page
    max_panel_area_hard = 0.80, -- a panel this big is "full page + crumbs":
                                -- never accept, not even as a soft result
    max_panel_area   = 0.55,  -- a panel covering this much page means the result
                              -- is "full page + crumbs", not a segmentation
    max_depth        = 8,
    border_frac      = 0.02,  -- ring thickness used for background sampling
    sample_step      = 2,     -- subsampling step for background sampling
    edge_inset_frac  = 0.005, -- ignore this much of every page edge: device
                              -- renders often carry a dark artifact line at
                              -- the extreme rows/columns, which would defeat
                              -- the margin trim (panels stuck at x=0, w=1)
}

local max, min, abs, floor = math.max, math.min, math.abs, math.floor

-- Convenience for hosts that hold the image as a row-major byte string
-- (the desktop test harness; also works with anything exposing :byte()).
function PanelDetect.accessorFromString(s, w)
    return function(x, y)
        return s:byte(y * w + x + 1)
    end
end

-- Median luminance of the outer border ring of the page. Panel gutters share
-- the page background color in the vast majority of layouts (white for
-- classic albums, black for night/space pages), and the outer margin is the
-- cheapest reliable sample of it. Full-bleed art defeats this by design: the
-- estimate then lands on artwork, no gutters are found, and the caller falls
-- back to a full-page panel, which is the desired behavior for splash pages.
local function estimateBackground(pix, w, h, o)
    local ring = max(2, floor(min(w, h) * o.border_frac + 0.5))
    local histo = {}
    for i = 0, 255 do histo[i] = 0 end
    local n = 0
    local step = o.sample_step
    for y = 0, h - 1, step do
        local is_band = (y < ring) or (y >= h - ring)
        for x = 0, w - 1, step do
            if is_band or x < ring or x >= w - ring then
                -- floor + clamp: guards against accessors returning floats or
                -- out-of-range values (histogram indexes by pixel value)
                local v = floor(pix(x, y))
                if v < 0 then v = 0 elseif v > 255 then v = 255 end
                histo[v] = histo[v] + 1
                n = n + 1
            end
        end
    end
    local half, acc = n / 2, 0
    for i = 0, 255 do
        acc = acc + histo[i]
        if acc >= half then return i end
    end
    return 255
end

-- One pass over a region: per-row and per-column ink counts, plus per-row and
-- per-column pure-background counts (pixels within pure_delta of the page
-- background). Purity separates true gutters (page-colored) from smooth
-- mid-tone areas inside artwork, which carry no "ink" but are not background.
-- Arrays are 1-based relative to the region origin.
local function scanRegion(pix, bg, delta, pure_delta, x0, y0, x1, y1)
    local row_ink, col_ink, row_pure, col_pure = {}, {}, {}, {}
    for i = 1, y1 - y0 do row_ink[i] = 0; row_pure[i] = 0 end
    for i = 1, x1 - x0 do col_ink[i] = 0; col_pure[i] = 0 end
    for y = y0, y1 - 1 do
        local ry = y - y0 + 1
        local acc, pure_acc = 0, 0
        for x = x0, x1 - 1 do
            local d = abs(pix(x, y) - bg)
            if d > delta then
                acc = acc + 1
                local rx = x - x0 + 1
                col_ink[rx] = col_ink[rx] + 1
            elseif d <= pure_delta then
                pure_acc = pure_acc + 1
                local rx = x - x0 + 1
                col_pure[rx] = col_pure[rx] + 1
            end
        end
        row_ink[ry] = acc
        row_pure[ry] = pure_acc
    end
    return row_ink, col_ink, row_pure, col_pure
end

-- First/last index (1-based) whose ink ratio exceeds the tolerance, i.e. the
-- content bounds of a projection. Returns nil for an empty projection.
local function contentBounds(ink, span, tol)
    local limit = tol * span
    local first, last
    for i = 1, #ink do
        if ink[i] > limit then
            first = first or i
            last = i
        end
    end
    return first, last
end

-- Maximal runs of low-ink indices strictly inside [first, last].
-- Each gutter is {s, e} in 1-based projection indices, inclusive.
-- A run qualifies either by thickness (>= min_run at the loose tolerance) or
-- by cleanliness: real BD gutters are often 1-2 analysis rows thick once scan
-- skew and downscale blur eat their edges, but their central row is
-- near-perfectly empty, which almost never happens inside artwork (panel
-- borders alone put ink on every interior row).
local function findGutters(ink, pure, span, tol, o, first, last, min_run, thin_seg)
    local limit = tol * span
    local strict_limit = o.strict_ink_tol * span
    local purity_limit = o.gutter_min_purity * span
    local gutters = {}
    local run_start, run_min, run_best_pure
    for i = first, last do
        if ink[i] <= limit then
            if not run_start then
                run_start, run_min, run_best_pure = i, ink[i], pure[i]
            else
                if ink[i] < run_min then run_min = ink[i] end
                if pure[i] > run_best_pure then run_best_pure = pure[i] end
            end
        elseif run_start then
            -- Thin runs qualify only when near-empty AND page-colored (what a
            -- skew/blur-eroded real gutter looks like; smooth mid-tone areas
            -- inside artwork are inkless but not background) AND far enough
            -- from the content bounds (the white channel between speech
            -- bubbles near a panel's edge is not a gutter).
            if i - run_start >= min_run
                or (run_min <= strict_limit and run_best_pure >= purity_limit
                    and (run_start - first) >= thin_seg
                    and (last - i + 1) >= thin_seg) then
                -- Qualify at the pass tolerance, but shrink the cut edges
                -- back to near-empty lines: at relaxed tolerance a row with
                -- only a sparse speech-bubble outline counts as "gutter",
                -- and cutting there slices the bubble top off its panel.
                -- If no near-empty core exists (noisy gutter), keep as is.
                local s, e = run_start, i - 1
                while s < e and ink[s] > strict_limit do s = s + 1 end
                while e > s and ink[e] > strict_limit do e = e - 1 end
                if ink[s] > strict_limit then s, e = run_start, i - 1 end
                gutters[#gutters + 1] = { s = s, e = e }
            end
            run_start = nil
        end
    end
    -- A run touching `last` cannot happen: contentBounds guarantees ink at `last`.
    return gutters
end

-- Gutters crossed by artwork: runs of rows/cols with moderate ink that are
-- sandwiched between dense ink lines (the adjacent panel borders, eroded by
-- downscale blur). This is what a BD gutter looks like when a character or a
-- caption box crosses it. Because artwork is full of moderate-ink bands, a
-- candidate must pass three additional checks before it may cut:
--   1. it is only searched for when NEITHER axis has a clean gutter,
--   2. the band must be mostly empty in 2D: ink concentrated in a narrow
--      crossing (checkBand), unlike artwork bands which are inked across
--      their whole span,
--   3. it must not slice off a sliver (min segment size).
-- checkBand(s, e) scans the band's perpendicular lines and returns the
-- fraction of them carrying ink.
local function findOccludedGutters(ink, span, first, last, o, checkBand)
    local limit = o.occl_tol * span
    local border = o.occluded_border_ink * span
    local dist = o.occluded_border_dist
    local min_seg = max(1, floor(o.occluded_min_segment * (last - first + 1) + 0.5))
    local function hasBorderLine(from, to)
        for i = max(first, from), min(last, to) do
            if ink[i] >= border then return true end
        end
        return false
    end
    local gutters = {}
    local run_start
    for i = first, last do
        if ink[i] <= limit then
            run_start = run_start or i
        elseif run_start then
            if i - run_start >= o.occluded_min_run
                and (run_start - first) >= min_seg
                and (last - i + 1) >= min_seg
                and hasBorderLine(run_start - dist, run_start - 1)
                and hasBorderLine(i, i + dist - 1)
                and checkBand(run_start, i - 1) <= o.occl_span then
                local g = { s = run_start, e = i - 1, min_ink = ink[run_start] }
                for k = run_start + 1, i - 1 do
                    if ink[k] < g.min_ink then g.min_ink = ink[k] end
                end
                -- The min-segment rule must also hold BETWEEN gutters: two
                -- cuts close together would isolate a sliver (e.g. a speech
                -- bubble band) that is not a panel. Keep the cleaner cut.
                local prev = gutters[#gutters]
                if prev and g.s - prev.e - 1 < min_seg then
                    if g.min_ink < prev.min_ink then
                        gutters[#gutters] = g
                    end
                else
                    gutters[#gutters + 1] = g
                end
            end
            run_start = nil
        end
    end
    return gutters
end

local function thickest(gutters)
    local best = 0
    for _, g in ipairs(gutters) do
        local t = g.e - g.s + 1
        if t > best then best = t end
    end
    return best
end

-- Recursive X-Y cut. Trims the region to its ink bounding box, then splits it
-- along every qualifying gutter of the axis holding the thickest gutter and
-- recurses into the resulting strips. Regions with no internal gutter on
-- either axis are emitted as leaves (in pixel coordinates, end-exclusive).
local function cut(pix, bg, o, tol, x0, y0, x1, y1, depth, leaves)
    if x1 <= x0 or y1 <= y0 then return end
    -- An undersized region is still emitted as a leaf (after trimming) so its
    -- content can be rescued onto a neighbor later: a speech-bubble band
    -- isolated between two cuts must not silently vanish. Only recursion is
    -- skipped for it (handled below via the two-panel area guard).
    local undersized_region = x1 - x0 < o.min_side_px_w or y1 - y0 < o.min_side_px_h

    local row_ink, col_ink, row_pure, col_pure = scanRegion(pix, bg, o.ink_delta, o.pure_delta, x0, y0, x1, y1)
    local rw, rh = x1 - x0, y1 - y0

    -- Trim at the strict tolerance regardless of the pass: relaxed-pass
    -- trimming would shave rows that hold only a sparse bubble outline.
    local trim_tol = min(tol, o.gutter_ink_tol)
    local ry0, ry1 = contentBounds(row_ink, rw, trim_tol)
    local rx0, rx1 = contentBounds(col_ink, rh, trim_tol)
    if not ry0 or not rx0 then return end -- empty region

    -- Trimmed content bounds in absolute pixels (end-exclusive).
    local tx0, tx1 = x0 + rx0 - 1, x0 + rx1
    local ty0, ty1 = y0 + ry0 - 1, y0 + ry1

    -- A region too small to contain two legal panels must not be subdivided:
    -- any cut would only produce fragments below the size filter, silently
    -- dropping content (e.g. the caption at the top of a narrow strip panel).
    local region_area = (tx1 - tx0) * (ty1 - ty0)
    if undersized_region
        or region_area < 2 * o.min_area_frac * o.page_w * o.page_h then
        leaves[#leaves + 1] = { x0 = tx0, y0 = ty0, x1 = tx1, y1 = ty1 }
        return
    end

    if depth < o.max_depth then
        local h_gutters = findGutters(row_ink, row_pure, rw, tol, o, ry0, ry1, o.min_gutter_rows, o.thin_seg_rows)
        local v_gutters = findGutters(col_ink, col_pure, rh, tol, o, rx0, rx1, o.min_gutter_cols, o.thin_seg_cols)
        -- Occluded gutters are a last resort: only when neither axis offers a
        -- clean cut (a gutterless-looking region), and only on large regions.
        if #h_gutters == 0 and #v_gutters == 0 then
            local delta = o.ink_delta
            if rh >= o.occluded_min_region * o.page_h then
                -- Fraction of the band's columns carrying any ink.
                local checkBandRows = function(s, e)
                    local inked = 0
                    for x = tx0, tx1 - 1 do
                        for y = y0 + s - 1, y0 + e - 1 do
                            if abs(pix(x, y) - bg) > delta then
                                inked = inked + 1
                                break
                            end
                        end
                    end
                    return inked / max(1, tx1 - tx0)
                end
                h_gutters = findOccludedGutters(row_ink, rw, ry0, ry1, o, checkBandRows)
            end
            if #h_gutters == 0 and rw >= o.occluded_min_region * o.page_w then
                -- Fraction of the band's rows carrying any ink.
                local checkBandCols = function(s, e)
                    local inked = 0
                    for y = ty0, ty1 - 1 do
                        for x = x0 + s - 1, x0 + e - 1 do
                            if abs(pix(x, y) - bg) > delta then
                                inked = inked + 1
                                break
                            end
                        end
                    end
                    return inked / max(1, ty1 - ty0)
                end
                v_gutters = findOccludedGutters(col_ink, rh, rx0, rx1, o, checkBandCols)
            end
        end

        local split_rows
        if #h_gutters > 0 and #v_gutters > 0 then
            split_rows = thickest(h_gutters) >= thickest(v_gutters)
        elseif #h_gutters > 0 then
            split_rows = true
        elseif #v_gutters > 0 then
            split_rows = false
        end

        if split_rows ~= nil then
            local gutters = split_rows and h_gutters or v_gutters
            local start = split_rows and ry0 or rx0
            local stop = split_rows and ry1 or rx1
            local origin = split_rows and y0 or x0
            local seg_start = start
            for i = 1, #gutters + 1 do
                local seg_end = gutters[i] and (gutters[i].s - 1) or stop
                if seg_end >= seg_start then
                    -- Segment bounds in absolute pixels (end-exclusive).
                    local a0 = origin + seg_start - 1
                    local a1 = origin + seg_end
                    if split_rows then
                        cut(pix, bg, o, tol, tx0, a0, tx1, a1, depth + 1, leaves)
                    else
                        cut(pix, bg, o, tol, a0, ty0, a1, ty1, depth + 1, leaves)
                    end
                end
                if gutters[i] then seg_start = gutters[i].e + 1 end
            end
            return
        end
    end

    leaves[#leaves + 1] = { x0 = tx0, y0 = ty0, x1 = tx1, y1 = ty1 }
end

local function iou(a, b)
    local ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
    local iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
    local inter = ix * iy
    if inter <= 0 then return 0 end
    return inter / (a.w * a.h + b.w * b.h - inter)
end

local function mergeOverlapping(panels, threshold)
    local merged = true
    while merged do
        merged = false
        for i = 1, #panels do
            local a = panels[i]
            if a then
                for j = i + 1, #panels do
                    local b = panels[j]
                    if b and iou(a, b) > threshold then
                        local nx = min(a.x, b.x)
                        local ny = min(a.y, b.y)
                        a.w = max(a.x + a.w, b.x + b.w) - nx
                        a.h = max(a.y + a.h, b.y + b.h) - ny
                        a.x, a.y = nx, ny
                        panels[j] = false
                        merged = true
                    end
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

-- Extent overlap of two panels on one axis, relative to the LARGER extent:
-- fragments of one panel share (nearly) the same extent, while a small box
-- contained in a big one (caption box vs. full-width panel) must NOT count
-- as aligned or the rejoin would swallow it.
local function axisAlign(a0, a1, b0, b1)
    local inter = min(a1, b1) - max(a0, b0)
    if inter <= 0 then return 0 end
    return inter / max(a1 - a0, b1 - b0)
end

-- Rejoin panel fragments produced by a white channel inside one panel (e.g.
-- between stacked speech bubbles): two aligned neighbors where at least one
-- is too small to be a real panel and the union is still panel-sized.
local function mergeSlivers(panels, o)
    local merged = true
    while merged do
        merged = false
        local best_i, best_j, best_gap, best_total
        for i = 1, #panels do
            local a = panels[i]
            if a then
                for j = i + 1, #panels do
                    local b = panels[j]
                    if b then
                        -- Vertically stacked fragments sharing the x extent
                        -- ONLY: short full-width bands are caption/bubble
                        -- fragments, but narrow full-height strips are
                        -- legitimate BD panels and must never rejoin sideways.
                        -- (Measured on the fixture corpus: a drawn white slit
                        -- through one panel is pixel-identical to a real thin
                        -- gutter beside a strip panel -- same 2-4 px pure
                        -- channel, same solid-ink flanks, same fragment
                        -- geometry -- so a sideways rejoin cannot be gated
                        -- safely and a rare slit split is the softer failure.)
                        local join = false
                        if axisAlign(a.x, a.x + a.w, b.x, b.x + b.w) >= o.sliver_align then
                            local gap = max(a.y, b.y) - min(a.y + a.h, b.y + b.h)
                            local total = max(a.y + a.h, b.y + b.h) - min(a.y, b.y)
                            join = gap <= o.sliver_max_gap and total <= o.sliver_max_total
                                and min(a.h, b.h) <= o.sliver_max_side
                            if join then
                                local norm_gap = max(0, gap)
                                if not best_i or norm_gap < best_gap
                                    or (norm_gap == best_gap and total < best_total) then
                                    best_i, best_j = i, j
                                    best_gap, best_total = norm_gap, total
                                end
                            end
                        end
                    end
                end
            end
        end
        if best_i then
            local a, b = panels[best_i], panels[best_j]
            local nx = min(a.x, b.x)
            local ny = min(a.y, b.y)
            a.w = max(a.x + a.w, b.x + b.w) - nx
            a.h = max(a.y + a.h, b.y + b.h) - ny
            a.x, a.y = nx, ny
            panels[best_j] = false
            merged = true
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

-- Rejoin a single panel split into several short header/caption fragments
-- above one body region. This is deliberately stricter than mergeSlivers:
-- it needs at least two short fragments whose union spans nearly the whole
-- body width, so ordinary side-by-side panels do not get swallowed.
local function mergeHeaderFragments(panels, o)
    local merged = true
    while merged do
        merged = false
        for i = 1, #panels do
            local body = panels[i]
            if body and body.h >= 0.18 then
                local parts = {}
                local ux0, ux1, uy0, uy1
                for j = 1, #panels do
                    local p = panels[j]
                    if p and i ~= j and p.h <= o.sliver_max_side then
                        local overlap_x = min(body.x + body.w, p.x + p.w) - max(body.x, p.x)
                        local vertical_gap = body.y - (p.y + p.h)
                        if overlap_x > 0
                            and vertical_gap <= o.sliver_max_gap
                            and p.y <= body.y
                            and p.y + p.h >= body.y - o.sliver_max_gap then
                            parts[#parts + 1] = j
                            ux0 = ux0 and min(ux0, p.x) or p.x
                            ux1 = ux1 and max(ux1, p.x + p.w) or (p.x + p.w)
                            uy0 = uy0 and min(uy0, p.y) or p.y
                            uy1 = uy1 and max(uy1, p.y + p.h) or (p.y + p.h)
                        end
                    end
                end
                if #parts >= 1 then
                    local cover = (min(body.x + body.w, ux1) - max(body.x, ux0)) / body.w
                    local total_h = max(body.y + body.h, uy1) - min(body.y, uy0)
                    local single_ok = #parts == 1
                        and cover >= o.header_single_min_cover
                        and (uy1 - uy0) <= o.header_single_max_h
                    local multi_ok = #parts >= 2 and cover >= o.header_merge_min_cover
                    if (single_ok or multi_ok)
                        and (ux1 - ux0) <= body.w * 1.15
                        and total_h <= o.sliver_max_total then
                        local nx = min(body.x, ux0)
                        local ny = min(body.y, uy0)
                        body.w = max(body.x + body.w, ux1) - nx
                        body.h = max(body.y + body.h, uy1) - ny
                        body.x, body.y = nx, ny
                        for _, j in ipairs(parts) do panels[j] = false end
                        merged = true
                    end
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

-- Rescue fragments the size filter is about to drop: a caption or speech
-- bubble sliced off its panel is glued onto the best-aligned neighbor
-- instead of silently disappearing from the reading flow. Safe by
-- construction: only fragments too small to be a real panel are ever moved,
-- so two legitimate panels can never be merged by this pass.
local function rescueUndersized(panels, o)
    local function undersized(p)
        return p.w < o.min_side_frac or p.h < o.min_side_frac
            or p.w * p.h < o.min_area_frac
    end
    -- A page that is mostly slivers is a shattered splash, not panels with
    -- captions: dropping the slivers there lets the validity gate reject the
    -- result and fall back to the full page, which is the right outcome.
    local small = 0
    for _, p in ipairs(panels) do
        if undersized(p) then small = small + 1 end
    end
    if small > o.rescue_max_count or 2 * small > #panels then
        return panels
    end
    local moved = true
    while moved do
        moved = false
        for i = 1, #panels do
            local p = panels[i]
            if p and undersized(p) then
                local best, best_align
                for j = 1, #panels do
                    local q = panels[j]
                    if q and j ~= i then
                        local x_align = axisAlign(p.x, p.x + p.w, q.x, q.x + q.w)
                        local y_align = axisAlign(p.y, p.y + p.h, q.y, q.y + q.h)
                        local y_gap = max(p.y, q.y) - min(p.y + p.h, q.y + q.h)
                        local x_gap = max(p.x, q.x) - min(p.x + p.w, q.x + q.w)
                        local align = 0
                        if y_gap <= o.rescue_max_gap and x_align > align then
                            align = x_align -- stacked candidate
                        end
                        if x_gap <= o.rescue_max_gap and y_align > align then
                            align = y_align -- side-by-side candidate
                        end
                        if align >= o.rescue_min_align and (not best or align > best_align) then
                            best, best_align = q, align
                        end
                    end
                end
                if best then
                    local nx = min(p.x, best.x)
                    local ny = min(p.y, best.y)
                    best.w = max(p.x + p.w, best.x + best.w) - nx
                    best.h = max(p.y + p.h, best.y + best.h) - ny
                    best.x, best.y = nx, ny
                    panels[i] = false
                    moved = true
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

-- Leaves (pixel rects) -> padded, normalized, rejoined, size-filtered panels.
-- The size filter runs LAST: an undersized fragment (a caption sliced off its
-- panel) must first get its chance to rejoin, or its content silently
-- disappears from the reading flow.
local function finalizePanels(leaves, w, h, o)
    local panels = {}
    local pad_x, pad_y = o.pad_frac * w, o.pad_frac * h
    for _, l in ipairs(leaves) do
        local x0 = max(0, l.x0 - pad_x)
        local y0 = max(0, l.y0 - pad_y)
        local x1 = min(w, l.x1 + pad_x)
        local y1 = min(h, l.y1 + pad_y)
        panels[#panels + 1] = {
            x = x0 / w, y = y0 / h,
            w = (x1 - x0) / w, h = (y1 - y0) / h,
        }
    end
    panels = mergeOverlapping(panels, o.merge_iou)
    panels = mergeHeaderFragments(panels, o)
    panels = mergeSlivers(panels, o)
    panels = mergeHeaderFragments(panels, o)
    panels = rescueUndersized(panels, o)
    local out = {}
    for _, p in ipairs(panels) do
        if p.w >= o.min_side_frac and p.h >= o.min_side_frac
            and p.w * p.h >= o.min_area_frac then
            out[#out + 1] = p
        end
    end
    return out
end

-- Artwork continuity across a horizontal boundary: the MINIMUM per-row ink
-- ratio over the whole seam band [ya, yb] (plus a small margin), over a
-- given x-range. A real gutter -- even a heavily occluded one -- always
-- contains at least one near-empty row; a cut through continuous artwork
-- does not. The band must cover the full seam between the two boxes' raw
-- ink bounds: a fixed thin band around the midpoint can land entirely
-- inside a panel when one leaf was trimmed short of its true edge.
local function boundaryInk(pix, bg, o, w, h, xa, xb, ya, yb)
    if ya > yb then ya, yb = yb, ya end
    local y0 = floor(ya * h + 0.5)
    local y1 = floor(yb * h + 0.5)
    local x0 = max(0, floor(xa * w))
    local x1 = min(w - 1, floor(xb * w))
    if x1 <= x0 then return 0 end
    local span = x1 - x0 + 1
    local best = 1
    for y = max(0, y0 - 2), min(h - 1, y1 + 2) do
        local ink = 0
        for x = x0, x1 do
            if abs(pix(x, y) - bg) > o.ink_delta then
                ink = ink + 1
            end
        end
        local ratio = ink / span
        if ratio < best then best = ratio end
    end
    return best
end

-- Rejoin partition leftovers: when an occluded cut splits one panel into a
-- full-width strip plus a narrower leftover next to inset panels, the two
-- fragments are vertically adjacent, edge-aligned, and — the give-away that
-- separates them from genuinely stacked panels — artwork crosses their
-- shared boundary (a real gutter there would be near-empty).
local function mergePartitionLeftovers(panels, pix, bg, o, w, h)
    local merged = true
    while merged do
        merged = false
        for i = 1, #panels do
            local a = panels[i]
            if a then
                for j = 1, #panels do
                    local b = panels[j]
                    if b and i ~= j then
                        local wide, narrow = a, b
                        if narrow.w > wide.w then wide, narrow = b, a end
                        local upper = (a.y <= b.y) and a or b
                        local lower = (upper == a) and b or a
                        local gap = lower.y - (upper.y + upper.h)
                        local left_aligned = abs(wide.x - narrow.x) <= 0.02
                        local right_aligned = abs((wide.x + wide.w) - (narrow.x + narrow.w)) <= 0.02
                        if wide.w >= 1.5 * narrow.w
                            and gap <= 0.03 and gap >= -0.06
                            and (left_aligned or right_aligned)
                            and boundaryInk(pix, bg, o, w, h,
                                narrow.x, narrow.x + narrow.w,
                                upper.y + upper.h - o.pad_frac,
                                lower.y + o.pad_frac) >= 0.45 then
                            local nx = min(a.x, b.x)
                            local ny = min(a.y, b.y)
                            a.w = max(a.x + a.w, b.x + b.w) - nx
                            a.h = max(a.y + a.h, b.y + b.h) - ny
                            a.x, a.y = nx, ny
                            panels[j] = false
                            merged = true
                        end
                    end
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

local function verticalBandInk(pix, bg, o, w, h, xc, ya, yb, x_from, x_to)
    local x0 = max(0, floor(xc + x_from))
    local x1 = min(w - 1, floor(xc + x_to))
    if x1 < x0 then return 0 end
    local py0 = max(0, floor(ya * h + 0.5))
    local py1 = min(h - 1, floor(yb * h + 0.5))
    local trim = max(2, floor((py1 - py0 + 1) * 0.12 + 0.5))
    py0, py1 = py0 + trim, py1 - trim
    if py1 < py0 then return 0 end
    local ink, total = 0, 0
    for y = py0, py1 do
        for x = x0, x1 do
            total = total + 1
            if abs(pix(x, y) - bg) > o.ink_delta then
                ink = ink + 1
            end
        end
    end
    return ink / max(1, total)
end

-- Rejoin a wide borderless/splash row that was cut by an empty vertical
-- channel inside the artwork. Real side-by-side panels usually have heavy ink
-- at one or both edges of the gutter; a false split has a blank seam and blank
-- side bands because there is no panel border there.
local function mergeFalseHorizontalSplits(panels, pix, bg, o, w, h)
    local merged = true
    while merged do
        merged = false
        local best_i, best_j, best_union
        for i = 1, #panels do
            local a = panels[i]
            if a then
                for j = i + 1, #panels do
                    local b = panels[j]
                    if b then
                        local left, right = a, b
                        if right.x < left.x then left, right = right, left end
                        local y_align = axisAlign(left.y, left.y + left.h, right.y, right.y + right.h)
                        local gap = right.x - (left.x + left.w)
                        local ux0 = min(left.x, right.x)
                        local ux1 = max(left.x + left.w, right.x + right.w)
                        local union_w = ux1 - ux0
                        if y_align >= o.false_split_y_align
                            and gap <= o.false_split_max_gap
                            and gap >= -3 * o.pad_frac
                            and min(left.y, right.y) <= o.false_split_max_y
                            and union_w >= o.false_split_min_union then
                            local seam = ((left.x + left.w + right.x) * 0.5) * w
                            local ya = max(left.y, right.y)
                            local yb = min(left.y + left.h, right.y + right.h)
                            local center = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -3, 3)
                            local side_l = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -10, -4)
                            local side_r = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, 4, 10)
                            local blank_side_split = min(side_l, side_r) <= o.false_split_max_blank_side_ink
                                and max(side_l, side_r) >= o.false_split_min_other_side_ink
                            local light_art_split = center >= o.false_split_min_art_seam_ink
                                and side_l <= o.false_split_max_side_ink
                                and side_r <= o.false_split_max_side_ink
                            if center <= o.false_split_max_seam_ink
                                and side_l <= o.false_split_max_side_ink
                                and side_r <= o.false_split_max_side_ink
                                and (blank_side_split or light_art_split)
                                and (not best_i or union_w > best_union) then
                                best_i, best_j, best_union = i, j, union_w
                            end
                        end
                    end
                end
            end
        end
        if best_i then
            local a, b = panels[best_i], panels[best_j]
            local nx = min(a.x, b.x)
            local ny = min(a.y, b.y)
            a.w = max(a.x + a.w, b.x + b.w) - nx
            a.h = max(a.y + a.h, b.y + b.h) - ny
            a.x, a.y = nx, ny
            panels[best_j] = false
            merged = true
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

local function mergeTopBandArtFragments(panels, pix, bg, o, w, h)
    local band = {}
    for i, p in ipairs(panels) do
        if p and p.y <= o.false_split_max_y then
            band[#band + 1] = { idx = i, box = p }
        end
    end
    if #band < o.top_cluster_min_count then return panels end

    table.sort(band, function(a, b) return a.box.x < b.box.x end)
    local groups, current = {}, {}
    for _, item in ipairs(band) do
        local ref = current[1] and current[1].box
        if not ref or axisAlign(ref.y, ref.y + ref.h, item.box.y, item.box.y + item.box.h) >= o.top_cluster_y_align then
            current[#current + 1] = item
        else
            groups[#groups + 1] = current
            current = { item }
        end
    end
    if #current > 0 then groups[#groups + 1] = current end

    for _, group in ipairs(groups) do
        if #group >= o.top_cluster_min_count then
            table.sort(group, function(a, b) return a.box.x < b.box.x end)
            local ux0, ux1 = group[1].box.x, group[1].box.x + group[1].box.w
            local uy0, uy1 = group[1].box.y, group[1].box.y + group[1].box.h
            local ok = true
            for n = 2, #group do
                local prev, cur = group[n - 1].box, group[n].box
                local gap = cur.x - (prev.x + prev.w)
                ux0, ux1 = min(ux0, cur.x), max(ux1, cur.x + cur.w)
                uy0, uy1 = min(uy0, cur.y), max(uy1, cur.y + cur.h)
                if gap > o.top_cluster_max_gap then
                    ok = false
                    break
                end
                local seam = ((prev.x + prev.w + cur.x) * 0.5) * w
                local ya = max(prev.y, cur.y)
                local yb = min(prev.y + prev.h, cur.y + cur.h)
                local center = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -3, 3)
                local side_l = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -10, -4)
                local side_r = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, 4, 10)
                if center < o.top_cluster_min_seam_ink
                    or side_l > o.top_cluster_max_side_ink
                    or side_r > o.top_cluster_max_side_ink then
                    ok = false
                    break
                end
            end
            if ok and ux1 - ux0 >= o.top_cluster_min_union then
                local keep = group[1].idx
                local body = panels[keep]
                body.x, body.y = ux0, uy0
                body.w, body.h = ux1 - ux0, uy1 - uy0
                for n = 2, #group do panels[group[n].idx] = false end
                local out = {}
                for _, p in ipairs(panels) do
                    if p then out[#out + 1] = p end
                end
                return out
            end
        end
    end
    return panels
end

local function mergeSideStripStacks(panels, o)
    local merged = true
    while merged do
        merged = false
        for i = 1, #panels do
            local body = panels[i]
            if body and body.w >= o.side_stack_body_min_w and body.h >= o.side_stack_body_min_h then
                local parts = {}
                local ux0, ux1, uy0, uy1
                local bx1 = body.x + body.w
                for j = 1, #panels do
                    local p = panels[j]
                    if p and j ~= i and p.w <= o.side_stack_max_w then
                        local gap = p.x - bx1
                        local y_overlap = min(body.y + body.h, p.y + p.h) - max(body.y, p.y)
                        if gap >= -o.side_stack_max_gap and gap <= o.side_stack_max_gap
                            and y_overlap > 0 then
                            parts[#parts + 1] = j
                            ux0 = ux0 and min(ux0, p.x) or p.x
                            ux1 = ux1 and max(ux1, p.x + p.w) or (p.x + p.w)
                            uy0 = uy0 and min(uy0, p.y) or p.y
                            uy1 = uy1 and max(uy1, p.y + p.h) or (p.y + p.h)
                        end
                    end
                end
                if #parts >= 2 then
                    local cover = (min(body.y + body.h, uy1) - max(body.y, uy0)) / body.h
                    if cover >= o.side_stack_min_y_cover
                        and axisAlign(ux0, ux1, panels[parts[1]].x, panels[parts[1]].x + panels[parts[1]].w) >= 0.70 then
                        local nx = min(body.x, ux0)
                        local ny = min(body.y, uy0)
                        body.w = max(body.x + body.w, ux1) - nx
                        body.h = max(body.y + body.h, uy1) - ny
                        body.x, body.y = nx, ny
                        for _, j in ipairs(parts) do panels[j] = false end
                        merged = true
                    end
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

local function mergeLeftCaptionStrips(panels, o)
    local merged = true
    while merged do
        merged = false
        for i = 1, #panels do
            local strip = panels[i]
            if strip and strip.x <= 0.08 and strip.w <= o.side_caption_max_w then
                local best_j, best_union
                for j = 1, #panels do
                    local body = panels[j]
                    if body and j ~= i and body.w >= o.side_caption_body_min_w then
                        local gap = body.x - (strip.x + strip.w)
                        local y_align = axisAlign(strip.y, strip.y + strip.h, body.y, body.y + body.h)
                        local union_w = max(strip.x + strip.w, body.x + body.w) - min(strip.x, body.x)
                        if gap >= -o.side_caption_max_gap
                            and gap <= o.side_caption_max_gap
                            and y_align >= o.side_caption_y_align
                            and union_w >= o.side_caption_min_union
                            and (not best_j or union_w > best_union) then
                            best_j, best_union = j, union_w
                        end
                    end
                end
                if best_j then
                    local body = panels[best_j]
                    local nx = min(strip.x, body.x)
                    local ny = min(strip.y, body.y)
                    body.w = max(strip.x + strip.w, body.x + body.w) - nx
                    body.h = max(strip.y + strip.h, body.y + body.h) - ny
                    body.x, body.y = nx, ny
                    panels[i] = false
                    merged = true
                    break
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

local function mergePanoramicStripRows(panels, pix, bg, o, w, h)
    local used = {}
    local out = {}
    for i = 1, #panels do
        if not used[i] then
            local base = panels[i]
            local group = { i }
            local ux0, ux1 = base.x, base.x + base.w
            local uy0, uy1 = base.y, base.y + base.h
            if base.y >= 0.45 and base.h <= o.strip_row_max_h then
                for j = i + 1, #panels do
                    local p = panels[j]
                    if not used[j]
                        and p.y >= 0.45
                        and p.h <= o.strip_row_max_h
                        and axisAlign(base.y, base.y + base.h, p.y, p.y + p.h) >= o.strip_row_y_align then
                        group[#group + 1] = j
                    end
                end
            end

            if #group >= 2 then
                table.sort(group, function(a, b) return panels[a].x < panels[b].x end)
                local ok = true
                ux0, ux1 = panels[group[1]].x, panels[group[1]].x + panels[group[1]].w
                uy0, uy1 = panels[group[1]].y, panels[group[1]].y + panels[group[1]].h
                for n = 2, #group do
                    local prev, cur = panels[group[n - 1]], panels[group[n]]
                    local gap = cur.x - (prev.x + prev.w)
                    if gap > o.strip_row_max_gap then
                        ok = false
                        break
                    end
                    local seam = ((prev.x + prev.w + cur.x) * 0.5) * w
                    local ya = max(prev.y, cur.y)
                    local yb = min(prev.y + prev.h, cur.y + cur.h)
                    local center = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -3, 3)
                    local side_l = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -10, -4)
                    local side_r = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, 4, 10)
                    if center < 0.08 and max(side_l, side_r) < 0.35 then
                        ok = false
                        break
                    end
                    ux0, ux1 = min(ux0, cur.x), max(ux1, cur.x + cur.w)
                    uy0, uy1 = min(uy0, cur.y), max(uy1, cur.y + cur.h)
                end
                if ok and ux1 - ux0 >= o.strip_row_min_union then
                    out[#out + 1] = { x = ux0, y = uy0, w = ux1 - ux0, h = uy1 - uy0 }
                    for _, idx in ipairs(group) do used[idx] = true end
                else
                    out[#out + 1] = base
                    used[i] = true
                end
            else
                out[#out + 1] = base
                used[i] = true
            end
        end
    end
    return out
end

local function mergeStackedTopFragments(panels, pix, bg, o, w, h)
    local merged = true
    while merged do
        merged = false
        for i = 1, #panels do
            local body = panels[i]
            if body and body.h >= 0.18 then
                local parts = {}
                local ux0, ux1, uy0, uy1
                for j = 1, #panels do
                    local p = panels[j]
                    if p and j ~= i and p.h <= o.stacked_top_max_h then
                        local vertical_gap = body.y - (p.y + p.h)
                        if p.y <= body.y
                            and vertical_gap <= o.stacked_top_max_gap
                            and p.y + p.h >= body.y - o.stacked_top_max_gap then
                            local overlap_x = min(body.x + body.w, p.x + p.w) - max(body.x, p.x)
                            if overlap_x > 0 then
                                parts[#parts + 1] = j
                                ux0 = ux0 and min(ux0, p.x) or p.x
                                ux1 = ux1 and max(ux1, p.x + p.w) or (p.x + p.w)
                                uy0 = uy0 and min(uy0, p.y) or p.y
                                uy1 = uy1 and max(uy1, p.y + p.h) or (p.y + p.h)
                            end
                        end
                    end
                end
                if #parts >= 1 then
                    table.sort(parts, function(a, b) return panels[a].x < panels[b].x end)
                    local ok = true
                    for n = 2, #parts do
                        local prev, cur = panels[parts[n - 1]], panels[parts[n]]
                        local gap = cur.x - (prev.x + prev.w)
                        if gap > o.stacked_top_max_gap
                            or axisAlign(prev.y, prev.y + prev.h, cur.y, cur.y + cur.h) < o.stacked_top_y_align then
                            ok = false
                            break
                        end
                    end
                    local cover = (min(body.x + body.w, ux1) - max(body.x, ux0)) / body.w
                    local total_h = max(body.y + body.h, uy1) - min(body.y, uy0)
                    local single_ok = false
                    if #parts == 1 then
                        local top = panels[parts[1]]
                        local xa = max(body.x, top.x)
                        local xb = min(body.x + body.w, top.x + top.w)
                        single_ok = cover >= o.stacked_top_single_cover
                            and boundaryInk(pix, bg, o, w, h, xa, xb,
                                top.y + top.h - o.pad_frac,
                                body.y + o.pad_frac) >= o.stacked_top_min_boundary_ink
                    end
                    local multi_ok = #parts >= 2 and cover >= o.stacked_top_min_cover
                    if ok
                        and (single_ok or multi_ok)
                        and total_h <= o.stacked_top_max_total then
                        local nx = min(body.x, ux0)
                        local ny = min(body.y, uy0)
                        body.w = max(body.x + body.w, ux1) - nx
                        body.h = max(body.y + body.h, uy1) - ny
                        body.x, body.y = nx, ny
                        for _, j in ipairs(parts) do panels[j] = false end
                        merged = true
                        break
                    end
                end
            end
        end
    end
    local out = {}
    for _, p in ipairs(panels) do
        if p then out[#out + 1] = p end
    end
    return out
end

local function findInternalGutterLine(pix, bg, o, w, h, x0, y0, x1, y1, split_rows)
    local span = split_rows and (x1 - x0) or (y1 - y0)
    local len = split_rows and (y1 - y0) or (x1 - x0)
    if span <= 0 or len <= 0 then return nil end

    local min_seg = max(1, floor(o.composite_grid_min_seg * len + 0.5))
    local run_start, run_end, run_best_ink, run_best_pure
    local best_s, best_e, best_ink, best_pure

    local function finishRun(pos)
        if run_start then
            local before = run_start - (split_rows and y0 or x0)
            local after = (split_rows and y1 or x1) - (run_end + 1)
            if run_end - run_start + 1 >= 2
                and before >= min_seg
                and after >= min_seg
                and (not best_s
                    or run_best_ink < best_ink
                    or (run_best_ink == best_ink and run_best_pure > best_pure)) then
                best_s, best_e = run_start, run_end
                best_ink, best_pure = run_best_ink, run_best_pure
            end
            run_start, run_end, run_best_ink, run_best_pure = nil, nil, nil, nil
        end
    end

    local first = split_rows and y0 or x0
    local last = (split_rows and y1 or x1) - 1
    for pos = first, last do
        local ink, pure = 0, 0
        if split_rows then
            for x = x0, x1 - 1 do
                local d = abs(pix(x, pos) - bg)
                if d > o.ink_delta then
                    ink = ink + 1
                elseif d <= o.pure_delta then
                    pure = pure + 1
                end
            end
        else
            for y = y0, y1 - 1 do
                local d = abs(pix(pos, y) - bg)
                if d > o.ink_delta then
                    ink = ink + 1
                elseif d <= o.pure_delta then
                    pure = pure + 1
                end
            end
        end
        local ink_ratio = ink / span
        local pure_ratio = pure / span
        if ink_ratio <= o.composite_grid_tol and pure_ratio >= o.composite_grid_min_pure then
            if not run_start then
                run_start, run_end = pos, pos
                run_best_ink, run_best_pure = ink_ratio, pure_ratio
            else
                run_end = pos
                if ink_ratio < run_best_ink then run_best_ink = ink_ratio end
                if pure_ratio > run_best_pure then run_best_pure = pure_ratio end
            end
        else
            finishRun(pos)
        end
    end
    finishRun(last + 1)

    if best_s then
        return (best_s + best_e + 1) * 0.5
    end
    return nil
end

local function splitLargeCompositeGrids(panels, pix, bg, o, w, h)
    local out = {}
    for _, p in ipairs(panels) do
        if p.w >= o.composite_grid_min_w
            and p.h >= o.composite_grid_min_h
            and p.h <= o.composite_grid_max_h
            and p.y <= o.composite_grid_max_y then
            local x0 = max(0, floor(p.x * w + 0.5))
            local y0 = max(0, floor(p.y * h + 0.5))
            local x1 = min(w, floor((p.x + p.w) * w + 0.5))
            local y1 = min(h, floor((p.y + p.h) * h + 0.5))
            local hy = findInternalGutterLine(pix, bg, o, w, h, x0, y0, x1, y1, true)
            if hy then
                local vx_top = findInternalGutterLine(pix, bg, o, w, h, x0, y0, x1, floor(hy + 0.5), false)
                local vx_bottom = findInternalGutterLine(pix, bg, o, w, h, x0, floor(hy + 0.5), x1, y1, false)
                if vx_top and vx_bottom then
                    local yn = hy / h
                    local xt = vx_top / w
                    local xb = vx_bottom / w
                    out[#out + 1] = { x = p.x, y = p.y, w = xt - p.x, h = yn - p.y }
                    out[#out + 1] = { x = xt, y = p.y, w = p.x + p.w - xt, h = yn - p.y }
                    out[#out + 1] = { x = p.x, y = yn, w = xb - p.x, h = p.y + p.h - yn }
                    out[#out + 1] = { x = xb, y = yn, w = p.x + p.w - xb, h = p.y + p.h - yn }
                else
                    out[#out + 1] = p
                end
            else
                out[#out + 1] = p
            end
        else
            out[#out + 1] = p
        end
    end
    return out
end

local function expandBottomCaptionTops(panels, pix, bg, o, w, h)
    local used = {}
    for i = 1, #panels do
        if not used[i] then
            local base = panels[i]
            local group = {}
            if base.y >= o.bottom_caption_min_y then
                for j = i, #panels do
                    local p = panels[j]
                    if not used[j]
                        and p.y >= o.bottom_caption_min_y
                        and axisAlign(base.y, base.y + base.h, p.y, p.y + p.h) >= 0.85 then
                        group[#group + 1] = j
                    end
                end
            end

            if #group >= o.bottom_caption_min_count then
                for _, idx in ipairs(group) do
                    local p = panels[idx]
                    local x0 = max(0, floor(p.x * w + 0.5))
                    local x1 = min(w, floor((p.x + p.w) * w + 0.5))
                    local y_top = max(0, floor(p.y * h + 0.5))
                    local y_bottom = min(h, floor((p.y + p.h) * h + 0.5))
                    local max_up = max(0, y_top - floor(o.bottom_caption_max_expand * h + 0.5))
                    local block = max(2, floor(o.bottom_caption_block + 0.5))
                    local candidate = y_top
                    local y = y_top - block
                    while y >= max_up do
                        local ink, pure, total = 0, 0, 0
                        for yy = y, min(y + block - 1, y_top - 1) do
                            for xx = x0, x1 - 1 do
                                local d = abs(pix(xx, yy) - bg)
                                total = total + 1
                                if d > o.ink_delta then
                                    ink = ink + 1
                                elseif d <= o.pure_delta then
                                    pure = pure + 1
                                end
                            end
                        end
                        local ink_ratio = ink / max(1, total)
                        local pure_ratio = pure / max(1, total)
                        if ink_ratio >= o.bottom_caption_stop_ink
                            and pure_ratio <= o.bottom_caption_stop_max_pure then
                            if candidate == y_top then
                                candidate = y
                                y = y - block
                            else
                                break
                            end
                        else
                            candidate = y
                            y = y - block
                        end
                    end

                    if y_top - candidate >= o.bottom_caption_min_expand * h then
                        local ink, total = 0, 0
                        for yy = candidate, y_top - 1 do
                            for xx = x0, x1 - 1 do
                                total = total + 1
                                if abs(pix(xx, yy) - bg) > o.ink_delta then
                                    ink = ink + 1
                                end
                            end
                        end
                        if ink / max(1, total) >= o.bottom_caption_min_ink then
                            p.y = candidate / h
                            p.h = (y_bottom - candidate) / h
                        end
                    end
                    used[idx] = true
                end
            else
                used[i] = true
            end
        end
    end
    return panels
end

local function coverage(panels)
    local total = 0
    for _, p in ipairs(panels) do
        total = total + p.w * p.h
    end
    return total
end

local function isValid(panels, o, min_cov, raw_count)
    local cov = coverage(panels)
    if #panels == 1 then
        local p = panels[1]
        if (raw_count or 0) > 1
            and cov >= o.single_panel_min_coverage
            and p.w * p.h >= o.single_panel_min_area
            and p.w >= o.single_panel_min_side
            and p.h >= o.single_panel_min_side then
            return true
        end
    end
    if #panels < o.min_panels or #panels > o.max_panels
        or cov < (min_cov or o.min_coverage) then
        return false
    end
    for _, p in ipairs(panels) do
        if p.w * p.h >= o.max_panel_area then
            -- Oversized biggest panel: suspicious (often two merged rows),
            -- but legal below the hard ceiling -- a half-page splash is a
            -- normal BD layout. "soft" asks for another pass to try a finer
            -- segmentation; the result is still usable if none succeeds.
            if p.w * p.h >= o.max_panel_area_hard then
                return false
            end
            return false, true
        end
    end
    return true
end

--- Detect panels on a page.
-- @param pix accessor function pix(x, y) -> 0..255
-- @param w, h image dimensions in pixels
-- @param opts optional overrides for DEFAULTS
-- @return panels array of {x, y, w, h} normalized 0..1 (single full-page
--         panel when segmentation is not confident), plus an info table.
function PanelDetect.detect(pix, w, h, opts)
    local o = {}
    for k, v in pairs(DEFAULTS) do o[k] = v end
    if opts then
        for k, v in pairs(opts) do o[k] = v end
    end
    -- Precomputed pixel thresholds.
    o.page_w, o.page_h = w, h
    o.min_gutter_rows = max(3, floor(o.min_gutter_frac * h + 0.5))
    o.min_gutter_cols = max(3, floor(o.min_gutter_frac * w + 0.5))
    o.thin_seg_rows = floor(o.thin_min_segment * h + 0.5)
    o.thin_seg_cols = floor(o.thin_min_segment * w + 0.5)
    o.min_side_px_w = max(4, floor(o.min_side_frac * w * 0.5))
    o.min_side_px_h = max(4, floor(o.min_side_frac * h * 0.5))

    local bg = estimateBackground(pix, w, h, o)

    local info = { background = bg, fallback = false, history = {} }

    -- Analysis region excludes a thin edge band (render/scan edge artifacts).
    local ex = floor(w * o.edge_inset_frac + 0.5)
    local ey = floor(h * o.edge_inset_frac + 0.5)

    -- Pass 1: strict tolerance; pass 2: relaxed tolerance; pass 3 (only
    -- reached when the page would otherwise fall back): loose occluded
    -- thresholds for pages whose gutters are heavily crossed by artwork.
    local passes = {
        { tol = o.gutter_ink_tol,  occl_tol = o.occluded_ink_tol,       occl_span = o.occluded_max_span },
        { tol = o.relaxed_ink_tol, occl_tol = o.occluded_ink_tol,       occl_span = o.occluded_max_span,
          min_cov = o.relaxed_min_coverage },
        { tol = o.relaxed_ink_tol, occl_tol = o.occluded_ink_tol_loose, occl_span = o.occluded_max_span_loose,
          min_cov = o.relaxed_min_coverage },
    }
    -- A "soft" result is valid except for one suspiciously large panel
    -- (>= max_panel_area, < max_panel_area_hard). It usually means two rows
    -- merged over an eroded gutter, so later passes get a chance to do
    -- better -- but if none does, the soft result (e.g. a page with a
    -- legitimate half-page splash) beats a full-page fallback.
    local soft_panels, soft_pass
    for pass, cfg in ipairs(passes) do
        o.occl_tol, o.occl_span = cfg.occl_tol, cfg.occl_span
        local leaves = {}
        cut(pix, bg, o, cfg.tol, ex, ey, w - ex, h - ey, 1, leaves)
        local panels = finalizePanels(leaves, w, h, o)
        panels = mergePartitionLeftovers(panels, pix, bg, o, w, h)
        panels = mergeFalseHorizontalSplits(panels, pix, bg, o, w, h)
        panels = mergeTopBandArtFragments(panels, pix, bg, o, w, h)
        panels = mergeSideStripStacks(panels, o)
        panels = mergeLeftCaptionStrips(panels, o)
        panels = mergePanoramicStripRows(panels, pix, bg, o, w, h)
        panels = mergeStackedTopFragments(panels, pix, bg, o, w, h)
        panels = splitLargeCompositeGrids(panels, pix, bg, o, w, h)
        panels = expandBottomCaptionTops(panels, pix, bg, o, w, h)
        info.tolerance_used = cfg.tol
        info.raw_count = #leaves
        info.panel_count = #panels
        info.coverage = coverage(panels)
        info.history[pass] = string.format("pass %d: raw=%d panels=%d coverage=%.2f",
            pass, #leaves, #panels, info.coverage)
        info.raw_leaves = leaves
        local valid, soft = isValid(panels, o, cfg.min_cov, #leaves)
        if valid then
            info.passes = pass
            return panels, info
        end
        if soft and not soft_panels then
            soft_panels, soft_pass = panels, pass
        end
    end

    if soft_panels then
        info.passes = soft_pass
        info.soft = true
        info.panel_count = #soft_panels
        info.coverage = coverage(soft_panels)
        return soft_panels, info
    end

    info.fallback = true
    return { { x = 0, y = 0, w = 1, h = 1 } }, info
end

--- Sort panels into reading order by top-edge bands.
--
-- The older interval-intersection sorter could let one tall side panel bridge
-- several rows, turning a staggered western BD layout into "read the whole
-- left column, then the right column". Top-edge bands keep boxes with the same
-- visual row start together, then read each band in the requested direction.
-- @param panels array of normalized {x, y, w, h}
-- @param dir "ltr" (default) or "rtl"
-- @return the same panels in a new, ordered array
function PanelDetect.sort(panels, dir)
    local rtl = dir == "rtl"
    local band_margin = 0.045
    local x_margin = 0.02

    local sorted = {}
    for i, p in ipairs(panels) do sorted[i] = p end
    table.sort(sorted, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then
            if rtl then return a.x > b.x end
            return a.x < b.x
        end
        return false
    end)

    local bands = {}
    for _, box in ipairs(sorted) do
        local band = bands[#bands]
        if not band or abs(box.y - band.y) > band_margin then
            band = { y = box.y, boxes = {} }
            bands[#bands + 1] = band
        end
        band.boxes[#band.boxes + 1] = box
    end

    local out = {}
    for _, band in ipairs(bands) do
        table.sort(band.boxes, function(a, b)
            if abs(a.x - b.x) > x_margin then
                if rtl then return a.x > b.x end
                return a.x < b.x
            end
            return a.y < b.y
        end)
        for _, box in ipairs(band.boxes) do out[#out + 1] = box end
    end

    -- Local reading-order repair for a common BD layout: two stacked panels
    -- on one side of a taller neighbor. Top-edge bands naturally put the tall
    -- neighbor before the lower stacked panel; human reading usually finishes
    -- the short stack first.
    local i = 1
    while i <= #out - 2 do
        local top, tall = out[i], out[i + 1]
        local stack_side_ok = rtl and top.x > tall.x or (not rtl and top.x < tall.x)
        if stack_side_ok
            and abs(top.y - tall.y) <= band_margin
            and tall.h >= top.h * 1.35 then
            local moved = false
            for k = i + 2, #out do
                local lower = out[k]
                local same_stack = axisAlign(top.x, top.x + top.w, lower.x, lower.x + lower.w) >= 0.70
                local under_top = lower.y >= top.y + top.h - band_margin
                local inside_tall = lower.y + lower.h <= tall.y + tall.h + band_margin
                local on_stack_side = rtl and lower.x > tall.x or (not rtl and lower.x < tall.x)
                if same_stack and under_top and inside_tall and on_stack_side then
                    table.remove(out, k)
                    table.insert(out, i + 1, lower)
                    moved = true
                    break
                end
            end
            if moved then
                i = i + 2
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return out
end

return PanelDetect
