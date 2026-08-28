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
    strip_row_min_y = 0.25,
    strip_row_min_union = 0.84,
    strip_row_y_align = 0.88,
    strip_row_max_gap = 0.025,
    strip_row_max_gutter_purity = 0.80,
    stacked_top_max_h = 0.22, -- two+ top fragments sitting on a lower body
                              -- and spanning the same column are one panel
    stacked_top_min_cover = 0.85,
    stacked_top_single_cover = 0.92,
    stacked_top_min_boundary_ink = 0.15,
    stacked_top_y_align = 0.80,
    stacked_top_max_gap = 0.03,
    stacked_top_max_total = 0.55,
    stacked_top_multi_max_height_ratio = 0.82,
    stacked_top_max_width_ratio = 1.15,
    stacked_top_multi_max_body_w = 0.75,
    stacked_top_multi_full_min_y = 0.20,
    stacked_top_wide_multi_max_part_h = 0.18,
    stacked_top_wide_multi_max_total = 0.45,
    stacked_top_caption_min_y = 0.45,
    stacked_top_caption_body_min_y = 0.55,
    stacked_top_caption_max_h = 0.12,
    stacked_top_caption_edge_align = 0.025,
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
    bottom_caption_peer_align = 0.025,
    bottom_caption_peer_max_expand = 0.08,
    caption_expand_gutter_purity = 0.85,
    caption_expand_gutter_ink = 0.03,
    caption_expand_snap_gap = 0.02,
    caption_box_min_y = 0.12,
    caption_box_max_expand = 0.030,
    caption_box_wall_ink = 0.80,
    caption_box_wall_pure = 0.12,
    caption_box_light_min_pure = 0.25,
    caption_box_text_min_ink = 0.15,
    caption_box_min_light_rows = 3,
    caption_box_min_text_rows = 3,
    caption_box_min_block_run = 0.35,
    caption_box_min_block_rows = 2,
    shattered_min_run = 3,
    shattered_max_w = 0.20,
    shattered_min_ratio = 1.5,
    shattered_max_span = 0.60,
    shattered_max_gap = 0.02,
    shattered_row_align = 0.012,
    shattered_max_seam_purity = 0.85,
    protruding_caption_min_y = 0.20,
    protruding_caption_max_y = 0.75,
    protruding_caption_max_expand = 0.06,
    protruding_caption_block = 8,
    protruding_caption_stop_ink = 0.68,
    protruding_caption_stop_max_pure = 0.25,
    protruding_caption_min_ink = 0.10,
    protruding_caption_min_pure = 0.20,
    protruding_caption_min_expand = 0.025,
    protruding_caption_safety_px = 8,
    protruding_caption_safety_max_y = 0.40,
    protruding_caption_peer_min_evidence = 2,
    protruding_caption_row_top_align = 0.02,
    protruding_caption_row_bottom_align = 0.03,
    protruding_caption_upper_min_offset = 0.08,
    protruding_caption_upper_max_gap = 0.04,
    protruding_caption_upper_min_overlap = 0.35,
    protruding_caption_min_union = 0.75,
    protruding_caption_max_union = 0.80,
    protruding_caption_general_min_count = 8,
    protruding_caption_general_max_count = 12,
    protruding_caption_general_max_raw_excess = 1,
    caption_partition_min_y = 0.50,
    caption_partition_max_header_h = 0.10,
    caption_partition_min_headers = 3,
    caption_partition_max_gap = 0.04,
    caption_partition_min_union = 0.75,
    caption_partition_body_gap = 0.04,
    caption_partition_bottom_align = 0.03,
    overlapping_caption_min_y = 0.20,
    overlapping_caption_max_y = 0.60,
    overlapping_caption_top_align = 0.012,
    overlapping_caption_bottom_align = 0.03,
    overlapping_caption_min_union = 0.80,
    overlapping_caption_max_gap = 0.04,
    overlapping_caption_expand = 0.025,
    overlapping_caption_min_ink = 0.03,
    overlapping_caption_panel_count = 3,
    overlapping_caption_max_boundary_ink = 0.72,
    overlapping_caption_max_top_background = 0.58,
    overlapping_caption_top_probe_start = 0.012,
    overlapping_caption_top_probe_end = 0.06,
    overlapping_caption_probe_step = 2,
    side_takeover_min_y = 0.55,
    side_takeover_max_expand = 0.07,
    side_takeover_max_gap = 0.025,
    side_takeover_edge_align = 0.025,
    side_takeover_max_upper_w_ratio = 0.70,
    side_takeover_protect_aligned_rows = true,
    top_text_max_y = 0.10, -- centered album/chapter titles above the page art
    top_text_max_bottom = 0.16,
    top_text_max_h = 0.085,
    top_text_max_w = 0.65,
    top_text_min_margin = 0.12,
    top_text_min_below = 3,
    contained_duplicate_overlap = 0.92,
    contained_duplicate_max_area_ratio = 0.70,
    contained_duplicate_parent_max_area = 0.25,
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
    art_seam_split_min_y = 0.24,
    gutterless_align = 0.92,   -- no page-coloured line at a shared edge means
    gutterless_max_gap = 0.02,     -- the seam is artwork, not a gutter
    gutterless_max_purity = 0.60,
    gutterless_min_boundary_ink = 0.15,
    gutterless_inner_margin = 0.20,
    gutterless_inner_max_purity = 0.85,
    boundary_clean_max_ink = 0.13,
    gutterless_min_side = 0.10,
    gutterless_max_union_area = 0.55,
    seam_sliver_max_w = 0.13,
    seam_sliver_min_body_w = 0.22,
    seam_sliver_min_y = 0.24,
    seam_sliver_min_h = 0.15,
    seam_sliver_max_purity = 0.25,
    art_seam_split_y_align = 0.92,
    art_seam_split_max_gap = 0.02,
    art_seam_split_min_union = 0.55,
    art_seam_split_min_piece_w = 0.15,
    art_seam_split_min_center_ink = 0.12,
    art_seam_split_max_center_ink = 0.45,
    art_seam_split_max_side_ink = 0.55,
    art_seam_split_dark_min_center_ink = 0.55,
    art_seam_split_dark_max_center_ink = 0.85,
    art_seam_split_dark_min_side_ink = 0.45,
    art_seam_split_dark_max_side_ink = 0.85,
    narrow_seam_split_min_union = 0.20,
    narrow_seam_split_max_union = 0.40,
    narrow_seam_split_min_piece_w = 0.08,
    narrow_seam_split_min_h = 0.15,
    narrow_seam_split_max_side_ink = 0.48,
    narrow_row_split_panel_count = 7,
    narrow_row_split_splash_min_area = 0.45,
    narrow_row_split_row_count = 4,
    narrow_row_split_max_piece_w = 0.12,
    narrow_row_split_min_union = 0.20,
    narrow_row_split_max_union = 0.36,
    narrow_row_split_min_row_union = 0.85,
    narrow_row_split_min_merged_w = 0.20,
    narrow_row_split_max_width_ratio = 1.80,
    narrow_row_split_align = 0.94,
    narrow_row_split_max_gap = 0.02,
    narrow_row_split_bottom_min_union = 0.80,
    top_cluster_min_count = 3, -- three+ top fragments cut through artwork,
                               -- not blank gutters, are one wide top panel
    top_cluster_min_union = 0.85,
    top_cluster_y_align = 0.90,
    top_cluster_max_gap = 0.03,
    top_cluster_min_seam_ink = 0.20,
    top_cluster_max_side_ink = 0.75,
    top_left_art_max_x = 0.08, -- top-left panel split into artwork fragments
    top_left_art_max_y = 0.08,
    top_left_art_max_gap = 0.03,
    top_left_art_y_align = 0.85,
    top_left_art_min_seam_ink = 0.35,
    top_left_art_max_side_ink = 0.85,
    top_left_art_max_purity = 0.40,
    bottom_full_bleed_edge_frac = 0.03,
    bottom_full_bleed_edge_ink = 0.30,
    bottom_full_bleed_min_y = 0.30,
    bottom_full_bleed_max_y = 0.70,
    bottom_full_bleed_min_run = 0.20,
    bottom_full_bleed_max_gap_px = 3,
    bottom_full_bleed_piece_inset = 0.10,
    bottom_full_bleed_min_cover = 0.90,
    side_stack_body_min_w = 0.55, -- big panel with a narrow right strip split
    side_stack_body_min_h = 0.30, -- into two+ pieces: rejoin the strip
    side_stack_max_w = 0.25,
    side_stack_max_gap = 0.03,
    side_stack_min_y_cover = 0.85,
    partition_max_width_ratio = 2.30,
    partition_max_narrow_h = 0.22,
    partition_min_upper_y = 0.12,
    aligned_frag_x_align = 0.88,
    aligned_frag_max_gap = 0.025,
    aligned_frag_max_total = 0.48,
    aligned_frag_top_max_h = 0.22,
    aligned_frag_art_top_max_h = 0.25,
    aligned_frag_art_max_purity = 0.65,
    aligned_frag_min_boundary_ink = 0.20,
    aligned_frag_caption_protect_min_y = 0.45,
    aligned_frag_caption_protect_max_h = 0.12,
    aligned_frag_caption_protect_body_min_h = 0.18,
    merge_boundary_max_purity = 0.65, -- a mostly page-colored line is a real
                                      -- gutter, never an artwork seam to merge
    art_merge_boundary_max_purity = 0.40,
    shared_header_min_y = 0.35,
    shared_header_max_h = 0.12,
    shared_header_max_gap = 0.03,
    shared_header_min_cover = 0.85,
    splash_mosaic_min_count = 4,
    splash_mosaic_min_union = 0.94,
    splash_mosaic_min_fill = 0.86,
    splash_mosaic_min_h = 0.45,
    splash_mosaic_max_h = 0.68,
    rescue_max_gap   = 0.08,  -- max gap when gluing an undersized fragment
                              -- (one the size filter would drop) onto its
                              -- best-aligned neighbor instead of losing it
    rescue_min_align = 0.60,  -- enough shared extent to be a sliced caption;
                              -- avoids gluing decorative logos onto panels
    rescue_max_count = 3,     -- more undersized fragments than this (or more
                              -- than half the boxes) means a shattered page,
                              -- not sliced-off captions: skip the rescue
    -- Page-coloured gutters: a real gutter whose ink count is just above the
    -- clean tolerance because a panel corner tick, a bubble tail or scan noise
    -- crosses it, while the line itself is still almost entirely page colour.
    -- Much stronger evidence than an occluded band inside artwork, so it is
    -- tried before the occluded search and only when neither axis cut cleanly.
    pure_gutter_max_ink   = 0.08,
    pure_gutter_min_purity = 0.88,
    pure_gutter_merge_gap = 6,
    pure_gutter_border_ink = 0.25,
    pure_gutter_soft_delta = 45,
    pure_gutter_max_soft = 0.06,
    pure_gutter_soft_max_run = 2,
    -- Purity only means "page colour" when the estimated background is one.
    page_colour_min_light_bg = 240,
    page_colour_max_dark_bg = 20,
    -- Occluded gutters: a real gutter crossed by artwork or caption boxes.
    -- Qualifies when a low-ish ink band sits directly between two dense ink
    -- lines (the borders of the adjacent panels, eroded by downscale blur).
    -- Only tried on large regions where no clean gutter exists on that axis.
    occluded_ink_tol    = 0.35, -- max ink fraction inside an occluded gutter row
    occluded_min_run    = 2,
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
    structural_rescue_span = 0.65,
    structural_rescue_border_ink = 0.40,
    structural_rescue_min_run = 1,
    structural_rescue_min_gain = 2,
    structural_rescue_max_gain = 8,
    structural_rescue_agreement = 0.85,
    structural_rescue_min_base_area = 0.24,
    structural_rescue_fragmented_min_area = 0.27,
    structural_rescue_min_coverage = 0.75,
    structural_rescue_max_raw_excess = 4,
    structural_rescue_pure_min_base_area = 0.18,
    structural_rescue_pure_max_base_raw_excess = 3,
    structural_rescue_border_trust_area = 0.30,
    structural_rescue_run_trust_area = 0.45,
    structural_rescue_agreement_max_base = 9,
    structural_rescue_pure_gain1_area_ratio = 0.80,
    structural_rescue_min_combined_regions = 3,
    structural_rescue_min_combined_base = 5,
    structural_rescue_max_base_raw_excess = 2,
    structural_rescue_sparse_min_area = 0.45,
    structural_rescue_five_min_area = 0.40,
    structural_rescue_coherent_coverage = 0.80,
    structural_rescue_coherent_max_area = 0.32,
    structural_rescue_splash_coverage = 0.90,
    structural_rescue_splash_min_area = 0.45,
    structural_rescue_dense_panel_count = 9,
    structural_rescue_dense_min_regions = 5,
    structural_rescue_dense_min_area = 0.13,
    structural_rescue_dense_max_area = 0.20,
    structural_rescue_dense_min_coverage = 0.75,
    structural_rescue_dense_max_coverage = 0.80,
    structural_rescue_coarse_min_area = 0.38,
    structural_rescue_coarse_max_area = 0.45,
    structural_rescue_coarse_min_coverage = 0.75,
    structural_rescue_coarse_max_coverage = 0.85,
    structural_rescue_redistribution_max_area_ratio = 0.70,
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
    malformed_loose_min_count = 6,
    malformed_loose_min_panel_area = 0.45,
    malformed_loose_min_overlap = 0.07,
    oversized_single_guard_min_coverage = 0.90,
    oversized_single_guard_min_area = 0.90,
    oversized_single_guard_max_raw = 3,
    oversized_single_guard_loose_min_count = 6,
    max_depth        = 8,
    border_frac      = 0.02,  -- ring thickness used for background sampling
    sample_step      = 2,     -- subsampling step for background sampling
    content_bounds_ink_delta = 30,
    content_bounds_min_ink_ratio = 0.012,
    content_bounds_vertical_min_ink_ratio = 0.020,
    content_bounds_dark_background_max = 220,
    content_bounds_white_cutoff = 245,
    content_bounds_x_inset = 0.03,
    content_bounds_y_inset = 0.03,
    content_bounds_sample_step = 4,
    content_bounds_min_run = 3,
    content_bounds_extent_min_span = 0.012,
    content_bounds_min_width = 0.50,
    content_bounds_min_height = 0.50,
    content_bounds_grow_min_ratio = 0.002,
    content_bounds_max_grow = 0.020,
    panel_edge_safety_frac = 0.008,
    fragmented_overlap_min_panels = 8,
    fragmented_overlap_min_raw_ratio = 2.0,
    fragmented_overlap_min_regions = 10,
    fragmented_overlap_min_union = 0.90,
    fragmented_overlap_min_excess = 0.06,
    fragmented_gap_max_coverage = 0.05,
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

local function activeExtent(length, cross_start, cross_end, sample_step,
        min_ink_ratio, min_run, isActive, grow_ratio, max_grow)
    local sample_count = floor((cross_end - cross_start - 1) / sample_step) + 1
    local active = {}
    local touched = {}
    for pos = 0, length - 1 do
        local ink = 0
        for cross = cross_start, cross_end - 1, sample_step do
            if isActive(pos, cross) then ink = ink + 1 end
        end
        active[pos + 1] = ink / sample_count >= min_ink_ratio
        touched[pos + 1] = grow_ratio and (ink / sample_count >= grow_ratio) or false
    end

    local first, last
    for pos = 0, length - min_run do
        local found = true
        for n = 1, min_run do
            if not active[pos + n] then found = false; break end
        end
        if found then first = pos; break end
    end
    for pos = length - min_run, 0, -1 do
        local found = true
        for n = 1, min_run do
            if not active[pos + n] then found = false; break end
        end
        if found then last = pos + min_run; break end
    end
    -- The run rule finds where content becomes solid, which is just inside a
    -- panel's own border: the border is one or two lines and the page colour
    -- behind it breaks the run. Walk back out over any line still carrying ink
    -- so the frame, and anything else thin, stays in the crop. The walk uses a
    -- far lower bar than the run rule -- a frame corner may only touch a
    -- handful of sampled rows -- and is capped, so it recovers an edge without
    -- being able to wander into a margin.
    if first and max_grow then
        local stop = max(0, first - max_grow)
        while first > stop and touched[first] do first = first - 1 end
    end
    if last and max_grow then
        local stop = min(length, last + max_grow)
        while last < stop and touched[last + 1] do last = last + 1 end
    end
    return first, last
end

--- Find the artwork bounds without segmenting panels.
-- This removes scanned/printed borders for Basic detail mode while remaining
-- reliable on complex and full-bleed pages. If one axis is ambiguous, that
-- axis safely falls back to the complete page.
function PanelDetect.findContentBounds(pix, w, h, opts)
    local o = {}
    for k, v in pairs(DEFAULTS) do o[k] = v end
    if opts then
        for k, v in pairs(opts) do o[k] = v end
    end

    local bg = estimateBackground(pix, w, h, o)
    local x_inset = floor(w * o.content_bounds_x_inset + 0.5)
    local y_inset = floor(h * o.content_bounds_y_inset + 0.5)
    local x0 = min(w - 1, max(0, x_inset))
    local x1 = max(x0 + 1, w - x_inset)
    local y0 = min(h - 1, max(0, y_inset))
    local y1 = max(y0 + 1, h - y_inset)
    local sample_step = max(1, floor(o.content_bounds_sample_step + 0.5))
    local base_run = max(1, floor(o.content_bounds_min_run + 0.5))
    local run_x = max(base_run, floor(w * o.content_bounds_extent_min_span + 0.5))
    local run_y = max(base_run, floor(h * o.content_bounds_extent_min_span + 0.5))
    local delta = o.content_bounds_ink_delta
    local function isContent(x, y)
        local value = pix(x, y)
        if bg < o.content_bounds_dark_background_max then
            -- A midtone/dark outer ring usually means full-bleed art. In that
            -- case white scan margins are background, while dark artwork is
            -- content even when it resembles the estimated edge luminance.
            return value < o.content_bounds_white_cutoff
        end
        return abs(value - bg) > delta
    end
    local grow_x = floor(w * o.content_bounds_max_grow + 0.5)
    local grow_y = floor(h * o.content_bounds_max_grow + 0.5)
    local left, right = activeExtent(
        w, y0, y1, sample_step, o.content_bounds_min_ink_ratio, run_x,
        function(x, y) return isContent(x, y) end,
        o.content_bounds_grow_min_ratio, grow_x)
    local top, bottom = activeExtent(
        h, x0, x1, sample_step, o.content_bounds_vertical_min_ink_ratio, run_y,
        function(y, x) return isContent(x, y) end,
        o.content_bounds_grow_min_ratio, grow_y)

    if not left or not right
        or right - left < w * o.content_bounds_min_width then
        left, right = 0, w
    end
    if not top or not bottom
        or bottom - top < h * o.content_bounds_min_height then
        top, bottom = 0, h
    end

    -- No inward safety step here. It was trimming a few pixels off each side
    -- so a leftover fraction of a source margin could not be enlarged, but on
    -- a framed page those pixels are the frame and its artwork. The extent
    -- walk above already stops on the first empty line, which is the margin.

    return {
        x = left / w,
        y = top / h,
        w = (right - left) / w,
        h = (bottom - top) / h,
        background = bg,
    }
end

--- Compatibility wrapper for callers that only need left/right trimming.
function PanelDetect.findHorizontalContentBounds(pix, w, h, opts)
    local bounds = PanelDetect.findContentBounds(pix, w, h, opts)
    return { x = bounds.x, w = bounds.w, background = bounds.background }
end

--- Build screen-aspect detail crops that cover the complete artwork bounds.
-- Portrait content sweeps vertically; wide content sweeps horizontally in
-- reading order. First and last crops are anchored to the corresponding
-- artwork edges, so trimming cannot omit the beginning or end of a page.
function PanelDetect.buildDetailViews(bounds, count, page_aspect, screen_aspect, direction)
    count = max(1, floor((count or 4) + 0.5))
    page_aspect = max(0.01, page_aspect or 1)
    screen_aspect = max(0.01, screen_aspect or 1)
    local crop_w = bounds.w
    local crop_h = crop_w * page_aspect / screen_aspect
    local horizontal = false
    if crop_h > bounds.h then
        crop_h = bounds.h
        crop_w = crop_h * screen_aspect / page_aspect
        horizontal = true
    end
    crop_w = min(bounds.w, max(0.01, crop_w))
    crop_h = min(bounds.h, max(0.01, crop_h))
    local travel_x = max(0, bounds.w - crop_w)
    local travel_y = max(0, bounds.h - crop_h)
    local views = {}
    for i = 1, count do
        local progress = count == 1 and 0 or (i - 1) / (count - 1)
        if horizontal and direction == "rtl" then progress = 1 - progress end
        views[i] = {
            x = bounds.x + travel_x * progress,
            y = bounds.y + travel_y * progress,
            w = crop_w,
            h = crop_h,
        }
    end
    return views, horizontal and "horizontal" or "vertical"
end

function PanelDetect.addDisplayEdgeSafety(panels, amount)
    amount = amount or DEFAULTS.panel_edge_safety_frac
    local out = {}
    for i, panel in ipairs(panels) do
        local x0 = max(0, panel.x - amount)
        local y0 = max(0, panel.y - amount)
        local x1 = min(1, panel.x + panel.w + amount)
        local y1 = min(1, panel.y + panel.h + amount)
        out[i] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
    return out
end

-- One pass over a region: per-row and per-column ink counts, plus per-row and
-- per-column pure-background counts (pixels within pure_delta of the page
-- background). Purity separates true gutters (page-colored) from smooth
-- mid-tone areas inside artwork, which carry no "ink" but are not background.
-- Arrays are 1-based relative to the region origin.
local function scanRegion(pix, bg, delta, pure_delta, soft_delta, x0, y0, x1, y1)
    local row_ink, col_ink, row_pure, col_pure = {}, {}, {}, {}
    local row_soft, col_soft = {}, {}
    for i = 1, y1 - y0 do row_ink[i] = 0; row_pure[i] = 0; row_soft[i] = 0 end
    for i = 1, x1 - x0 do col_ink[i] = 0; col_pure[i] = 0; col_soft[i] = 0 end
    for y = y0, y1 - 1 do
        local ry = y - y0 + 1
        local acc, pure_acc, soft_acc = 0, 0, 0
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
            elseif d <= soft_delta then
                -- Just off the page colour: the halo JPEG ringing and
                -- anti-aliasing leave along a border. Counted apart so a
                -- gutter can spend a little of it without a smooth grey band
                -- ever passing for page colour.
                soft_acc = soft_acc + 1
                local rx = x - x0 + 1
                col_soft[rx] = col_soft[rx] + 1
            end
        end
        row_ink[ry] = acc
        row_pure[ry] = pure_acc
        row_soft[ry] = soft_acc
    end
    return row_ink, col_ink, row_pure, col_pure, row_soft, col_soft
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
            run_start, run_hard = nil, nil
        end
    end
    -- A run touching `last` cannot happen: contentBounds guarantees ink at `last`.
    return gutters
end

-- Gutters that ink counting alone misses: lines that are almost entirely page
-- colour but carry slightly too much ink for the clean tolerance, because a
-- panel corner tick, a balloon tail or scan noise crosses them. Purity is the
-- discriminating signal here - artwork bands are inkless only where they are
-- smooth mid-tone, never where they are 88%+ exact page background across the
-- whole region span. Segment guards keep this from shaving thin slivers.
local function findPureGutters(ink, pure, soft, span, o, first, last, min_seg, max_soft)
    local ink_limit = o.pure_gutter_max_ink * span
    local purity_limit = o.pure_gutter_min_purity * span
    local soft_limit = (max_soft or 0) * span
    local border = o.pure_gutter_border_ink * span
    local dist = o.occluded_border_dist
    local function hasBorderLine(from, to)
        for i = max(first, from), min(last, to) do
            if ink[i] >= border then return true end
        end
        return false
    end
    local gutters = {}
    local run_start, run_min_ink, run_hard
    for i = first, last do
        local hard = pure[i] >= purity_limit
        if ink[i] <= ink_limit
            and (hard or pure[i] + min(soft[i], soft_limit) >= purity_limit) then
            if run_start then
                if ink[i] < run_min_ink then run_min_ink = ink[i] end
                run_hard = run_hard or hard
            else
                run_start, run_min_ink, run_hard = i, ink[i], hard
            end
        elseif run_start then
            -- Only a line between two panel borders is a gutter. Without this
            -- an empty stretch inside a single panel is page colour too and
            -- the panel gets cut in half.
            -- Halo credit exists for a gutter so thin that downscaling or
            -- JPEG ringing eats its purity. A wide run that never reaches the
            -- purity bar on its own is not an eroded gutter, it is a painted
            -- light band inside artwork, and cutting it slices the picture.
            local soft_only_wide = not run_hard
                and (i - run_start) > o.pure_gutter_soft_max_run
            if not soft_only_wide
                and (run_start - first) >= min_seg and (last - i + 1) >= min_seg
                and hasBorderLine(run_start - dist, run_start - 1)
                and hasBorderLine(i, i + dist - 1) then
                local prev = gutters[#gutters]
                local gap = prev and (run_start - prev.e - 1) or min_seg
                if prev and gap < min_seg then
                    if gap <= o.pure_gutter_merge_gap then
                        -- Two page-coloured lines around a stray ink line are
                        -- one gutter: cutting both emits an unusable sliver.
                        prev.e = i - 1
                        prev.min_ink = min(prev.min_ink, run_min_ink)
                    elseif run_min_ink < prev.min_ink then
                        -- A row of white caption boxes can look page-coloured
                        -- too. Only the cleanest line of the pair may cut.
                        gutters[#gutters] = {
                            s = run_start, e = i - 1, min_ink = run_min_ink,
                            pure = true,
                        }
                    end
                else
                    gutters[#gutters + 1] = {
                        s = run_start, e = i - 1, min_ink = run_min_ink,
                        pure = true,
                    }
                end
            end
            run_start, run_hard = nil, nil
        end
    end
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
    local rescue_border = o.structural_rescue_border_ink * span
    local dist = o.occluded_border_dist
    local min_seg = max(1, floor(o.occluded_min_segment * (last - first + 1) + 0.5))
    local function hasBorderLine(from, to, threshold)
        for i = max(first, from), min(last, to) do
            if ink[i] >= threshold then return true end
        end
        return false
    end
    local gutters, near = {}, {}
    local function appendCandidate(target, candidate)
        local prev = target[#target]
        if prev and candidate.s - prev.e - 1 < min_seg then
            if candidate.min_ink < prev.min_ink then
                target[#target] = candidate
            end
        else
            target[#target + 1] = candidate
        end
    end
    local run_start
    for i = first, last do
        if ink[i] <= limit then
            run_start = run_start or i
        elseif run_start then
            local run_len = i - run_start
            if run_len >= min(o.occluded_min_run, o.structural_rescue_min_run)
                and (run_start - first) >= min_seg
                and (last - i + 1) >= min_seg then
                local normal_border = hasBorderLine(
                    run_start - dist, run_start - 1, border)
                    and hasBorderLine(i, i + dist - 1, border)
                local relaxed_border = normal_border or (
                    hasBorderLine(run_start - dist, run_start - 1, rescue_border)
                    and hasBorderLine(i, i + dist - 1, rescue_border))
                local band_span = relaxed_border and checkBand(run_start, i - 1) or 1
                local g = { s = run_start, e = i - 1, min_ink = ink[run_start] }
                for k = run_start + 1, i - 1 do
                    if ink[k] < g.min_ink then g.min_ink = ink[k] end
                end
                local normal_run = run_len >= o.occluded_min_run
                if normal_run and normal_border and band_span <= o.occl_span then
                    appendCandidate(gutters, g)
                elseif o._near_occluded_regions
                    and run_len >= o.structural_rescue_min_run
                    and relaxed_border
                    and band_span <= o.structural_rescue_span then
                    local reasons = {}
                    if not normal_run then reasons[#reasons + 1] = "run" end
                    if not normal_border then reasons[#reasons + 1] = "border" end
                    if band_span > o.occl_span then reasons[#reasons + 1] = "span" end
                    g.rescue_kind = table.concat(reasons, "_")
                    appendCandidate(near, g)
                end
            end
            run_start, run_hard = nil, nil
        end
    end
    return gutters, near
end

local function thickest(gutters)
    local best = 0
    for _, g in ipairs(gutters) do
        local t = g.e - g.s + 1
        if t > best then best = t end
    end
    return best
end

-- Merge page-coloured gutters into the occluded set. A page-coloured line is
-- far stronger evidence than an occluded band, so when the two disagree by
-- less than one legal segment the page-coloured one wins; further apart they
-- are different gutters and both cut.
local function mergeGutterSets(occluded, pure, min_seg)
    if #pure == 0 then return occluded end
    if #occluded == 0 then return pure end
    local merged = {}
    local i, j = 1, 1
    while i <= #occluded or j <= #pure do
        local take_pure
        if i > #occluded then
            take_pure = true
        elseif j > #pure then
            take_pure = false
        else
            take_pure = pure[j].s <= occluded[i].s
        end
        local candidate = take_pure and pure[j] or occluded[i]
        candidate.pure = candidate.pure or take_pure
        if take_pure then j = j + 1 else i = i + 1 end
        local prev = merged[#merged]
        if prev and candidate.s - prev.e - 1 < min_seg then
            if candidate.pure and not prev.pure then
                merged[#merged] = candidate
            end
        else
            merged[#merged + 1] = candidate
        end
    end
    return merged
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

    local row_ink, col_ink, row_pure, col_pure, row_soft, col_soft =
        scanRegion(pix, bg, o.ink_delta, o.pure_delta, o.pure_gutter_soft_delta,
            x0, y0, x1, y1)
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
            local h_near, v_near = {}, {}
            local pure_rows = not o._disable_pure_gutters
                and (bg >= o.page_colour_min_light_bg
                    or bg <= o.page_colour_max_dark_bg)
                and rh >= o.occluded_min_region * o.page_h
            local pure_cols = not o._disable_pure_gutters
                and (bg >= o.page_colour_min_light_bg
                    or bg <= o.page_colour_max_dark_bg)
                and rw >= o.occluded_min_region * o.page_w
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
                h_gutters, h_near = findOccludedGutters(
                    row_ink, rw, ry0, ry1, o, checkBandRows)
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
                v_gutters, v_near = findOccludedGutters(
                    col_ink, rh, rx0, rx1, o, checkBandCols)
            end
            -- A row or column that is almost entirely page colour is a real
            -- gutter carrying a few crossing pixels (a panel corner tick, a
            -- balloon tail, scan noise). It only speaks when its own axis found
            -- nothing; when the other axis also has a candidate, the vote below
            -- decides, and it weighs evidence before thickness.
            if #h_gutters == 0 and pure_rows then
                local pure_h = findPureGutters(
                    row_ink, row_pure, row_soft, rw, o, ry0, ry1,
                    o.thin_seg_rows, o.pure_gutter_max_soft)
                if #pure_h > 0 then
                    h_gutters = mergeGutterSets(h_gutters, pure_h,
                        max(1, floor(o.occluded_min_segment
                            * (ry1 - ry0 + 1) + 0.5)))
                    o._pure_gutter_used = true
                end
            end
            if #h_gutters == 0 and #v_gutters == 0 and pure_cols then
                local pure_v = findPureGutters(
                    col_ink, col_pure, col_soft, rh, o, rx0, rx1,
                    o.thin_seg_cols)
                if #pure_v > 0 then
                    v_gutters = mergeGutterSets(v_gutters, pure_v,
                        max(1, floor(o.occluded_min_segment
                            * (rx1 - rx0 + 1) + 0.5)))
                    o._pure_gutter_used = true
                end
            end
            local function recordNear(candidates, split_rows)
                if #candidates == 0 or not o._near_occluded_regions then return end
                local kind = candidates[1].rescue_kind
                for n = 2, #candidates do
                    if candidates[n].rescue_kind ~= kind then kind = "both" end
                end
                o._near_occluded_regions[#o._near_occluded_regions + 1] = {
                    x0 = x0, y0 = y0, x1 = x1, y1 = y1,
                    tx0 = tx0, ty0 = ty0, tx1 = tx1, ty1 = ty1,
                    depth = depth, tol = tol,
                    split_rows = split_rows,
                    kind = kind,
                    area = region_area,
                }
            end
            recordNear(h_near, true)
            recordNear(v_near, false)
        end

        local split_rows
        if #h_gutters > 0 and #v_gutters > 0 then
            local function allPure(gutters)
                for _, g in ipairs(gutters) do
                    if not g.pure then return false end
                end
                return true
            end
            local h_pure, v_pure = allPure(h_gutters), allPure(v_gutters)
            if h_pure ~= v_pure then
                -- One axis offers a page-coloured line, the other a band of
                -- near-empty pixels held between two borders. Thickness cannot
                -- rank those: instead check whether the occluded gutter is
                -- still a gutter inside every band the clean line marks out.
                -- A column that only clears the top row of a 3-over-2 page is
                -- that row's gutter, not the region's, and slicing on it cuts
                -- the row below in half.
                local firm_survives = true
                local pure_g = h_pure and h_gutters or v_gutters
                local firm_g = h_pure and v_gutters or h_gutters
                local bands = {}
                local seg = h_pure and ry0 or rx0
                local stop = h_pure and ry1 or rx1
                for i = 1, #pure_g + 1 do
                    local seg_end = pure_g[i] and (pure_g[i].s - 1) or stop
                    if seg_end > seg then bands[#bands + 1] = { seg, seg_end } end
                    if pure_g[i] then seg = pure_g[i].e + 1 end
                end
                for _, firm in ipairs(firm_g) do
                    for _, band in ipairs(bands) do
                        local worst = 0
                        for i = firm.s, firm.e do
                            local inked = 0
                            for j = band[1], band[2] do
                                local px, py
                                if h_pure then
                                    px, py = x0 + i - 1, y0 + j - 1
                                else
                                    px, py = x0 + j - 1, y0 + i - 1
                                end
                                if abs(pix(px, py) - bg) > o.ink_delta then
                                    inked = inked + 1
                                end
                            end
                            worst = max(worst, inked / max(1, band[2] - band[1] + 1))
                        end
                        if worst > o.occl_tol then firm_survives = false break end
                    end
                    if not firm_survives then break end
                end
                if firm_survives then
                    -- The occluded gutter holds across the whole region: it is
                    -- a real boundary, so cut on its axis.
                    split_rows = v_pure
                else
                    split_rows = h_pure
                end
            else
                split_rows = thickest(h_gutters) >= thickest(v_gutters)
            end
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

local function hasCaptionBodyBelow(panels, caption, skip_a, skip_b, o)
    if caption.y < o.aligned_frag_caption_protect_min_y
        or caption.h > o.aligned_frag_caption_protect_max_h then
        return false
    end
    for k, body in ipairs(panels) do
        if k ~= skip_a and k ~= skip_b and body then
            local gap = body.y - (caption.y + caption.h)
            if body.h >= o.aligned_frag_caption_protect_body_min_h
                and gap >= -o.stacked_top_max_gap
                and gap <= o.stacked_top_max_gap
                and axisAlign(caption.x, caption.x + caption.w, body.x, body.x + body.w)
                    >= o.stacked_top_single_cover
                and abs(caption.x - body.x) <= o.stacked_top_caption_edge_align
                and abs((caption.x + caption.w) - (body.x + body.w))
                    <= o.stacked_top_caption_edge_align then
                return true
            end
        end
    end
    return false
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
                            local upper, lower = a, b
                            if lower.y < upper.y then upper, lower = lower, upper end
                            local gap = max(a.y, b.y) - min(a.y + a.h, b.y + b.h)
                            local total = max(a.y + a.h, b.y + b.h) - min(a.y, b.y)
                            join = gap <= o.sliver_max_gap and total <= o.sliver_max_total
                                and min(a.h, b.h) <= o.sliver_max_side
                                and not (lower.h <= o.aligned_frag_caption_protect_max_h
                                    and hasCaptionBodyBelow(panels, lower, i, j, o))
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
            if body and body.h >= 0.18 and not body.caption_partition_body then
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

-- A row of caption boxes can expose panel boundaries that are hidden in the
-- artwork below. When three or more aligned headers cover fewer body leaves,
-- split only those bodies at the header gaps before generic fragment merging
-- has a chance to swallow the boundary evidence.
local function rebuildCaptionPartitionRows(panels, o)
    for i, first in ipairs(panels) do
        if first.y >= o.caption_partition_min_y
            and first.h <= o.caption_partition_max_header_h then
            local headers = {}
            for j, p in ipairs(panels) do
                if p.y >= o.caption_partition_min_y
                    and p.h <= o.caption_partition_max_header_h
                    and axisAlign(first.y, first.y + first.h, p.y, p.y + p.h) >= 0.82 then
                    headers[#headers + 1] = j
                end
            end
            local merged_header_drop = {}
            local original_panels
            if #headers >= o.caption_partition_min_headers then
                original_panels = panels
                local working = {}
                for j, p in ipairs(panels) do
                    local copy = {}
                    for key, value in pairs(p) do copy[key] = value end
                    working[j] = copy
                end
                panels = working
                table.sort(headers, function(a, b) return panels[a].x < panels[b].x end)
                local compact = {}
                for _, idx in ipairs(headers) do
                    local prev_idx = compact[#compact]
                    local prev, cur = prev_idx and panels[prev_idx], panels[idx]
                    local raw_gap = prev and cur._raw_x0 and prev._raw_x1
                        and (cur._raw_x0 - prev._raw_x1) or math.huge
                    local union_w = prev and max(prev.x + prev.w, cur.x + cur.w)
                        - min(prev.x, cur.x) or math.huge
                    if prev and raw_gap >= 0 and raw_gap <= 3 and union_w <= 0.42 then
                        local x0, y0 = min(prev.x, cur.x), min(prev.y, cur.y)
                        prev.w = max(prev.x + prev.w, cur.x + cur.w) - x0
                        prev.h = max(prev.y + prev.h, cur.y + cur.h) - y0
                        prev.x, prev.y = x0, y0
                        prev._raw_x1 = cur._raw_x1
                        prev._raw_y0 = min(prev._raw_y0, cur._raw_y0)
                        prev._raw_y1 = max(prev._raw_y1, cur._raw_y1)
                        merged_header_drop[idx] = true
                    else
                        compact[#compact + 1] = idx
                    end
                end
                headers = compact
            end
            if #headers >= o.caption_partition_min_headers then
                local hx0 = panels[headers[1]].x
                local hx1 = panels[headers[1]].x + panels[headers[1]].w
                local header_bottom = panels[headers[1]].y + panels[headers[1]].h
                local aligned = true
                for n = 2, #headers do
                    local prev, cur = panels[headers[n - 1]], panels[headers[n]]
                    if cur.x - (prev.x + prev.w) > o.caption_partition_max_gap then
                        aligned = false
                        break
                    end
                    hx1 = max(hx1, cur.x + cur.w)
                    header_bottom = max(header_bottom, cur.y + cur.h)
                end

                if aligned and hx1 - hx0 >= o.caption_partition_min_union then
                    local header_set = {}
                    for _, idx in ipairs(headers) do header_set[idx] = true end
                    local bodies = {}
                    local bottom_anchor
                    for j, body in ipairs(panels) do
                        local gap = body.y - header_bottom
                        if not header_set[j] and not merged_header_drop[j]
                            and body.h >= 0.20
                            and gap >= -o.caption_partition_body_gap
                            and gap <= o.caption_partition_body_gap then
                            local bottom = body.y + body.h
                            if not bottom_anchor
                                or abs(bottom - bottom_anchor) <= o.caption_partition_bottom_align then
                                bodies[#bodies + 1] = j
                                bottom_anchor = bottom_anchor or bottom
                            end
                        end
                    end

                    if #bodies > 0 and #bodies < #headers then
                        local assigned = {}
                        local all_assigned = true
                        for _, header_idx in ipairs(headers) do
                            local header = panels[header_idx]
                            local center = header.x + header.w * 0.5
                            local best, best_distance
                            for _, body_idx in ipairs(bodies) do
                                local body = panels[body_idx]
                                if center >= body.x - o.caption_partition_max_gap
                                    and center <= body.x + body.w + o.caption_partition_max_gap then
                                    local distance = abs(center - (body.x + body.w * 0.5))
                                    if not best or distance < best_distance then
                                        best, best_distance = body_idx, distance
                                    end
                                end
                            end
                            if not best then
                                all_assigned = false
                                break
                            end
                            assigned[best] = assigned[best] or {}
                            assigned[best][#assigned[best] + 1] = header_idx
                        end

                        if all_assigned then
                            local body_x0, body_x1
                            for _, body_idx in ipairs(bodies) do
                                if not assigned[body_idx] then
                                    all_assigned = false
                                    break
                                end
                                local body = panels[body_idx]
                                body_x0 = body_x0 and min(body_x0, body.x) or body.x
                                body_x1 = body_x1 and max(body_x1, body.x + body.w)
                                    or (body.x + body.w)
                            end
                            if all_assigned and body_x1 - body_x0 >= o.caption_partition_min_union then
                                local drop, rebuilt = {}, {}
                                for idx in pairs(merged_header_drop) do drop[idx] = true end
                                for _, idx in ipairs(headers) do drop[idx] = true end
                                for _, body_idx in ipairs(bodies) do
                                    drop[body_idx] = true
                                    local body = panels[body_idx]
                                    local group = assigned[body_idx]
                                    table.sort(group, function(a, b) return panels[a].x < panels[b].x end)
                                    local boundaries = { body.x }
                                    for n = 1, #group - 1 do
                                        local left, right = panels[group[n]], panels[group[n + 1]]
                                        boundaries[n + 1] = (left.x + left.w + right.x) * 0.5
                                    end
                                    boundaries[#group + 1] = body.x + body.w
                                    local bottom = body.y + body.h
                                    for n, header_idx in ipairs(group) do
                                        local header = panels[header_idx]
                                        local x0 = min(boundaries[n], header.x)
                                        local x1 = max(boundaries[n + 1], header.x + header.w)
                                        local y0 = min(body.y, header.y)
                                        rebuilt[#rebuilt + 1] = {
                                            x = x0, y = y0,
                                            w = x1 - x0, h = bottom - y0,
                                            caption_partition_body = true,
                                        }
                                    end
                                end
                                local out = {}
                                for j, p in ipairs(panels) do
                                    if not drop[j] then out[#out + 1] = p end
                                end
                                for _, p in ipairs(rebuilt) do out[#out + 1] = p end
                                return out
                            end
                        end
                    end
                end
            end
            if original_panels then panels = original_panels end
        end
    end
    return panels
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
            _raw_x0 = l.x0, _raw_y0 = l.y0,
            _raw_x1 = l.x1, _raw_y1 = l.y1,
        }
    end
    if not o._disable_caption_partition then
        panels = rebuildCaptionPartitionRows(panels, o)
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

-- Strong page-colored continuity at a shared edge is direct evidence of a
-- real gutter. Merge heuristics use this independently of ink density, which
-- may be raised by a speech balloon crossing part of the gutter.
local function horizontalBoundaryPurity(pix, bg, o, w, h, xa, xb, ya, yb)
    local y0 = max(0, floor(ya * h + 0.5))
    local y1 = min(h - 1, floor(yb * h + 0.5))
    local x0 = max(0, floor(xa * w))
    local x1 = min(w - 1, floor(xb * w))
    if x1 <= x0 then return 0 end
    local span, best = x1 - x0 + 1, 0
    for y = y0, y1 do
        local pure = 0
        for x = x0, x1 do
            if abs(pix(x, y) - bg) <= o.pure_delta then pure = pure + 1 end
        end
        best = max(best, pure / span)
    end
    return best
end

local function horizontalBoundaryProfile(pix, bg, o, w, h, xa, xb, ya, yb)
    local y0 = max(0, floor(min(ya, yb) * h + 0.5))
    local y1 = min(h - 1, floor(max(ya, yb) * h + 0.5))
    local x0 = max(0, floor(xa * w))
    local x1 = min(w - 1, floor(xb * w))
    if x1 <= x0 or y1 < y0 then return 0, 1, 0 end
    local span = x1 - x0 + 1
    local best_pure, least_ink, best_clean = 0, 1, 0
    for y = y0, y1 do
        local pure, ink = 0, 0
        for x = x0, x1 do
            local d = abs(pix(x, y) - bg)
            if d <= o.pure_delta then
                pure = pure + 1
            elseif d > o.ink_delta then
                ink = ink + 1
            end
        end
        best_pure = max(best_pure, pure / span)
        least_ink = min(least_ink, ink / span)
        -- best_pure and least_ink can come from different rows; a gutter needs
        -- one row that is page-coloured *and* free of ink, so track that too.
        if ink / span <= o.boundary_clean_max_ink then
            best_clean = max(best_clean, pure / span)
        end
    end
    return best_pure, least_ink, best_clean
end

-- Purity of the cleanest column at a seam between two boxes.
local function verticalBoundaryPurity(pix, bg, o, w, h, xc, ya, yb)
    local y0 = max(0, floor(ya * h + 0.5))
    local y1 = min(h - 1, floor(yb * h + 0.5))
    if y1 <= y0 then return 0 end
    local span, best = y1 - y0 + 1, 0
    local center = floor(xc + 0.5)
    for x = max(0, center - 5), min(w - 1, center + 5) do
        local pure = 0
        for y = y0, y1 do
            if abs(pix(x, y) - bg) <= o.pure_delta then pure = pure + 1 end
        end
        best = max(best, pure / span)
    end
    return best
end

-- A borderless lower splash can sit behind a row of framed panels. X-Y cuts
-- cannot represent that overlap and instead partition the splash into the
-- exposed rectangles around the foreground row. Detect the strong page-edge
-- signature cheaply: white side margins abruptly become sustained artwork on
-- both edges in the lower half of the page.
local function findBottomFullBleedStart(pix, w, h, o)
    local band = max(2, floor(w * o.bottom_full_bleed_edge_frac + 0.5))
    local min_y = floor(h * o.bottom_full_bleed_min_y + 0.5)
    local max_y = floor(h * o.bottom_full_bleed_max_y + 0.5)
    local min_run = floor(h * o.bottom_full_bleed_min_run + 0.5)
    local start_y, last_active, gap

    for y = min_y, h - 1 do
        local left_ink, right_ink = 0, 0
        for x = 0, band - 1 do
            if abs(pix(x, y) - 255) > o.ink_delta then left_ink = left_ink + 1 end
            if abs(pix(w - 1 - x, y) - 255) > o.ink_delta then right_ink = right_ink + 1 end
        end
        local active = min(left_ink, right_ink) / band
            >= o.bottom_full_bleed_edge_ink
        if active then
            if not start_y then start_y = y end
            last_active = y
            gap = 0
        elseif start_y then
            gap = (gap or 0) + 1
            if gap > o.bottom_full_bleed_max_gap_px then
                if start_y <= max_y and last_active - start_y + 1 >= min_run then
                    return start_y / h
                end
                start_y, last_active, gap = nil, nil, nil
            end
        end
    end
    if start_y and start_y <= max_y
        and last_active - start_y + 1 >= min_run then
        return start_y / h
    end
    return nil
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
                        local width_ratio = wide.w / max(narrow.w, 0.001)
                        if wide.w >= 1.5 * narrow.w
                            and width_ratio <= o.partition_max_width_ratio
                            and narrow.h <= o.partition_max_narrow_h
                            and upper.y >= o.partition_min_upper_y
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

local function mergeAlignedVerticalFragments(panels, pix, bg, o, w, h)
    local merged = true
    while merged do
        merged = false
        local best_i, best_j, best_total
        for i = 1, #panels do
            local a = panels[i]
            if a then
                for j = i + 1, #panels do
                    local b = panels[j]
                    if b then
                        local upper, lower = a, b
                        if lower.y < upper.y then upper, lower = lower, upper end
                        local gap = lower.y - (upper.y + upper.h)
                        local total = lower.y + lower.h - upper.y
                        local x_align = axisAlign(upper.x, upper.x + upper.w, lower.x, lower.x + lower.w)
                        local height_ok = upper.h <= o.aligned_frag_top_max_h
                        if not height_ok and o._structural_candidate
                            and upper.h <= o.aligned_frag_art_top_max_h
                            and x_align >= o.aligned_frag_x_align
                            and gap <= o.aligned_frag_max_gap
                            and gap >= -o.aligned_frag_max_gap
                            and total <= o.aligned_frag_max_total then
                            height_ok = horizontalBoundaryPurity(
                                pix, bg, o, w, h,
                                max(upper.x, lower.x),
                                min(upper.x + upper.w, lower.x + lower.w),
                                upper.y + upper.h - o.pad_frac,
                                lower.y + o.pad_frac)
                                    < o.aligned_frag_art_max_purity
                        end
                        if x_align >= o.aligned_frag_x_align
                            and height_ok
                            and gap <= o.aligned_frag_max_gap and gap >= -o.aligned_frag_max_gap
                            and total <= o.aligned_frag_max_total
                            and not hasCaptionBodyBelow(panels, lower, i, j, o)
                            and boundaryInk(pix, bg, o, w, h,
                                max(upper.x, lower.x), min(upper.x + upper.w, lower.x + lower.w),
                                upper.y + upper.h - o.pad_frac,
                                lower.y + o.pad_frac) >= o.aligned_frag_min_boundary_ink
                            and (not best_i or total < best_total) then
                            best_i, best_j, best_total = i, j, total
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

local function mergeArtworkSeamSplits(panels, pix, bg, o, w, h)
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
                        local wide_candidate = union_w >= o.art_seam_split_min_union
                            and left.w >= o.art_seam_split_min_piece_w
                            and right.w >= o.art_seam_split_min_piece_w
                        local narrow_candidate = union_w >= o.narrow_seam_split_min_union
                            and union_w <= o.narrow_seam_split_max_union
                            and left.w >= o.narrow_seam_split_min_piece_w
                            and right.w >= o.narrow_seam_split_min_piece_w
                            and min(left.h, right.h) >= o.narrow_seam_split_min_h
                        -- A light strip of artwork at a panel's edge (an icy
                        -- wall, a white cloak, a smoke plume) reads as a full
                        -- height gutter and shears a sliver off the panel. The
                        -- give-away is that the seam holds no page-coloured
                        -- column at all, which a real gutter always does.
                        local sliver_candidate = min(left.w, right.w)
                            <= o.seam_sliver_max_w
                            and max(left.w, right.w) >= o.seam_sliver_min_body_w
                            and min(left.h, right.h) >= o.seam_sliver_min_h
                            and min(left.y, right.y) >= o.seam_sliver_min_y
                        if (min(left.y, right.y) >= o.art_seam_split_min_y
                                or sliver_candidate)
                            and y_align >= o.art_seam_split_y_align
                            and gap <= o.art_seam_split_max_gap
                            and (wide_candidate or narrow_candidate
                                or sliver_candidate) then
                            local seam = ((left.x + left.w + right.x) * 0.5) * w
                            local ya = max(left.y, right.y)
                            local yb = min(left.y + left.h, right.y + right.h)
                            local center = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -3, 3)
                            local side_l = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -10, -4)
                            local side_r = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, 4, 10)
                            local gutter_purity = verticalBoundaryPurity(
                                pix, bg, o, w, h, seam, ya, yb)
                            local light_art_split = center >= o.art_seam_split_min_center_ink
                                and center <= o.art_seam_split_max_center_ink
                                and side_l <= o.art_seam_split_max_side_ink
                                and side_r <= o.art_seam_split_max_side_ink
                            local narrow_light_split = center >= o.art_seam_split_min_center_ink
                                and center <= o.art_seam_split_max_center_ink
                                and side_l <= o.narrow_seam_split_max_side_ink
                                and side_r <= o.narrow_seam_split_max_side_ink
                            local dark_art_split = center >= o.art_seam_split_dark_min_center_ink
                                and center <= o.art_seam_split_dark_max_center_ink
                                and side_l >= o.art_seam_split_dark_min_side_ink
                                and side_l <= o.art_seam_split_dark_max_side_ink
                                and side_r >= o.art_seam_split_dark_min_side_ink
                                and side_r <= o.art_seam_split_dark_max_side_ink
                            local gutter_ok = union_w < 0.80
                                or gutter_purity < o.art_merge_boundary_max_purity
                            local sliver_split = sliver_candidate
                                and gap >= -o.art_seam_split_max_gap
                                and gutter_purity < o.seam_sliver_max_purity
                            if (sliver_split
                                or (gutter_ok
                                and ((wide_candidate and (light_art_split or dark_art_split))
                                or (narrow_candidate and narrow_light_split))))
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

-- Every real gutter contains at least one line of almost pure page colour
-- across the shared edge of its two panels - that is what a gutter is. When
-- two column-aligned, touching boxes have no such line between them, the row
-- cut that separated them came from a gutter found in a *neighbouring* column
-- and sliced one tall panel, so the two boxes are one panel. Purity is the
-- only reliable signal here: ink density across an artwork seam varies far
-- too much to threshold. Restricted to full-size boxes (caption strips are
-- owned by the caption repairs) and to pages whose estimated background is a
-- real page colour, because purity is meaningless against mid-tone artwork.
local function mergeGutterlessStacks(panels, pix, bg, o, w, h)
    if o._disable_gutterless_merge then return panels end
    if bg < o.page_colour_min_light_bg and bg > o.page_colour_max_dark_bg then
        return panels
    end
    local merged = true
    while merged do
        merged = false
        local best_i, best_j, best_purity
        for i = 1, #panels do
            local a = panels[i]
            if a then
                for j = i + 1, #panels do
                    local b = panels[j]
                    if b then
                        local upper, lower = a, b
                        if lower.y < upper.y then upper, lower = lower, upper end
                        local gap = lower.y - (upper.y + upper.h)
                        local total = lower.y + lower.h - upper.y
                        local x_align = axisAlign(
                            a.x, a.x + a.w, b.x, b.x + b.w)
                        local y_align = axisAlign(
                            a.y, a.y + a.h, b.y, b.y + b.h)
                        if x_align >= o.gutterless_align
                            and y_align < o.gutterless_align
                            and gap <= o.gutterless_max_gap
                            and gap >= -o.gutterless_max_gap
                            and min(upper.h, lower.h) >= o.gutterless_min_side
                            and total * max(a.w, b.w)
                                <= o.gutterless_max_union_area then
                            -- finalizePanels pads the boxes outward, so the
                            -- two may overlap; scan the whole band between
                            -- the two edges either way round.
                            local purity, boundary_ink = horizontalBoundaryProfile(
                                pix, bg, o, w, h,
                                max(upper.x, lower.x),
                                min(upper.x + upper.w, lower.x + lower.w),
                                min(upper.y + upper.h, lower.y) - o.pad_frac,
                                max(upper.y + upper.h, lower.y) + o.pad_frac)
                            -- A line that carries almost no ink is a gutter
                            -- even when the page there is grey rather than
                            -- white; artwork running across the seam never
                            -- leaves one.
                            --
                            -- The padded edges can also sit well away from the
                            -- real seam, so a clean line anywhere inside the
                            -- union vetoes the merge: this step exists for
                            -- stacks with no gutter at all, and any gutter
                            -- between the two boxes means two panels.
                            local _, _, inner_clean = horizontalBoundaryProfile(
                                pix, bg, o, w, h,
                                max(upper.x, lower.x),
                                min(upper.x + upper.w, lower.x + lower.w),
                                upper.y + total * o.gutterless_inner_margin,
                                upper.y + total * (1 - o.gutterless_inner_margin))
                            if purity < o.gutterless_max_purity
                                and boundary_ink > o.gutterless_min_boundary_ink
                                and inner_clean < o.gutterless_inner_max_purity
                                and (not best_i or purity < best_purity) then
                                best_i, best_j, best_purity = i, j, purity
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

-- A single narrow fragment inside an otherwise balanced four-box row is a
-- common result when a speech-box channel cuts one real panel. Restrict the
-- repair to the page structure that makes the split objectively anomalous:
-- one dominant splash, four aligned pieces, and a two-panel row below.
local function mergeSingleNarrowRowSplit(panels, o)
    if #panels ~= o.narrow_row_split_panel_count then return panels end

    local has_splash = false
    for _, panel in ipairs(panels) do
        if panel.w * panel.h >= o.narrow_row_split_splash_min_area then
            has_splash = true
            break
        end
    end
    if not has_splash then return panels end

    for i, narrow in ipairs(panels) do
        if narrow.w <= o.narrow_row_split_max_piece_w then
            local row = {}
            for idx, panel in ipairs(panels) do
                if axisAlign(narrow.y, narrow.y + narrow.h,
                        panel.y, panel.y + panel.h) >= o.narrow_row_split_align
                    and abs(narrow.y - panel.y) <= o.narrow_row_split_max_gap
                    and abs(narrow.y + narrow.h - panel.y - panel.h)
                        <= o.narrow_row_split_max_gap then
                    row[#row + 1] = idx
                end
            end

            if #row == o.narrow_row_split_row_count then
                table.sort(row, function(a, b) return panels[a].x < panels[b].x end)
                local row_x0 = panels[row[1]].x
                local row_x1 = panels[row[#row]].x + panels[row[#row]].w
                if row_x1 - row_x0 >= o.narrow_row_split_min_row_union then
                    for pos, idx in ipairs(row) do
                        if idx == i then
                            for _, neighbor_pos in ipairs({ pos - 1, pos + 1 }) do
                                local neighbor_idx = row[neighbor_pos]
                                if neighbor_idx then
                                    local neighbor = panels[neighbor_idx]
                                    local left, right = narrow, neighbor
                                    if right.x < left.x then left, right = right, left end
                                    local gap = right.x - (left.x + left.w)
                                    local union_w = max(left.x + left.w,
                                        right.x + right.w) - min(left.x, right.x)
                                    if gap >= -2 * o.pad_frac
                                        and gap <= o.narrow_row_split_max_gap
                                        and union_w >= o.narrow_row_split_min_union
                                        and union_w <= o.narrow_row_split_max_union then
                                        local min_w, max_w = union_w, union_w
                                        for _, other_idx in ipairs(row) do
                                            if other_idx ~= i and other_idx ~= neighbor_idx then
                                                min_w = min(min_w, panels[other_idx].w)
                                                max_w = max(max_w, panels[other_idx].w)
                                            end
                                        end

                                        local row_bottom = max(
                                            narrow.y + narrow.h,
                                            neighbor.y + neighbor.h)
                                        local bottom = {}
                                        for other_idx, panel in ipairs(panels) do
                                            if other_idx ~= i and other_idx ~= neighbor_idx
                                                and panel.y >= row_bottom - 0.03 then
                                                bottom[#bottom + 1] = panel
                                            end
                                        end
                                        table.sort(bottom, function(a, b) return a.x < b.x end)
                                        local bottom_union = 0
                                        if #bottom == 2 then
                                            bottom_union = bottom[2].x + bottom[2].w
                                                - bottom[1].x
                                        end

                                        if min_w >= o.narrow_row_split_min_merged_w
                                            and max_w / min_w
                                                <= o.narrow_row_split_max_width_ratio
                                            and bottom_union
                                                >= o.narrow_row_split_bottom_min_union then
                                            local nx = min(narrow.x, neighbor.x)
                                            local ny = min(narrow.y, neighbor.y)
                                            narrow.w = max(narrow.x + narrow.w,
                                                neighbor.x + neighbor.w) - nx
                                            narrow.h = max(narrow.y + narrow.h,
                                                neighbor.y + neighbor.h) - ny
                                            narrow.x, narrow.y = nx, ny
                                            panels[neighbor_idx] = false
                                            local out = {}
                                            for _, panel in ipairs(panels) do
                                                if panel then out[#out + 1] = panel end
                                            end
                                            return out
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return panels
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

-- Rejoin consecutive pieces of a top-left panel only while artwork crosses
-- their shared seam. The first genuinely blank gutter terminates the group,
-- preserving the next framed panel in the row.
local function mergeTopLeftArtFragments(panels, pix, bg, o, w, h)
    local band = {}
    for i, p in ipairs(panels) do
        if p.y <= o.top_left_art_max_y then
            band[#band + 1] = { idx = i, box = p }
        end
    end
    if #band < 3 then return panels, false end
    table.sort(band, function(a, b) return a.box.x < b.box.x end)
    if band[1].box.x > o.top_left_art_max_x then return panels, false end

    local first = band[1].box
    local last = 1
    for n = 2, #band do
        local prev, cur = band[n - 1].box, band[n].box
        local gap = cur.x - (prev.x + prev.w)
        local y_align = axisAlign(prev.y, prev.y + prev.h, cur.y, cur.y + cur.h)
        if gap > o.top_left_art_max_gap or y_align < o.top_left_art_y_align then break end

        local seam = ((prev.x + prev.w + cur.x) * 0.5) * w
        local ya = max(prev.y, cur.y)
        local yb = min(prev.y + prev.h, cur.y + cur.h)
        local center = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -3, 3)
        local side_l = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, -10, -4)
        local side_r = verticalBandInk(pix, bg, o, w, h, seam, ya, yb, 4, 10)
        local purity = verticalBoundaryPurity(pix, bg, o, w, h, seam, ya, yb)
        if center < o.top_left_art_min_seam_ink
            or side_l > o.top_left_art_max_side_ink
            or side_r > o.top_left_art_max_side_ink
            or purity > o.top_left_art_max_purity then
            break
        end
        last = n
    end
    if last == 1 then return panels, false end

    local x0, y0 = first.x, first.y
    local x1, y1 = first.x + first.w, first.y + first.h
    for n = 2, last do
        local p = band[n].box
        x0, y0 = min(x0, p.x), min(y0, p.y)
        x1, y1 = max(x1, p.x + p.w), max(y1, p.y + p.h)
        panels[band[n].idx] = false
    end
    first.x, first.y, first.w, first.h = x0, y0, x1 - x0, y1 - y0
    local out = {}
    for _, p in ipairs(panels) do if p then out[#out + 1] = p end end
    return out, true
end

local function rebuildBottomFullBleedSplash(panels, o)
    local start_y = o._bottom_full_bleed_start
    if not start_y or o.occl_span ~= o.occluded_max_span_loose then return panels end

    local pieces, intervals, crossing = {}, {}, 0
    for i, p in ipairs(panels) do
        local bottom = p.y + p.h
        if bottom >= 0.98 and p.y >= start_y + o.bottom_full_bleed_piece_inset then
            pieces[#pieces + 1] = i
            intervals[#intervals + 1] = { p.x, p.x + p.w }
        elseif p.y < start_y and bottom > start_y + 0.05 then
            crossing = crossing + 1
        end
    end
    if #pieces < 2 or crossing < 2 then return panels end

    table.sort(intervals, function(a, b) return a[1] < b[1] end)
    local cover, x0, x1 = 0, intervals[1][1], intervals[1][2]
    for n = 2, #intervals do
        local item = intervals[n]
        if item[1] <= x1 + 0.02 then
            x1 = max(x1, item[2])
        else
            cover = cover + x1 - x0
            x0, x1 = item[1], item[2]
        end
    end
    cover = cover + x1 - x0
    if cover < o.bottom_full_bleed_min_cover then return panels end

    for _, i in ipairs(pieces) do panels[i] = false end
    -- Keep the reconstructed splash just below the generic 0.55 soft gate.
    -- The few skipped rows are the featureless full-bleed lead-in behind the
    -- foreground panels, while the visible splash remains edge-to-edge.
    local panel_y = max(start_y, 1 - o.max_panel_area + 0.002)
    local out = {}
    for _, p in ipairs(panels) do if p then out[#out + 1] = p end end
    out[#out + 1] = { x = 0, y = panel_y, w = 1, h = 1 - panel_y }
    return out
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
            if base.y >= o.strip_row_min_y and base.h <= o.strip_row_max_h then
                for j = i + 1, #panels do
                    local p = panels[j]
                    if not used[j]
                        and p.y >= o.strip_row_min_y
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
                    local gutter_purity = verticalBoundaryPurity(
                        pix, bg, o, w, h, seam, ya, yb)
                    if (center < 0.08 and max(side_l, side_r) < 0.35)
                        or gutter_purity >= o.strip_row_max_gutter_purity then
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
            if body and body.h >= 0.18 and not body.caption_partition_body then
                local parts = {}
                local ux0, ux1, uy0, uy1
                local max_part_h = 0
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
                                max_part_h = max(max_part_h, p.h)
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
                    local single_caption_ok = false
                    if #parts == 1 then
                        local top = panels[parts[1]]
                        local xa = max(body.x, top.x)
                        local xb = min(body.x + body.w, top.x + top.w)
                        single_ok = cover >= o.stacked_top_single_cover
                            and boundaryInk(pix, bg, o, w, h, xa, xb,
                                top.y + top.h - o.pad_frac,
                                body.y + o.pad_frac) >= o.stacked_top_min_boundary_ink
                        single_caption_ok = top.y >= o.stacked_top_caption_min_y
                            and body.y >= o.stacked_top_caption_body_min_y
                            and top.h <= o.stacked_top_caption_max_h
                            and cover >= o.stacked_top_single_cover
                            and abs(top.x - body.x) <= o.stacked_top_caption_edge_align
                            and abs((top.x + top.w) - (body.x + body.w))
                                <= o.stacked_top_caption_edge_align
                    end
                    local wide_multi_ok = body.w <= o.stacked_top_multi_max_body_w
                        or (uy0 >= o.stacked_top_multi_full_min_y
                            and max_part_h <= o.stacked_top_wide_multi_max_part_h
                            and total_h <= o.stacked_top_wide_multi_max_total)
                    local multi_ok = #parts >= 2
                        and wide_multi_ok
                        and cover >= o.stacked_top_min_cover
                        and max_part_h <= body.h * o.stacked_top_multi_max_height_ratio
                    if multi_ok and (body.y <= 0.30 or body.y >= 0.60) then
                        local boundary_purity = horizontalBoundaryPurity(
                            pix, bg, o, w, h,
                            max(body.x, ux0), min(body.x + body.w, ux1),
                            uy1 - o.pad_frac, body.y + o.pad_frac)
                        multi_ok = boundary_purity < o.merge_boundary_max_purity
                    end
                    local width_ok = (ux1 - ux0) <= body.w * o.stacked_top_max_width_ratio
                    if ok
                        and (single_ok or single_caption_ok or multi_ok)
                        and width_ok
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

-- A caption/header may span two panels below it and be isolated as a short
-- panel by an occluded cut. Preserve both panels and extend each through the
-- shared header instead of displaying that header as a separate crop.
local function distributeSharedHeaders(panels, o)
    local drop = {}
    for i, header in ipairs(panels) do
        local top_shared = header.y <= 0.08 and header.w >= 0.45
        if (header.y >= o.shared_header_min_y or top_shared)
            and header.h <= o.shared_header_max_h then
            local gap_limit = top_shared and 0.04 or o.shared_header_max_gap
            local bodies = {}
            local ux0, ux1
            for j, body in ipairs(panels) do
                if i ~= j and body.h >= 0.15 and not body.caption_partition_body then
                    local gap = body.y - (header.y + header.h)
                    local overlap_x = min(header.x + header.w, body.x + body.w)
                        - max(header.x, body.x)
                    if gap >= -gap_limit
                        and gap <= gap_limit
                        and overlap_x > 0
                        and body.w <= header.w * 0.75 then
                        bodies[#bodies + 1] = j
                        ux0 = ux0 and min(ux0, body.x) or body.x
                        ux1 = ux1 and max(ux1, body.x + body.w) or (body.x + body.w)
                    end
                end
            end
            if #bodies >= 2 then
                table.sort(bodies, function(a, b) return panels[a].x < panels[b].x end)
                local cover = (min(header.x + header.w, ux1) - max(header.x, ux0)) / header.w
                local aligned = true
                for n = 2, #bodies do
                    if abs(panels[bodies[n]].y - panels[bodies[1]].y) > gap_limit then
                        aligned = false
                        break
                    end
                end
                if aligned and cover >= o.shared_header_min_cover then
                    for _, j in ipairs(bodies) do
                        local body = panels[j]
                        local bottom = body.y + body.h
                        body.y = min(body.y, header.y)
                        body.h = bottom - body.y
                    end
                    drop[i] = true
                end
            end
        end
    end
    if not next(drop) then return panels end
    local out = {}
    for i, p in ipairs(panels) do
        if not drop[i] then out[#out + 1] = p end
    end
    return out
end

-- A loose occluded pass can partition one borderless top splash into a dense
-- rectangular mosaic. Rejoin only the narrow signature seen on these pages:
-- four or more touching pieces, almost full page width, high rectangular fill,
-- and one genuinely large anchor piece. Ordinary framed grids do not qualify.
local function mergeShatteredTopSplash(panels, o)
    if o.occl_span ~= o.occluded_max_span_loose then return panels end
    local group = {}
    local ux0, uy0, ux1, uy1
    local has_anchor = false
    for i, p in ipairs(panels) do
        if p.y <= 0.30 and p.y + p.h <= o.splash_mosaic_max_h + 0.02 then
            group[#group + 1] = i
            ux0 = ux0 and min(ux0, p.x) or p.x
            uy0 = uy0 and min(uy0, p.y) or p.y
            ux1 = ux1 and max(ux1, p.x + p.w) or (p.x + p.w)
            uy1 = uy1 and max(uy1, p.y + p.h) or (p.y + p.h)
            if p.w >= 0.45 and p.h >= 0.35 then has_anchor = true end
        end
    end
    if #group < o.splash_mosaic_min_count or not has_anchor then return panels end
    local bw, bh = ux1 - ux0, uy1 - uy0
    if ux0 > 0.02 or uy0 > 0.02
        or bw < o.splash_mosaic_min_union
        or bh < o.splash_mosaic_min_h or bh > o.splash_mosaic_max_h then
        return panels
    end
    local metrics_panels = {}
    for _, i in ipairs(group) do metrics_panels[#metrics_panels + 1] = panels[i] end
    local metrics = PanelDetect.layoutMetrics(metrics_panels, o)
    if metrics.union_coverage / max(0.001, bw * bh) < o.splash_mosaic_min_fill then
        return panels
    end
    local keep = group[1]
    panels[keep] = { x = ux0, y = uy0, w = bw, h = bh }
    for n = 2, #group do panels[group[n]] = false end
    local out = {}
    for _, p in ipairs(panels) do if p then out[#out + 1] = p end end
    return out
end

-- Two short fragments sitting across the top of a near-full-width body are
-- another stable splash signature. A single detached title is intentionally
-- excluded so chapter headings remain governed by their dedicated rule.
local function mergeTopSplashCap(panels)
    for i, body in ipairs(panels) do
        local area = body.w * body.h
        if body.x <= 0.02 and body.w >= 0.95
            and body.y >= 0.08 and body.y <= 0.20
            and body.h >= 0.35 and area < 0.55 then
            local caps, cx0, cx1 = {}, nil, nil
            for j, p in ipairs(panels) do
                if i ~= j and p.y <= body.y
                    and p.y + p.h >= body.y - 0.03
                    and p.x >= body.x - 0.02
                    and p.x + p.w <= body.x + body.w + 0.02 then
                    caps[#caps + 1] = j
                    cx0 = cx0 and min(cx0, p.x) or p.x
                    cx1 = cx1 and max(cx1, p.x + p.w) or (p.x + p.w)
                end
            end
            local single_full_cap = #caps == 1
                and panels[caps[1]].y <= 0.03
                and panels[caps[1]].w >= body.w * 0.90
            if (#caps >= 2 and cx1 - cx0 >= body.w * 0.80)
                or single_full_cap then
                local bottom = body.y + body.h
                body.y = min(body.y, panels[caps[1]].y)
                body.h = bottom - body.y
                for _, j in ipairs(caps) do panels[j] = false end
                local out = {}
                for _, p in ipairs(panels) do if p then out[#out + 1] = p end end
                return out
            end
        end
    end
    return panels
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
                elseif vx_top then
                    local yn = hy / h
                    local xt = vx_top / w
                    out[#out + 1] = { x = p.x, y = p.y, w = xt - p.x, h = yn - p.y }
                    out[#out + 1] = { x = xt, y = p.y, w = p.x + p.w - xt, h = yn - p.y }
                    out[#out + 1] = { x = p.x, y = yn, w = p.w, h = p.y + p.h - yn }
                elseif vx_bottom then
                    local yn = hy / h
                    local xb = vx_bottom / w
                    out[#out + 1] = { x = p.x, y = p.y, w = p.w, h = yn - p.y }
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

-- A panel can never extend past its own gutter. The highest page-coloured,
-- ink-free line above a panel's top edge is therefore a hard floor for every
-- caption recovery: without it a light band in the row above (smoke, snow, a
-- white cloak, an icy wall) passes the ink/purity tests and the panel swallows
-- its neighbour. The highest such line is used rather than the first one going
-- up, because the blank lines inside the white caption box being recovered
-- look exactly like a gutter; the artwork above the real gutter never does.
local function captionExpandFloor(pix, bg, o, w, h, x0, x1, y_top, max_up)
    x0 = max(0, x0)
    x1 = min(w, x1)
    local span = max(1, x1 - x0)
    local pure_limit = o.caption_expand_gutter_purity * span
    local ink_limit = o.caption_expand_gutter_ink * span
    -- finalizePanels pads every box outward, so a panel's stored top already
    -- sits above its own gutter. Search below it too or the gutter that bounds
    -- this panel is never seen.
    local start = min(h - 1, y_top + floor(o.pad_frac * h + 0.5))
    local floor_y
    for y = max(0, max_up), start do
        local pure, ink = 0, 0
        for x = x0, x1 - 1 do
            local d = abs(pix(x, y) - bg)
            if d <= o.pure_delta then
                pure = pure + 1
            elseif d > o.ink_delta then
                ink = ink + 1
            end
        end
        if pure >= pure_limit and ink <= ink_limit then
            floor_y = y + 1
            break
        end
    end
    if not floor_y then return max_up end
    return min(y_top, floor_y)
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
                    local expand_floor = captionExpandFloor(
                        pix, bg, o, w, h, x0, x1, y_top, max_up)
                    local gutter_bound = expand_floor > max_up
                    max_up = max(max_up, expand_floor)
                    local block = max(2, floor(o.bottom_caption_block + 0.5))
                    local candidate = y_top
                    local hit_dense = false
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
                                hit_dense = true
                                break
                            end
                        else
                            candidate = y
                            y = y - block
                        end
                    end

                    -- The gutter above is hard evidence of where the panel
                    -- starts, so a clean scan may snap to it even when the
                    -- remaining distance is below the minimum expansion.
                    -- Dense material between the gutter and the stop point is
                    -- this panel's own frame or caption border, never the
                    -- panel above, so a short dense band may be crossed.
                    local snapped = false
                    if gutter_bound
                        and (not hit_dense
                            or candidate - max_up
                                <= o.caption_expand_snap_gap * h) then
                        candidate = max_up
                        snapped = true
                    end

                    if y_top - candidate >= o.bottom_caption_min_expand * h
                        or (snapped and candidate < y_top) then
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

                local ordered, min_pos, min_y = {}, nil, 1
                for _, idx in ipairs(group) do ordered[#ordered + 1] = idx end
                table.sort(ordered, function(a, b) return panels[a].x < panels[b].x end)
                for pos, idx in ipairs(ordered) do
                    local p = panels[idx]
                    if not min_pos or p.y < min_y then
                        min_pos, min_y = pos, p.y
                    end
                end
                if min_pos and min_pos > 1 and min_pos < #ordered then
                    for _, idx in ipairs(ordered) do
                        local p = panels[idx]
                        local bottom = p.y + p.h
                        local px0 = max(0, floor(p.x * w + 0.5))
                        local px1 = min(w, floor((p.x + p.w) * w + 0.5))
                        local floor_y = captionExpandFloor(
                            pix, bg, o, w, h, px0, px1,
                            floor(p.y * h + 0.5), floor(min_y * h + 0.5)) / h
                        if p.y - min_y > 0
                            and min_y >= floor_y
                            and p.y - min_y <= o.bottom_caption_peer_max_expand
                            and abs(bottom - (panels[ordered[min_pos]].y + panels[ordered[min_pos]].h))
                                <= o.bottom_caption_peer_align then
                            p.y = min_y
                            p.h = bottom - min_y
                        end
                    end
                end
            else
                used[i] = true
            end
        end
    end
    return panels
end

-- Speech boxes often protrude above a lower panel and overlap the artwork in
-- the row above. The recursive cut then assigns that strip to the upper panel.
-- Recover it only when the panel belongs to a coherent row, an upper panel
-- actually overlaps the boundary, and an upward scan finds a light caption
-- band before it reaches dense artwork.
local function expandProtrudingCaptionTops(panels, pix, bg, o, w, h, raw_count)
    local count = #panels
    local coverage = PanelDetect.layoutMetrics(panels, o).union_coverage
    local legacy_layout = (raw_count == 13 and count >= 8 and count <= 10)
        or (raw_count == 12 and (count == 9 or count == 10))
        or ((raw_count == 10 or raw_count == 11) and count == 10)
    local coherent_layout = count >= o.protruding_caption_general_min_count
        and count <= o.protruding_caption_general_max_count
        and raw_count >= count
        and raw_count - count <= o.protruding_caption_general_max_raw_excess
    local eligible_layout = legacy_layout or coherent_layout
    if not eligible_layout
        or coverage < o.protruding_caption_min_union
        or coverage >= o.protruding_caption_max_union then
        return panels
    end
    local anchors = {}
    for i, panel in ipairs(panels) do
        anchors[i] = { x = panel.x, y = panel.y, w = panel.w, h = panel.h }
    end
    local recovered = {}
    for i, panel in ipairs(panels) do
        local anchor = anchors[i]
        if anchor.y >= o.protruding_caption_min_y
            and anchor.y <= o.protruding_caption_max_y then
            local peer_count = 1
            local same_top_peer_count = 1
            for j, peer in ipairs(anchors) do
                if i ~= j then
                    local same_top = abs(anchor.y - peer.y)
                        <= o.protruding_caption_row_top_align
                    local same_bottom = abs(
                        anchor.y + anchor.h - peer.y - peer.h)
                        <= o.protruding_caption_row_bottom_align
                    if same_top then
                        same_top_peer_count = same_top_peer_count + 1
                    end
                    if same_top or same_bottom then
                        peer_count = peer_count + 1
                    end
                end
            end
            local has_peer = peer_count >= 3
                or (peer_count >= 2 and anchor.y <= 0.40)
            if coherent_layout and not legacy_layout then
                has_peer = same_top_peer_count >= 3
            end

            local has_upper = false
            if has_peer then
                for j, upper in ipairs(anchors) do
                    if i ~= j then
                        local overlap_x = min(anchor.x + anchor.w, upper.x + upper.w)
                            - max(anchor.x, upper.x)
                        local upper_bottom = upper.y + upper.h
                        if upper.y <= anchor.y - o.protruding_caption_upper_min_offset
                            and upper_bottom >= anchor.y - o.pad_frac
                            and upper_bottom <= anchor.y
                                + o.protruding_caption_upper_max_gap
                            and overlap_x >= anchor.w
                                * o.protruding_caption_upper_min_overlap then
                            has_upper = true
                            break
                        end
                    end
                end
            end

            if has_upper then
                local x0 = max(0, floor(panel.x * w + 0.5))
                local x1 = min(w, floor((panel.x + panel.w) * w + 0.5))
                local y_top = max(0, floor(panel.y * h + 0.5))
                local max_up = max(0, y_top
                    - floor(o.protruding_caption_max_expand * h + 0.5))
                local expand_floor = captionExpandFloor(
                    pix, bg, o, w, h, x0, x1, y_top, max_up)
                local gutter_bound = expand_floor > max_up
                max_up = max(max_up, expand_floor)
                local block = max(2, floor(o.protruding_caption_block + 0.5))
                local candidate = y_top
                local dense_above = false
                local hit_dense = false
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
                    if ink_ratio >= o.protruding_caption_stop_ink
                        and pure_ratio <= o.protruding_caption_stop_max_pure then
                        if dense_above then
                            candidate = min(y_top, candidate + block)
                            hit_dense = true
                            break
                        else
                            dense_above = true
                        end
                    else
                        dense_above = false
                    end
                    candidate = y
                    y = y - block
                end

                -- The gutter above is hard evidence of where this panel
                -- starts, so a scan that reaches it without meeting artwork
                -- may snap to it even for a sub-minimal expansion. A short
                -- dense band just below the gutter is this panel's own frame
                -- or caption border and may be crossed too.
                local snapped = false
                if gutter_bound
                    and (not hit_dense
                        or candidate - max_up
                            <= o.caption_expand_snap_gap * h) then
                    candidate = max_up
                    snapped = true
                end

                local safety_layout = raw_count == 12 and count == 10
                    or (raw_count == 11 and count == 10
                        and anchor.y <= o.protruding_caption_safety_max_y)
                if safety_layout then
                    candidate = max(max_up, candidate
                        - floor(o.protruding_caption_safety_px + 0.5))
                end

                if y_top - candidate >= o.protruding_caption_min_expand * h
                    or (snapped and candidate < y_top) then
                    local ink, pure, total = 0, 0, 0
                    for yy = candidate, y_top - 1 do
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
                    if ink / max(1, total) >= o.protruding_caption_min_ink
                        and pure / max(1, total)
                            >= o.protruding_caption_min_pure then
                        local bottom = panel.y + panel.h
                        panel.y = candidate / h
                        panel.h = bottom - panel.y
                        recovered[i] = true
                    end
                end
            end
        end
    end


    -- If two members of one aligned row independently prove that their
    -- captions protrude upward, carry the same top to a missed peer. This
    -- avoids clipping a low-ink caption while still requiring corroborating
    -- pixel evidence from the row.
    for i, anchor in ipairs(anchors) do
        local group = {}
        for j, peer in ipairs(anchors) do
            local same_top = abs(anchor.y - peer.y)
                <= o.protruding_caption_row_top_align
            local same_bottom = abs(anchor.y + anchor.h - peer.y - peer.h)
                <= o.protruding_caption_row_bottom_align
            if same_top or same_bottom then group[#group + 1] = j end
        end
        if #group >= 3 then
            local evidence, target = 0, anchor.y
            for _, idx in ipairs(group) do
                if recovered[idx] then
                    evidence = evidence + 1
                    target = min(target, panels[idx].y)
                end
            end
            local required_evidence = o.protruding_caption_peer_min_evidence
            if coherent_layout or (raw_count == 12 and count == 10) then
                required_evidence = 1
            end
            if evidence >= required_evidence then
                for _, idx in ipairs(group) do
                    local panel = panels[idx]
                    local px0 = max(0, floor(panel.x * w + 0.5))
                    local px1 = min(w, floor((panel.x + panel.w) * w + 0.5))
                    local floor_y = captionExpandFloor(
                        pix, bg, o, w, h, px0, px1,
                        floor(panel.y * h + 0.5), floor(target * h + 0.5)) / h
                    if panel.y > target
                        and target >= floor_y
                        and anchors[idx].y - target
                            <= o.protruding_caption_max_expand + o.pad_frac then
                        local bottom = panel.y + panel.h
                        panel.y = target
                        panel.h = bottom - target
                    end
                end
            end
        end
    end
    return panels
end

local function expandOverlappingCaptionRows(panels, pix, bg, o, w, h)
    local used = {}
    for i, base in ipairs(panels) do
        if not used[i]
            and not base.caption_partition_body
            and base.y >= o.overlapping_caption_min_y
            and base.y <= o.overlapping_caption_max_y then
            local group = {}
            local base_bottom = base.y + base.h
            for j, p in ipairs(panels) do
                if not used[j]
                    and not p.caption_partition_body
                    and abs(p.y - base.y) <= o.overlapping_caption_top_align
                    and abs((p.y + p.h) - base_bottom)
                        <= o.overlapping_caption_bottom_align then
                    group[#group + 1] = j
                end
            end
            if #group == o.overlapping_caption_panel_count then
                table.sort(group, function(a, b) return panels[a].x < panels[b].x end)
                local x0 = panels[group[1]].x
                local x1 = panels[group[1]].x + panels[group[1]].w
                local aligned = true
                for n = 2, #group do
                    local prev, cur = panels[group[n - 1]], panels[group[n]]
                    if cur.x - (prev.x + prev.w) > o.overlapping_caption_max_gap then
                        aligned = false
                        break
                    end
                    x1 = max(x1, cur.x + cur.w)
                end

                local upper_overlap = false
                for j, upper in ipairs(panels) do
                    if not used[j] then
                        local bottom = upper.y + upper.h
                        local overlap_x = min(x1, upper.x + upper.w) - max(x0, upper.x)
                        if upper.y < base.y - 0.10
                            and bottom >= base.y
                            and bottom <= base.y + o.overlapping_caption_max_gap
                            and overlap_x >= (x1 - x0) * 0.35 then
                            upper_overlap = true
                            break
                        end
                    end
                end

                local caption_evidence = false
                if aligned and upper_overlap
                    and x1 - x0 >= o.overlapping_caption_min_union then
                    local step = o.overlapping_caption_probe_step
                    local bx0 = max(0, floor(x0 * w + 0.5))
                    local bx1 = min(w, floor(x1 * w + 0.5))
                    local boundary = floor((base.y + o.pad_frac) * h + 0.5)
                    local max_boundary_ink = 0
                    for y = max(0, boundary - 4), min(h - 1, boundary + 4) do
                        local ink, total = 0, 0
                        for x = bx0, bx1 - 1, step do
                            total = total + 1
                            if abs(pix(x, y) - bg) > o.content_bounds_ink_delta then
                                ink = ink + 1
                            end
                        end
                        max_boundary_ink = max(max_boundary_ink, ink / max(1, total))
                    end

                    local top_background = 0
                    for _, idx in ipairs(group) do
                        local p = panels[idx]
                        local px0 = max(0, floor(p.x * w + 0.5))
                        local px1 = min(w, floor((p.x + p.w) * w + 0.5))
                        local py0 = max(0, floor(
                            (p.y + o.overlapping_caption_top_probe_start) * h + 0.5))
                        local py1 = min(h, floor(
                            (p.y + o.overlapping_caption_top_probe_end) * h + 0.5))
                        local near_bg, total = 0, 0
                        for y = py0, py1 - 1, step do
                            for x = px0, px1 - 1, step do
                                total = total + 1
                                if abs(pix(x, y) - bg) <= o.content_bounds_ink_delta then
                                    near_bg = near_bg + 1
                                end
                            end
                        end
                        top_background = top_background + near_bg / max(1, total)
                    end
                    top_background = top_background / #group
                    caption_evidence = max_boundary_ink
                            <= o.overlapping_caption_max_boundary_ink
                        and top_background <= o.overlapping_caption_max_top_background
                end

                if caption_evidence then
                    local target_y = max(0, base.y - o.overlapping_caption_expand)
                    for _, idx in ipairs(group) do
                        local p = panels[idx]
                        local px0 = max(0, floor(p.x * w + 0.5))
                        local px1 = min(w, floor((p.x + p.w) * w + 0.5))
                        target_y = max(target_y, captionExpandFloor(
                            pix, bg, o, w, h, px0, px1,
                            floor(p.y * h + 0.5),
                            floor(target_y * h + 0.5)) / h)
                    end
                    local py0 = max(0, floor(target_y * h + 0.5))
                    local py1 = min(h, floor(base.y * h + 0.5))
                    local inked = 0
                    for _, idx in ipairs(group) do
                        local p = panels[idx]
                        local px0 = max(0, floor(p.x * w + 0.5))
                        local px1 = min(w, floor((p.x + p.w) * w + 0.5))
                        local ink, total = 0, 0
                        for y = py0, py1 - 1 do
                            for x = px0, px1 - 1 do
                                total = total + 1
                                if abs(pix(x, y) - bg) > o.ink_delta then ink = ink + 1 end
                            end
                        end
                        if ink / max(1, total) >= o.overlapping_caption_min_ink then
                            inked = inked + 1
                        end
                    end
                    if inked >= 2 and target_y < base.y then
                        for _, idx in ipairs(group) do
                            local p = panels[idx]
                            local bottom = p.y + p.h
                            p.y = target_y
                            p.h = bottom - target_y
                            used[idx] = true
                        end
                    end
                end
            end
        end
    end
    return panels
end

local function removeDetachedTopTextPanels(panels, o)
    if #panels <= o.top_text_min_below then return panels end
    local drop = {}
    local drop_count = 0
    for i, p in ipairs(panels) do
        if p.y <= o.top_text_max_y
            and p.y + p.h <= o.top_text_max_bottom
            and p.h <= o.top_text_max_h
            and p.w <= o.top_text_max_w
            and p.x >= o.top_text_min_margin
            and p.x + p.w <= 1 - o.top_text_min_margin then
            local below = 0
            for j, q in ipairs(panels) do
                if j ~= i and q.y >= p.y + p.h - o.pad_frac then
                    below = below + 1
                end
            end
            if below >= o.top_text_min_below then
                drop[i] = true
                drop_count = drop_count + 1
            end
        end
    end
    if drop_count == 0 or #panels - drop_count < o.min_panels then return panels end
    local out = {}
    for i, p in ipairs(panels) do
        if not drop[i] then out[#out + 1] = p end
    end
    return out
end

local function expandSideTakeoverCaptions(panels, pix, bg, o, w, h)
    local protect_aligned_rows = false
    if o.side_takeover_protect_aligned_rows and #panels == 7 then
        for _, panel in ipairs(panels) do
            if panel.w * panel.h >= 0.45 then
                protect_aligned_rows = true
                break
            end
        end
    end
    for _, lower in ipairs(panels) do
        if lower.y >= o.side_takeover_min_y then
            local aligned_peer = false
            for _, peer in ipairs(panels) do
                if protect_aligned_rows and peer ~= lower
                    and abs(peer.y - lower.y) <= o.side_takeover_edge_align
                    and abs((peer.y + peer.h) - (lower.y + lower.h))
                        <= o.side_takeover_edge_align then
                    aligned_peer = true
                    break
                end
            end
            local best, best_expand
            for _, upper in ipairs(aligned_peer and {} or panels) do
                if upper ~= lower
                    and upper.y < lower.y
                    and upper.w <= lower.w * o.side_takeover_max_upper_w_ratio then
                    local gap = lower.y - (upper.y + upper.h)
                    local left_aligned = abs(lower.x - upper.x) <= o.side_takeover_edge_align
                    local right_aligned = abs((lower.x + lower.w) - (upper.x + upper.w)) <= o.side_takeover_edge_align
                    local contained_x = upper.x >= lower.x - o.side_takeover_edge_align
                        and upper.x + upper.w <= lower.x + lower.w + o.side_takeover_edge_align
                    if contained_x
                        and (left_aligned or right_aligned)
                        and gap <= o.side_takeover_max_gap
                        and gap >= -o.side_takeover_max_gap then
                        local target = max(lower.y - o.side_takeover_max_expand, upper.y)
                        local expand = lower.y - target
                        if expand > 0 and (not best or expand > best_expand) then
                            best, best_expand = target, expand
                        end
                    end
                end
            end
            if best then
                local px0 = max(0, floor(lower.x * w + 0.5))
                local px1 = min(w, floor((lower.x + lower.w) * w + 0.5))
                local floor_y = captionExpandFloor(
                    pix, bg, o, w, h, px0, px1,
                    floor(lower.y * h + 0.5), floor(best * h + 0.5)) / h
                if best >= floor_y then
                    local bottom = lower.y + lower.h
                    lower.y = best
                    lower.h = bottom - best
                end
            end
        end
    end
    return panels
end

local function overlapArea(a, b)
    local ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
    local iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
    return ix * iy
end

local function removeContainedDuplicatePanels(panels, o)
    local drop = {}
    for i, a in ipairs(panels) do
        local area_a = a.w * a.h
        for j, b in ipairs(panels) do
            if i ~= j and not drop[i] then
                local area_b = b.w * b.h
                if area_b > area_a
                    and area_b <= o.contained_duplicate_parent_max_area
                    and area_a <= area_b * o.contained_duplicate_max_area_ratio
                    and overlapArea(a, b) >= area_a * o.contained_duplicate_overlap then
                    drop[i] = true
                end
            end
        end
    end
    local out = {}
    for i, p in ipairs(panels) do
        if not drop[i] then out[#out + 1] = p end
    end
    return out
end

local function finiteNumber(v)
    return type(v) == "number"
        and v == v
        and v ~= math.huge
        and v ~= -math.huge
end

--- Measure the final normalized panel layout without counting overlaps twice.
-- Exposed for the desktop harness and diagnostics; detection uses the same
-- function, so confidence tests exercise the exact production calculation.
function PanelDetect.layoutMetrics(panels, opts)
    local o = opts or DEFAULTS
    local epsilon = 1e-6
    local metrics = {
        panel_count = #panels,
        summed_area = 0,
        union_coverage = 0,
        overlap_excess = 0,
        max_iou = 0,
        max_panel_area = 0,
        geometry_valid = true,
        geometry_reason = nil,
    }
    local edges = {}

    for _, p in ipairs(panels) do
        if type(p) ~= "table"
            or not finiteNumber(p.x) or not finiteNumber(p.y)
            or not finiteNumber(p.w) or not finiteNumber(p.h) then
            metrics.geometry_valid = false
            metrics.geometry_reason = "non_finite_geometry"
            return metrics
        end
        local area = p.w * p.h
        metrics.summed_area = metrics.summed_area + area
        metrics.max_panel_area = max(metrics.max_panel_area, area)
        if p.w < o.min_side_frac or p.h < o.min_side_frac
            or area < o.min_area_frac then
            metrics.geometry_valid = false
            metrics.geometry_reason = "undersized_panel"
        elseif p.x < -epsilon or p.y < -epsilon
            or p.x + p.w > 1 + epsilon or p.y + p.h > 1 + epsilon then
            metrics.geometry_valid = false
            metrics.geometry_reason = "out_of_bounds_panel"
        end
        edges[#edges + 1] = max(0, min(1, p.x))
        edges[#edges + 1] = max(0, min(1, p.x + p.w))
    end

    for i = 1, #panels do
        for j = i + 1, #panels do
            metrics.max_iou = max(metrics.max_iou, iou(panels[i], panels[j]))
        end
    end

    table.sort(edges)
    for i = 1, #edges - 1 do
        local xa, xb = edges[i], edges[i + 1]
        if xb > xa then
            local intervals = {}
            for _, p in ipairs(panels) do
                if p.x < xb and p.x + p.w > xa then
                    intervals[#intervals + 1] = {
                        max(0, min(1, p.y)),
                        max(0, min(1, p.y + p.h)),
                    }
                end
            end
            table.sort(intervals, function(a, b)
                if a[1] ~= b[1] then return a[1] < b[1] end
                return a[2] < b[2]
            end)
            local covered, y0, y1 = 0, nil, nil
            for _, interval in ipairs(intervals) do
                if not y0 then
                    y0, y1 = interval[1], interval[2]
                elseif interval[1] <= y1 then
                    y1 = max(y1, interval[2])
                else
                    covered = covered + max(0, y1 - y0)
                    y0, y1 = interval[1], interval[2]
                end
            end
            if y0 then covered = covered + max(0, y1 - y0) end
            metrics.union_coverage = metrics.union_coverage + (xb - xa) * covered
        end
    end
    metrics.overlap_excess = max(0, metrics.summed_area - metrics.union_coverage)
    return metrics
end

local function isValid(panels, o, min_cov, raw_count)
    local metrics = PanelDetect.layoutMetrics(panels, o)
    local cov = metrics.union_coverage
    if not metrics.geometry_valid then
        return false, false, metrics.geometry_reason, metrics
    end
    if metrics.max_iou > o.merge_iou then
        return false, false, "duplicate_overlap", metrics
    end
    if #panels == 1 then
        local p = panels[1]
        if (raw_count or 0) > 1
            and cov >= o.single_panel_min_coverage
            and p.w * p.h >= o.single_panel_min_area
            and p.w >= o.single_panel_min_side
            and p.h >= o.single_panel_min_side then
            if metrics.max_panel_area >= o.max_panel_area_hard then
                return false, false, "hard_oversized_panel", metrics
            elseif metrics.max_panel_area >= o.max_panel_area then
                return false, true, "soft_oversized_panel", metrics
            end
            return true, false, "hard", metrics
        end
    end
    if #panels < o.min_panels or #panels > o.max_panels
        or cov < (min_cov or o.min_coverage) then
        return false, false, "count_or_union_coverage", metrics
    end
    if metrics.max_panel_area >= o.max_panel_area_hard then
        return false, false, "hard_oversized_panel", metrics
    elseif metrics.max_panel_area >= o.max_panel_area then
        return false, true, "soft_oversized_panel", metrics
    end
    return true, false, "hard", metrics
end

local function layoutSimilarity(a, b)
    if #a == 0 or #b == 0 then return 0 end
    local function directed(from, to)
        local total = 0
        for _, p in ipairs(from) do
            local best = 0
            for _, q in ipairs(to) do best = max(best, iou(p, q)) end
            total = total + best
        end
        return total / #from
    end
    return (directed(a, b) + directed(b, a)) * 0.5
end

local function softCandidatesAgree(a, b)
    return abs(#a.panels - #b.panels) <= 1
        and abs(a.metrics.union_coverage - b.metrics.union_coverage) <= 0.10
        and layoutSimilarity(a.panels, b.panels) >= 0.80
end

local function softCandidateHasCleanPartition(candidate, o)
    return #candidate.panels >= o.min_panels
        and candidate.raw_count == #candidate.panels
        and candidate.metrics.union_coverage >= o.relaxed_min_coverage
        and candidate.metrics.max_iou <= 0.10
end

-- A caption box drawn at a panel's top often pokes above the panel's frame into
-- the artwork of the row above, and where two rows touch with no gutter the cut
-- has nowhere to go but through the caption. The other caption repairs need a
-- row of peers to agree before they act, so a two-panel row is left clipped.
--
-- This one carries its own evidence. Walking up from the panel's top it accepts
-- only caption material -- page colour carrying text -- and stops at a wall of
-- solid ink, which is the artwork of the panel above. No wall inside the budget
-- means no expansion at all, so a light neighbour (snow, sky, a white cloak)
-- can never be swallowed: the rule can only ever recover what sits between the
-- panel and the dark artwork immediately over it.
local function expandCaptionBoxTops(panels, pix, bg, o, w, h)
    if o._disable_caption_box_tops then return panels end
    for _, panel in ipairs(panels) do
        if panel.y >= o.caption_box_min_y then
            local x0 = max(0, floor(panel.x * w + 0.5))
            local x1 = min(w, floor((panel.x + panel.w) * w + 0.5))
            local span = x1 - x0
            local y_top = max(0, floor(panel.y * h + 0.5))
            local limit = max(0, y_top - floor(o.caption_box_max_expand * h + 0.5))
            if span > 0 and y_top > limit then
                -- The highest clean page-coloured line in range is the panel's
                -- own boundary: whatever sits above it belongs to the row
                -- above. The *highest* one, not the nearest, because the blank
                -- lines inside the caption box being recovered look exactly
                -- like a gutter too.
                local gutter = captionExpandFloor(
                    pix, bg, o, w, h, x0, x1, y_top, limit)
                local bound = max(limit, gutter)
                local on_gutter = gutter > limit and gutter < y_top
                local wall, light_rows, text_rows, box_rows = nil, 0, 0, 0
                for y = y_top - 1, bound, -1 do
                    local ink, pure = 0, 0
                    local run, longest = 0, 0
                    for x = x0, x1 - 1 do
                        local d = abs(pix(x, y) - bg)
                        if d > o.ink_delta then
                            ink = ink + 1
                            run = 0
                        elseif d <= o.pure_delta then
                            pure = pure + 1
                            run = run + 1
                            if run > longest then longest = run end
                        else
                            run = 0
                        end
                    end
                    ink, pure = ink / span, pure / span
                    if ink >= o.caption_box_wall_ink
                        and pure <= o.caption_box_wall_pure then
                        wall = y
                        break
                    end
                    if pure >= o.caption_box_light_min_pure then
                        light_rows = light_rows + 1
                    end
                    if ink >= o.caption_box_text_min_ink then
                        text_rows = text_rows + 1
                    end
                    -- A caption box is a rectangle of page colour, so its rows
                    -- carry one long unbroken run. Light artwork -- snow, a
                    -- floor, a pale sky -- is just as bright on average but
                    -- broken up by the drawing, and that is what separates a
                    -- caption to recover from the row above.
                    if longest >= o.caption_box_min_block_run * span then
                        box_rows = box_rows + 1
                    end
                end
                -- Solid artwork stops the walk; so does the panel's own gutter.
                -- Reaching the expansion budget with neither means there is no
                -- evidence of where this panel ends, so nothing is claimed.
                local new_top_px = wall and (wall + 1) or (on_gutter and bound)
                if new_top_px and light_rows >= o.caption_box_min_light_rows
                    and text_rows >= o.caption_box_min_text_rows
                    and box_rows >= o.caption_box_min_block_rows then
                    local new_top = new_top_px / h
                    if new_top < panel.y then
                        panel.h = panel.h + (panel.y - new_top)
                        panel.y = new_top
                    end
                end
            end
        end
    end
    return panels
end

local function postprocessLeaves(leaves, pix, bg, o, w, h)
    local panels = finalizePanels(leaves, w, h, o)
    panels = mergePartitionLeftovers(panels, pix, bg, o, w, h)
    panels = mergeAlignedVerticalFragments(panels, pix, bg, o, w, h)
    panels = mergeFalseHorizontalSplits(panels, pix, bg, o, w, h)
    panels = mergeTopBandArtFragments(panels, pix, bg, o, w, h)
    local top_left_art_merge
    panels, top_left_art_merge = mergeTopLeftArtFragments(panels, pix, bg, o, w, h)
    panels = mergeSideStripStacks(panels, o)
    panels = mergeLeftCaptionStrips(panels, o)
    panels = mergeStackedTopFragments(panels, pix, bg, o, w, h)
    panels = mergePanoramicStripRows(panels, pix, bg, o, w, h)
    panels = mergeArtworkSeamSplits(panels, pix, bg, o, w, h)
    panels = mergeGutterlessStacks(panels, pix, bg, o, w, h)
    panels = distributeSharedHeaders(panels, o)
    panels = mergeTopSplashCap(panels)
    panels = mergeShatteredTopSplash(panels, o)
    panels = rebuildBottomFullBleedSplash(panels, o)
    panels = splitLargeCompositeGrids(panels, pix, bg, o, w, h)
    panels = expandBottomCaptionTops(panels, pix, bg, o, w, h)
    panels = expandProtrudingCaptionTops(
        panels, pix, bg, o, w, h, #leaves)
    if not o._disable_overlapping_caption then
        panels = expandOverlappingCaptionRows(panels, pix, bg, o, w, h)
    end
    panels = expandSideTakeoverCaptions(panels, pix, bg, o, w, h)
    panels = expandCaptionBoxTops(panels, pix, bg, o, w, h)
    panels = removeDetachedTopTextPanels(panels, o)
    panels = removeContainedDuplicatePanels(panels, o)
    panels = mergeSingleNarrowRowSplit(panels, o)
    return panels, top_left_art_merge
end

-- Three or more equal-height strips side by side, none of them separated by a
-- gutter, are one panel the cut shattered -- not a row of narrow panels. When
-- that happens the rest of the page is usually being sliced just as arbitrarily
-- (it is what an X-Y cut does to a splash with insets drawn over it), so the
-- honest answer is the whole-page overview rather than a plausible-looking
-- partition. A real row of narrow panels is excluded twice over: its seams hold
-- page colour, and it spans the content width instead of a corner of it.
local function shatteredStripRow(panels, pix, bg, o, w, h)
    if o._disable_shattered_strip_guard then return false end
    local sorted = {}
    for _, p in ipairs(panels) do sorted[#sorted + 1] = p end
    table.sort(sorted, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    local run = {}
    local function runSpan()
        local first, last = run[1], run[#run]
        return last.x + last.w - first.x
    end
    local function flush()
        if #run < o.shattered_min_run then return false end
        if runSpan() > o.shattered_max_span then return false end
        for i = 2, #run do
            local left, right = run[i - 1], run[i]
            local seam = ((left.x + left.w + right.x) * 0.5) * w
            local ya = max(left.y, right.y)
            local yb = min(left.y + left.h, right.y + right.h)
            if verticalBoundaryPurity(pix, bg, o, w, h, seam, ya, yb)
                >= o.shattered_max_seam_purity then
                return false
            end
        end
        return true
    end
    for _, p in ipairs(sorted) do
        local prev = run[#run]
        local same_row = prev
            and abs(p.y - prev.y) <= o.shattered_row_align
            and abs(p.h - prev.h) <= o.shattered_row_align * 2
            and p.x - (prev.x + prev.w) <= o.shattered_max_gap
            and p.x >= prev.x
        local strip = p.w <= o.shattered_max_w and p.h >= p.w * o.shattered_min_ratio
        if not strip then
            if flush() then return true end
            run = {}
        elseif same_row then
            run[#run + 1] = p
        else
            if flush() then return true end
            run = { p }
        end
    end
    return flush()
end

local function rerunStructuralCandidate(kind, cfg, pix, bg, o, w, h, ex, ey)
    local saved_span = o.occl_span
    local saved_border = o.occluded_border_ink
    local saved_near = o._near_occluded_regions
    local saved_run = o.occluded_min_run
    local saved_structural_candidate = o._structural_candidate
    if kind:find("span", 1, true) then
        o.occl_span = o.structural_rescue_span
    end
    if kind:find("border", 1, true) then
        o.occluded_border_ink = o.structural_rescue_border_ink
    end
    if kind:find("run", 1, true) then
        o.occluded_min_run = o.structural_rescue_min_run
    end
    o._near_occluded_regions = nil
    o._structural_candidate = true

    local leaves = {}
    cut(pix, bg, o, cfg.tol, ex, ey, w - ex, h - ey, 1, leaves)
    local panels, top_left_art_merge = postprocessLeaves(leaves, pix, bg, o, w, h)

    o.occl_span = saved_span
    o.occluded_border_ink = saved_border
    o.occluded_min_run = saved_run
    o._near_occluded_regions = saved_near
    o._structural_candidate = saved_structural_candidate
    return {
        panels = panels,
        leaves = leaves,
        raw_count = #leaves,
        top_left_art_merge = top_left_art_merge,
        rescue_kind = kind,
    }
end

local function hasWideTopComposite(panels)
    if #panels ~= 4 then return false end
    for _, panel in ipairs(panels) do
        if panel.y < 0.10 and panel.w >= 0.80 and panel.h >= 0.40
            and panel.w * panel.h >= 0.35 then
            return true
        end
    end
    return false
end

local function isCoherentWideTopGrid(panels)
    if #panels ~= 5 then return false end
    local ordered = {}
    for i, panel in ipairs(panels) do ordered[i] = panel end
    table.sort(ordered, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    local top, middle = ordered[1], ordered[2]
    if top.y >= 0.10 or top.w < 0.80 or top.h < 0.40
        or middle.w < 0.80 or middle.y <= top.y + 0.30
        or middle.y > top.y + top.h + 0.04 then
        return false
    end
    local bottom = { ordered[3], ordered[4], ordered[5] }
    table.sort(bottom, function(a, b) return a.x < b.x end)
    local bottom_top = bottom[1].y
    local bottom_left = bottom[1].x
    local bottom_right = bottom[1].x + bottom[1].w
    for i, panel in ipairs(bottom) do
        if abs(panel.y - bottom_top) > 0.03
            or panel.w < 0.18 or panel.h < 0.12 or panel.h > 0.30 then
            return false
        end
        if i > 1 and panel.x - bottom_right > 0.05 then return false end
        bottom_right = max(bottom_right, panel.x + panel.w)
    end
    return bottom_top > middle.y + 0.10
        and bottom_top <= middle.y + middle.h + 0.05
        and bottom_right - bottom_left >= 0.80
end

local function candidateIsHard(candidate, base, cfg, o, dense_split)
    local valid, soft, reason, metrics = isValid(
        candidate.panels, o, cfg.min_cov, candidate.raw_count)
    local min_base_area = base.pure_split
        and o.structural_rescue_pure_min_base_area
        or o.structural_rescue_min_base_area
    candidate.metrics = metrics
    candidate.reason = reason
    candidate.gain = #candidate.panels - #base.panels
    candidate.coherent_rows = isCoherentWideTopGrid(candidate.panels)
    candidate.redistribution = candidate.gain == 0
        and candidate.raw_count > base.raw_count
        and base.metrics.max_panel_area >= min_base_area
        and metrics.max_panel_area <= base.metrics.max_panel_area
            * o.structural_rescue_redistribution_max_area_ratio
    if not valid or soft then return false, reason end
    if candidate.gain < 1 and not candidate.redistribution then
        return false, "no_gain"
    end
    if candidate.gain > o.structural_rescue_max_gain then return false, "excessive_gain" end
    if not dense_split
        and base.metrics.max_panel_area < min_base_area then
        return false, "base_not_composite"
    end
    if metrics.union_coverage < o.structural_rescue_min_coverage then
        return false, "low_coverage"
    end
    if candidate.raw_count - #candidate.panels > o.structural_rescue_max_raw_excess then
        return false, "fragmented_candidate"
    end
    if abs(metrics.union_coverage - base.metrics.union_coverage) > 0.12 then
        return false, "coverage_shift"
    end
    if metrics.max_panel_area > base.metrics.max_panel_area * 0.98
        and not candidate.coherent_rows then
        return false, "largest_panel_unchanged"
    end
    if candidate.redistribution then return true, "accepted_redistribution" end
    if candidate.coherent_rows then return true, "accepted_coherent_rows" end
    return true, "accepted"
end

local function tryStructuralRescue(base, regions, cfg, pix, bg, o, w, h, ex, ey)
    if not regions or #regions == 0 then return nil, 0 end
    if base.raw_count < #base.panels then return nil, 0 end
    -- A pass that needed page-coloured lines to find some of its rows is on a
    -- page whose gutters are systematically noisy. Its base is already better
    -- than the "one giant merged block" the rescue gates were written for, so
    -- the composite-evidence gates are relaxed for it. Acceptance itself stays
    -- unchanged: candidateIsHard still has to prove the candidate is better.
    local min_base_area = base.pure_split
        and o.structural_rescue_pure_min_base_area
        or o.structural_rescue_min_base_area
    local max_base_raw_excess = base.pure_split
        and o.structural_rescue_pure_max_base_raw_excess
        or o.structural_rescue_max_base_raw_excess
    local coarse_split = #base.panels <= 3
        and #regions >= o.structural_rescue_min_combined_regions
        and base.metrics.max_panel_area >= o.structural_rescue_coarse_min_area
        and base.metrics.max_panel_area < o.structural_rescue_coarse_max_area
        and base.metrics.union_coverage >= o.structural_rescue_coarse_min_coverage
        and base.metrics.union_coverage < o.structural_rescue_coarse_max_coverage
    local dense_split = #base.panels == o.structural_rescue_dense_panel_count
        and #regions >= o.structural_rescue_dense_min_regions
        and base.raw_count - #base.panels <= o.structural_rescue_max_base_raw_excess
        and base.metrics.max_panel_area >= o.structural_rescue_dense_min_area
        and base.metrics.max_panel_area < o.structural_rescue_dense_max_area
        and base.metrics.union_coverage >= o.structural_rescue_dense_min_coverage
        and base.metrics.union_coverage < o.structural_rescue_dense_max_coverage
    if not dense_split
        and base.metrics.max_panel_area < min_base_area then
        return nil, 0
    end
    if not dense_split and base.raw_count > #base.panels
        and base.metrics.max_panel_area
            < min(o.structural_rescue_fragmented_min_area, min_base_area) then
        return nil, 0
    end
    if base.raw_count - #base.panels > max_base_raw_excess then
        return nil, 0
    end
    if #base.panels <= 4 and not coarse_split
        and base.metrics.max_panel_area < o.structural_rescue_sparse_min_area then
        return nil, 0
    end
    if #base.panels == 5
        and base.metrics.max_panel_area < o.structural_rescue_five_min_area then
        return nil, 0
    end
    if base.metrics.union_coverage >= o.structural_rescue_coherent_coverage
        and base.metrics.max_panel_area < o.structural_rescue_coherent_max_area then
        return nil, 0
    end
    if base.reason == "soft_oversized_panel" and #base.panels <= 4
        and base.metrics.union_coverage >= o.structural_rescue_coherent_coverage then
        return nil, 0
    end
    if base.metrics.union_coverage >= o.structural_rescue_splash_coverage
        and base.metrics.max_panel_area >= o.structural_rescue_splash_min_area then
        return nil, 0
    end
    local needed = { span = false, border = false, run = false }
    for _, region in ipairs(regions) do
        if region.kind:find("span", 1, true) then needed.span = true end
        if region.kind:find("border", 1, true) then needed.border = true end
        if region.kind:find("run", 1, true) then needed.run = true end
    end
    if hasWideTopComposite(base.panels) then
        needed.border = true
        needed.run = true
    end
    if coarse_split then
        needed.span = true
        needed.run = true
    end

    local candidates = {}
    local agreement_candidates = {}
    local tried = 0
    local diagnostics = o._debug_structural and {} or nil
    local simple_kinds = {}
    for _, kind in ipairs({ "span", "border", "run" }) do
        if needed[kind] then simple_kinds[#simple_kinds + 1] = kind end
    end
    local already_run = {}
    -- Border relaxation alone is weak evidence unless the base is obviously
    -- one merged block: either almost nothing was segmented, or a page with
    -- proven page-coloured gutters still has a panel covering a third of it.
    local trust_border = #base.panels <= 2
        or (base.pure_split
            and base.metrics.max_panel_area
                >= o.structural_rescue_border_trust_area)
    -- Relaxing the minimum run length is the weakest evidence of all, but a
    -- base that only became valid because page-coloured lines rescued a few
    -- of its rows, and still carries a block covering half the page, is worse
    -- than anything the run candidate can produce.
    local trust_run = base.pure_split
        and base.metrics.max_panel_area >= o.structural_rescue_run_trust_area
    local function run(kind)
        if already_run[kind] then return end
        already_run[kind] = true
        tried = tried + 1
        local candidate = rerunStructuralCandidate(
            kind, cfg, pix, bg, o, w, h, ex, ey)
        local accepted, reason = candidateIsHard(
            candidate, base, cfg, o, dense_split)
        if accepted and kind:find("_", 1, true)
            and #base.panels < o.structural_rescue_min_combined_base
            and not coarse_split then
            accepted, reason = false, "combined_base_too_sparse"
        end
        if accepted and kind:find("_", 1, true)
            and #regions < o.structural_rescue_min_combined_regions then
            accepted, reason = false, "weak_combined_evidence"
        end
        if diagnostics then
            diagnostics[#diagnostics + 1] = string.format(
                "%s:%s raw=%d panels=%d gain=%d union=%.3f max=%.3f",
                kind, reason, candidate.raw_count, #candidate.panels, candidate.gain,
                candidate.metrics.union_coverage, candidate.metrics.max_panel_area)
        end
        if accepted then
            candidates[#candidates + 1] = candidate
            return candidate
        elseif dense_split and candidate.gain == 1
            and reason == "largest_panel_unchanged" then
            agreement_candidates[#agreement_candidates + 1] = candidate
        end
    end
    -- On a page whose gutters needed page-coloured lines, a single-panel gain
    -- is trustworthy when the candidate also clearly shrinks the largest
    -- remaining block: that is the signature of one merged panel being split,
    -- not of artwork being shredded.
    local function decisiveGain(candidate)
        if candidate.gain >= o.structural_rescue_min_gain then return true end
        return base.pure_split and candidate.gain >= 1
            and candidate.metrics.max_panel_area
                <= base.metrics.max_panel_area
                    * o.structural_rescue_pure_gain1_area_ratio
    end
    for _, kind in ipairs(simple_kinds) do
        local candidate = run(kind)
        local decisive = candidate
            and (candidate.redistribution or candidate.coherent_rows
                or decisiveGain(candidate)
                or (dense_split and candidate.gain == 1))
            and (candidate.rescue_kind ~= "run" or trust_run)
            and (candidate.rescue_kind ~= "border" or trust_border)
        if decisive and not coarse_split then return candidate, tried, diagnostics end
    end

    if #base.panels <= 6 and #simple_kinds >= 2
        and #regions >= o.structural_rescue_min_combined_regions then
        run(table.concat(simple_kinds, "_"))
    end
    if #candidates == 0
        and #base.panels <= 8
        and #regions >= 3
        and base.metrics.max_panel_area >= 0.35
        and needed.span and needed.border then
        run("span_border")
    end

    local best
    for _, candidate in ipairs(candidates) do
        local standalone_evidence = (candidate.rescue_kind ~= "run" or trust_run)
            and (candidate.rescue_kind ~= "border" or trust_border)
        if (standalone_evidence or candidate.coherent_rows)
            and (candidate.redistribution or candidate.coherent_rows
                or decisiveGain(candidate))
            and (not best
                or (#base.panels <= 6 and candidate.gain > best.gain)
                or (#base.panels > 6 and candidate.gain < best.gain)) then
            best = candidate
        end
    end
    if best then return best, tried, diagnostics end

    if dense_split and #agreement_candidates >= 2 then
        for a = 1, #agreement_candidates do
            for b = a + 1, #agreement_candidates do
                if layoutSimilarity(
                    agreement_candidates[a].panels,
                    agreement_candidates[b].panels)
                        >= o.structural_rescue_agreement then
                    agreement_candidates[a].reason = "accepted_dense_agreement"
                    return agreement_candidates[a], tried, diagnostics
                end
            end
        end
    end

    -- A one-panel gain is accepted only when a second threshold family
    -- independently reconstructs the same layout.
    if #base.panels <= o.structural_rescue_agreement_max_base
        and #candidates > 0 then
        for _, kind in ipairs({ "span", "border", "run" }) do run(kind) end
        for a = 1, #candidates do
            for b = a + 1, #candidates do
                if candidates[a].gain == 1 and candidates[b].gain == 1
                    and layoutSimilarity(candidates[a].panels, candidates[b].panels)
                        >= o.structural_rescue_agreement then
                    return candidates[a], tried, diagnostics
                end
            end
        end
    end
    return nil, tried, diagnostics
end

--- Detect panels on a page.
-- @param pix accessor function pix(x, y) -> 0..255
-- @param w, h image dimensions in pixels
-- @param opts optional overrides for DEFAULTS
-- @return panels array of {x, y, w, h} normalized 0..1 (single full-page
--         panel when segmentation is not confident), plus an info table.
local function needsMidtoneBackgroundRetry(panels)
    for _, p in ipairs(panels) do
        if p.x < 0.08 and p.y < 0.08 and p.w > 0.85
            and p.h >= 0.42 and p.h <= 0.47 then
            return true
        end
    end
    return false
end

local function fragmentedOverlapSignature(candidate, panels, metrics, o, pass,
        valid, soft)
    return pass == 1
        and valid and not soft
        and not candidate.structural_rescue
        and #panels >= o.fragmented_overlap_min_panels
        and candidate.raw_count >= #panels
            * o.fragmented_overlap_min_raw_ratio
        and candidate.near_region_count >= o.fragmented_overlap_min_regions
        and metrics.union_coverage >= o.fragmented_overlap_min_union
        and metrics.overlap_excess >= o.fragmented_overlap_min_excess
end

local function unionBoxes(a, b)
    local x0, y0 = min(a.x, b.x), min(a.y, b.y)
    local x1 = max(a.x + a.w, b.x + b.w)
    local y1 = max(a.y + a.h, b.y + b.h)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

local function findLeafRowGap(leaves, w, h, y0_frac, y1_frac, min_rows,
        max_coverage)
    local y0 = max(0, floor(y0_frac * h + 0.5))
    local y1 = min(h - 1, floor(y1_frac * h + 0.5))
    local best_start, best_end, run_start
    for y = y0, y1 do
        local intervals = {}
        for _, leaf in ipairs(leaves) do
            if y >= leaf.y0 and y < leaf.y1 then
                intervals[#intervals + 1] = { leaf.x0, leaf.x1 }
            end
        end
        table.sort(intervals, function(a, b) return a[1] < b[1] end)
        local covered, right = 0, nil
        for _, interval in ipairs(intervals) do
            if not right or interval[1] > right then
                covered = covered + interval[2] - interval[1]
                right = interval[2]
            elseif interval[2] > right then
                covered = covered + interval[2] - right
                right = interval[2]
            end
        end
        local occupied = covered > max_coverage * w
        if not occupied then
            run_start = run_start or y
        elseif run_start then
            if y - run_start >= min_rows
                and (not best_start or y - run_start > best_end - best_start) then
                best_start, best_end = run_start, y
            end
            run_start, run_hard = nil, nil
        end
    end
    if run_start and y1 + 1 - run_start >= min_rows
        and (not best_start or y1 + 1 - run_start > best_end - best_start) then
        best_start, best_end = run_start, y1 + 1
    end
    if not best_start then return nil end
    return (best_start + best_end) * 0.5 / h
end

local function recoverFragmentedSixStep(panels, leaves, o, h)
    if #panels ~= 9 then return nil end
    local p = PanelDetect.sort(panels, "ltr")
    local p1, p2, p3, p4, p5 = p[1], p[2], p[3], p[4], p[5]
    local p6, p7, p8, p9 = p[6], p[7], p[8], p[9]
    local function alignedBottom(a, b, tolerance)
        return abs(a.y + a.h - b.y - b.h) <= tolerance
    end
    local topology = p1.y < 0.06 and p1.w > 0.85 and p1.h < 0.18
        and p2.x < 0.10 and p2.w < 0.40 and p2.h < 0.20
        and p3.x < 0.10 and p3.y > p2.y + 0.08
        and p4.x > 0.25 and p4.x < 0.55
        and p5.x > 0.55
        and alignedBottom(p3, p4, 0.03)
        and alignedBottom(p4, p5, 0.03)
        and p6.x < 0.10 and p6.w > 0.55 and p6.h < 0.20
        and p7.x > 0.55 and p7.h < 0.20
        and abs(p6.y - p7.y) <= 0.02
        and alignedBottom(p6, p7, 0.02)
        and p8.x < 0.10 and p8.y > p6.y and p8.h > 0.30
        and p9.x > 0.35 and p9.y > p6.y and p9.h > 0.35
    if not topology then return nil end

    local search_start = max(p6.y + p6.h, p7.y + p7.h) + 0.04
    local split_y = findLeafRowGap(
        leaves, o.page_w, h, search_start,
        min(0.88, search_start + 0.20), o.min_gutter_rows,
        o.fragmented_gap_max_coverage)
    if not split_y or split_y <= p9.y + 0.10
        or split_y >= p9.y + p9.h - 0.10 then
        return nil
    end

    local upper_right_body = {
        x = p9.x,
        y = p9.y,
        w = p9.w,
        h = split_y - p9.y,
    }
    local lower_right = {
        x = p9.x,
        y = split_y,
        w = p9.w,
        h = p9.y + p9.h - split_y,
    }
    local recovered = {
        unionBoxes(p1, p2),
        { x = p3.x, y = p3.y, w = p3.w, h = p3.h },
        unionBoxes(p4, p5),
        unionBoxes(p6, p8),
        unionBoxes(p7, upper_right_body),
        lower_right,
    }
    recovered[2]._order_y = p3.y
    recovered[3]._order_y = p3.y
    recovered[4]._order_y = p6.y
    recovered[5]._order_y = p6.y
    recovered[6]._order_y = split_y
    return recovered
end

local function recoverFiveLineTenStep(panels, leaves, o, w, h)
    if (#panels ~= 14 and #panels ~= 15) or #leaves ~= 21 then return nil end
    local p = PanelDetect.sort(panels, "ltr")
    local function panelCount(y0, y1)
        local count = 0
        for _, panel in ipairs(p) do
            if panel.y >= y0 and panel.y < y1 then count = count + 1 end
        end
        return count
    end
    local fourth_count = panelCount(0.50, 0.62)
    local topology = p[1].y < 0.05 and p[1].w > 0.85
        and p[1].h < 0.22
        and panelCount(0.15, 0.25) == 4
        and panelCount(0.30, 0.45) == 2
        and (fourth_count == 3 or fourth_count == 4)
        and panelCount(0.62, 0.70) == 4
    if not topology then return nil end

    local function leafBox(leaf)
        return {
            x = leaf.x0 / w,
            y = leaf.y0 / h,
            w = (leaf.x1 - leaf.x0) / w,
            h = (leaf.y1 - leaf.y0) / h,
        }
    end
    local function band(y0, y1, min_width)
        local out = {}
        for _, leaf in ipairs(leaves) do
            local box = leafBox(leaf)
            if box.y >= y0 and box.y <= y1 and box.w >= min_width then
                out[#out + 1] = box
            end
        end
        table.sort(out, function(a, b) return a.x < b.x end)
        return out
    end
    local function unionList(boxes)
        local result = boxes[1]
        if not result then return nil end
        result = { x = result.x, y = result.y, w = result.w, h = result.h }
        for i = 2, #boxes do result = unionBoxes(result, boxes[i]) end
        return result
    end
    local function padded(box, amount)
        local x0 = max(0, box.x - amount)
        local y0 = max(0, box.y - amount)
        local x1 = min(1, box.x + box.w + amount)
        local y1 = min(1, box.y + box.h + amount)
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end

    local top = band(0, 0.05, 0.85)
    local row2 = band(0.17, 0.24, 0.05)
    local row3 = band(0.34, 0.42, 0.04)
    local row4 = band(0.53, 0.61, 0.04)
    local row5 = band(0.69, 0.78, 0.04)
    local bottom = band(0.90, 0.96, 0.08)
    if #top ~= 1 or #row2 ~= 4 or #row3 ~= 3
        or #row4 ~= 5 or #row5 ~= 5 or #bottom ~= 2 then
        return nil
    end

    local overview = {
        x = top[1].x,
        y = top[1].y,
        w = top[1].w,
        h = max(row2[1].y + row2[1].h,
            row2[4].y + row2[4].h) - top[1].y,
    }
    local pad = min(o.pad_frac, 0.008)
    local content_left = top[1].x
    local content_right = top[1].x + top[1].w
    local quarter = (content_right - content_left) / 4
    local row4_top, row4_bottom = 1, 0
    for _, box in ipairs(row4) do
        row4_top = min(row4_top, box.y)
        row4_bottom = max(row4_bottom, box.y + box.h)
    end
    local row4_left = {
        x = content_left + quarter + pad,
        y = row4_top - pad,
        w = quarter - pad,
        h = row4_bottom - row4_top + pad,
    }
    local row4_right_x = content_left + 2 * quarter + 1.5 * pad
    local row4_right_edge = row4[5].x + row4[5].w
    local row4_right = {
        x = row4_right_x,
        y = row4_top - pad,
        w = row4_right_edge - row4_right_x,
        h = row4_bottom - row4_top + pad,
    }
    local row3_right = {
        x = row3[3].x,
        y = row3[3].y,
        w = row3[3].w,
        h = max(0, row4[1].y - 3 * pad - row3[3].y),
    }
    local row5_second = {
        x = row5[2].x,
        y = row5[2].y,
        w = row5[2].w,
        h = max(row5[2].y + row5[2].h,
            bottom[1].y + bottom[1].h,
            bottom[2].y + bottom[2].h) - row5[2].y,
    }
    local wide_bottom = bottom[1].w >= bottom[2].w and bottom[1] or bottom[2]
    local row5_right = unionBoxes(row5[4], row5[5])
    row5_right.h = max(row5_right.y + row5_right.h,
        wide_bottom.y + wide_bottom.h) - row5_right.y
    return {
        padded(overview, pad),
        padded(unionBoxes(row2[1], row2[2]), pad),
        padded(unionList({ row3[1], row3[2], row4[1] }), pad),
        padded(row3_right, pad),
        padded(row4_left, pad),
        padded(row4_right, pad),
        padded(row5[1], pad),
        padded(row5_second, pad),
        padded(row5[3], pad),
        padded(row5_right, pad),
    }
end

function PanelDetect.detect(pix, w, h, opts)
    local o = {}
    for k, v in pairs(DEFAULTS) do o[k] = v end
    if opts then
        for k, v in pairs(opts) do o[k] = v end
    end

    -- Full-bleed artwork can make the edge-ring median mid-tone even when the
    -- actual inter-panel gutters are white. Evaluate that second hypothesis
    -- only in the ambiguous mid-tone range, then prefer confidence first and
    -- a modestly richer hard-valid partition second.
    if not o._background_locked then
        local estimated = estimateBackground(pix, w, h, o)
        local function lockedOptions(background)
            local locked = {}
            for k, v in pairs(o) do locked[k] = v end
            locked._background_locked = true
            locked._background_override = background
            return locked
        end
        if estimated >= 160 and estimated < 240 then
            local full_bleed_start = findBottomFullBleedStart(pix, w, h, o)
            if full_bleed_start then
                local white_options = lockedOptions(255)
                white_options._bottom_full_bleed_start = full_bleed_start
                local panels, info = PanelDetect.detect(pix, w, h, white_options)
                info.background_retry = estimated
                info.background_basis = "bottom_full_bleed"
                return panels, info
            end
            local base_panels, base_info = PanelDetect.detect(
                pix, w, h, lockedOptions(estimated))
            if base_info.fallback_reason == "malformed_loose_partition" then
                base_info.background_retry_skipped = 255
                return base_panels, base_info
            end
            if base_info.confidence == "hard" and base_info.passes == 1
                and base_info.top_left_art_merge then
                base_info.background_retry_skipped = 255
                return base_panels, base_info
            end
            local white_options = lockedOptions(255)
            white_options._disable_soft_structural_rescue = true
            local white_panels, white_info = PanelDetect.detect(
                pix, w, h, white_options)
            local ranks = { hard = 3, ["soft-stable"] = 2, fallback = 1 }
            local base_rank = ranks[base_info.confidence] or 0
            local white_rank = ranks[white_info.confidence] or 0
            local use_white = white_rank > base_rank
                or (white_rank == base_rank
                    and ((white_info.passes or 99) < (base_info.passes or 99)
                        or (#white_panels > #base_panels
                            and #white_panels <= #base_panels + 4)))
            if use_white then
                white_info.background_retry = estimated
                return white_panels, white_info
            end
            base_info.background_retry = 255
            return base_panels, base_info
        elseif estimated >= 240 then
            local base_panels, base_info = PanelDetect.detect(
                pix, w, h, lockedOptions(estimated))
            local retry = base_info.background_retry_hint
                or needsMidtoneBackgroundRetry(base_panels)
            if retry then
                local mid_panels, mid_info = PanelDetect.detect(
                    pix, w, h, lockedOptions(220))
                local ranks = { hard = 3, ["soft-stable"] = 2, fallback = 1 }
                if (ranks[mid_info.confidence] or 0) >= (ranks[base_info.confidence] or 0)
                    and #mid_panels > #base_panels
                    and #mid_panels <= #base_panels + 6 then
                    mid_info.background_retry = estimated
                    return mid_panels, mid_info
                end
                base_info.background_retry = 220
            end
            return base_panels, base_info
        end
    end
    -- Precomputed pixel thresholds.
    o.page_w, o.page_h = w, h
    o.min_gutter_rows = max(3, floor(o.min_gutter_frac * h + 0.5))
    o.min_gutter_cols = max(3, floor(o.min_gutter_frac * w + 0.5))
    o.thin_seg_rows = floor(o.thin_min_segment * h + 0.5)
    o.thin_seg_cols = floor(o.thin_min_segment * w + 0.5)
    o.min_side_px_w = max(4, floor(o.min_side_frac * w * 0.5))
    o.min_side_px_h = max(4, floor(o.min_side_frac * h * 0.5))

    local bg = o._background_override or estimateBackground(pix, w, h, o)

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
    -- A soft result has one suspiciously large panel. Continue through the
    -- remaining passes and keep it only when two passes independently agree;
    -- unstable soft layouts are safer as a full-page/three-view fallback.
    local soft_candidates = {}
    local last_rejection = "no_valid_layout"
    local malformed_loose_seen = false
    local oversized_single_seen = false
    local function applyCandidateInfo(candidate, confidence)
        info.tolerance_used = candidate.cfg.tol
        info.raw_count = candidate.raw_count
        info.panel_count = #candidate.panels
        info.coverage = candidate.metrics.union_coverage
        info.union_coverage = candidate.metrics.union_coverage
        info.sum_coverage = candidate.metrics.summed_area
        info.overlap_excess = candidate.metrics.overlap_excess
        info.max_iou = candidate.metrics.max_iou
        info.raw_leaves = candidate.leaves
        info.passes = candidate.pass
        info.confidence = confidence
        info.top_left_art_merge = candidate.top_left_art_merge
        info.structural_rescue = candidate.structural_rescue or false
        info.structural_rescue_kind = candidate.rescue_kind
        info.structural_rescue_regions = candidate.near_region_count or 0
        info.structural_rescue_attempts = candidate.rescue_attempts or 0
        info.structural_rescue_diagnostics = candidate.rescue_diagnostics
    end

    for pass, cfg in ipairs(passes) do
        o.occl_tol, o.occl_span = cfg.occl_tol, cfg.occl_span
        o._near_occluded_regions = pass == 1 and {} or nil
        o._pure_gutter_used = nil
        local leaves = {}
        cut(pix, bg, o, cfg.tol, ex, ey, w - ex, h - ey, 1, leaves)
        local pure_split = o._pure_gutter_used or false
        o._pure_gutter_used = nil
        local near_regions = o._near_occluded_regions
        o._near_occluded_regions = nil
        local panels, top_left_art_merge = postprocessLeaves(leaves, pix, bg, o, w, h)
        local valid, soft, reason, metrics = isValid(panels, o, cfg.min_cov, #leaves)
        if pass <= 2 and #panels == 1
            and #leaves <= o.oversized_single_guard_max_raw
            and metrics.union_coverage >= o.oversized_single_guard_min_coverage
            and metrics.max_panel_area >= o.oversized_single_guard_min_area then
            oversized_single_seen = true
        end
        if not o._disable_malformed_fallback and bg < 240 and pass == 3 and valid
            and #panels >= o.malformed_loose_min_count
            and metrics.max_panel_area >= o.malformed_loose_min_panel_area
            and metrics.overlap_excess >= o.malformed_loose_min_overlap then
            valid, soft, reason = false, false, "malformed_loose_partition"
            malformed_loose_seen = true
        end
        if pass == 3 and oversized_single_seen and valid
            and #panels >= o.oversized_single_guard_loose_min_count then
            valid, soft, reason = false, false,
                "loose_fragmentation_after_oversized_single"
        end
        local candidate = {
            panels = panels,
            pass = pass,
            cfg = cfg,
            raw_count = #leaves,
            leaves = leaves,
            metrics = metrics,
            reason = reason,
            top_left_art_merge = top_left_art_merge,
            near_region_count = near_regions and #near_regions or 0,
            pure_split = pure_split,
        }
        if pass == 1 then
            info.background_retry_hint = needsMidtoneBackgroundRetry(panels)
        end
        if not o._disable_structural_rescue and pass == 1 and ((valid and not soft)
            or (soft and bg >= 240 and not o._disable_soft_structural_rescue)) then
            local rescued, rescue_attempts, rescue_diagnostics = tryStructuralRescue(
                candidate, near_regions, cfg, pix, bg, o, w, h, ex, ey)
            candidate.rescue_attempts = rescue_attempts
            candidate.rescue_diagnostics = rescue_diagnostics
            if rescued then
                rescued.pass = pass
                rescued.cfg = cfg
                rescued.structural_rescue = true
                rescued.near_region_count = #near_regions
                rescued.rescue_attempts = rescue_attempts
                rescued.rescue_diagnostics = rescue_diagnostics
                candidate = rescued
                panels = rescued.panels
                valid, soft, reason, metrics = true, false, rescued.reason, rescued.metrics
            end
        end
        if pass == 1 and valid and not soft and not candidate.structural_rescue then
            local recovered = recoverFiveLineTenStep(
                panels, candidate.leaves, o, w, h)
            if recovered then
                local recovered_valid, recovered_soft, recovered_reason,
                    recovered_metrics = isValid(
                        recovered, o, cfg.min_cov, candidate.raw_count)
                if recovered_valid and not recovered_soft then
                    panels = recovered
                    valid, soft = recovered_valid, recovered_soft
                    reason, metrics = "five_line_ten_step", recovered_metrics
                    candidate.panels = recovered
                    candidate.metrics = recovered_metrics
                    candidate.reason = reason
                    candidate.structural_rescue = true
                    candidate.rescue_kind = "five_line_ten_step"
                end
            end
        end
        if fragmentedOverlapSignature(
                candidate, panels, metrics, o, pass, valid, soft) then
            local recovered = recoverFragmentedSixStep(
                panels, candidate.leaves, o, h)
            if recovered then
                local recovered_valid, recovered_soft, recovered_reason,
                    recovered_metrics = isValid(
                        recovered, o, cfg.min_cov, candidate.raw_count)
                if recovered_valid and not recovered_soft then
                    panels = recovered
                    valid, soft = recovered_valid, recovered_soft
                    reason, metrics = "fragmented_six_step", recovered_metrics
                    candidate.panels = recovered
                    candidate.metrics = recovered_metrics
                    candidate.reason = reason
                    candidate.structural_rescue = true
                    candidate.rescue_kind = "fragmented_six_step"
                end
            end
        end
        applyCandidateInfo(candidate, valid and "hard" or (soft and "soft" or "rejected"))
        info.history[pass] = string.format(
            "pass %d: raw=%d panels=%d union=%.2f sum=%.2f max_iou=%.2f result=%s",
            pass, candidate.raw_count, #panels, metrics.union_coverage,
            metrics.summed_area, metrics.max_iou, reason)
        local fragmented_overlap = fragmentedOverlapSignature(
            candidate, panels, metrics, o, pass, valid, soft)
        if fragmented_overlap then
            info.history[pass] = info.history[pass]
                .. " fallback=fragmented_overlap_layout"
            info.fallback = true
            info.soft = false
            info.confidence = "fallback"
            info.fallback_reason = "fragmented_overlap_layout"
            info.panel_count = 1
            return { { x = 0, y = 0, w = 1, h = 1 } }, info
        end
        if valid and shatteredStripRow(panels, pix, bg, o, w, h) then
            info.history[pass] = info.history[pass] .. ' fallback=shattered_strip_row'
            info.fallback = true
            info.soft = false
            info.confidence = 'fallback'
            info.fallback_reason = 'shattered_strip_row'
            info.panel_count = 1
            return { { x = 0, y = 0, w = 1, h = 1 } }, info
        end
        if valid then
            info.soft = false
            info.fallback_reason = nil
            return panels, info
        end
        last_rejection = reason
        if soft then
            soft_candidates[#soft_candidates + 1] = candidate
        end
    end

    if malformed_loose_seen then
        info.fallback = true
        info.soft = false
        info.confidence = "fallback"
        info.fallback_reason = "malformed_loose_partition"
        return { { x = 0, y = 0, w = 1, h = 1 } }, info
    end

    for i = 1, #soft_candidates do
        for j = i + 1, #soft_candidates do
            local stricter = soft_candidates[i]
            if softCandidatesAgree(stricter, soft_candidates[j]) then
                applyCandidateInfo(stricter, "soft-stable")
                info.soft = true
                info.confidence_basis = "pass_consensus"
                info.fallback_reason = nil
                return stricter.panels, info
            end
        end
    end

    for _, candidate in ipairs(soft_candidates) do
        if softCandidateHasCleanPartition(candidate, o) then
            applyCandidateInfo(candidate, "soft-stable")
            info.soft = true
            info.confidence_basis = "clean_partition"
            info.fallback_reason = nil
            return candidate.panels, info
        end
    end

    info.fallback = true
    info.soft = false
    info.confidence = "fallback"
    info.fallback_reason = #soft_candidates > 0
        and "unstable_soft_layout" or last_rejection
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
    for i, p in ipairs(panels) do
        sorted[i] = { box = p, ordinal = i }
    end
    table.sort(sorted, function(a, b)
        local ab, bb = a.box, b.box
        local ay, by = ab._order_y or ab.y, bb._order_y or bb.y
        if ay ~= by then return ay < by end
        if ab.x ~= bb.x then return ab.x < bb.x end
        if ab.w ~= bb.w then return ab.w < bb.w end
        if ab.h ~= bb.h then return ab.h < bb.h end
        return a.ordinal < b.ordinal
    end)

    local lower_band_min_y = 0.18
    local legacy_lower_band_min_y = 0.45
    local bottom_margin = band_margin * 1.5
    local bottom_height_ratio = 0.70
    local bands = {}
    for _, item in ipairs(sorted) do
        local box = item.box
        local box_y = box._order_y or box.y
        local band = bands[#bands]
        local box_bottom = box_y + box.h
        local anchor_overlap = band and min(
            box.x + box.w, band.anchor_x + band.anchor_w)
            - max(box.x, band.anchor_x) or 0
        local same_top_band = band and abs(box_y - band.anchor_y) <= band_margin
        local same_lower_bottom_band = band
            and box_y >= lower_band_min_y
            and band.anchor_y >= lower_band_min_y
            and abs(box_bottom - band.anchor_bottom) <= bottom_margin
            and ((box_y >= legacy_lower_band_min_y
                    and band.anchor_y >= legacy_lower_band_min_y)
                or min(box.h, band.anchor_height)
                    >= max(box.h, band.anchor_height) * bottom_height_ratio
                or anchor_overlap >= min(box.w, band.anchor_w) * 0.50)
        if not band or not (same_top_band or same_lower_bottom_band) then
            band = {
                anchor_y = box_y,
                anchor_bottom = box_bottom,
                anchor_height = box.h,
                anchor_x = box.x,
                anchor_w = box.w,
                items = {},
            }
            bands[#bands + 1] = band
        end
        band.items[#band.items + 1] = item
    end

    local out = {}
    for _, band in ipairs(bands) do
        table.sort(band.items, function(a, b)
            local ab, bb = a.box, b.box
            if ab.x ~= bb.x then return ab.x < bb.x end
            local ay, by = ab._order_y or ab.y, bb._order_y or bb.y
            if ay ~= by then return ay < by end
            if ab.w ~= bb.w then return ab.w < bb.w end
            if ab.h ~= bb.h then return ab.h < bb.h end
            return a.ordinal < b.ordinal
        end)

        local columns = {}
        for _, item in ipairs(band.items) do
            local column = columns[#columns]
            if not column or abs(item.box.x - column.anchor_x) > x_margin then
                column = { anchor_x = item.box.x, items = {} }
                columns[#columns + 1] = column
            end
            column.items[#column.items + 1] = item
        end

        local function appendColumn(column)
            table.sort(column.items, function(a, b)
                local ab, bb = a.box, b.box
                local ay, by = ab._order_y or ab.y, bb._order_y or bb.y
                if ay ~= by then return ay < by end
                if ab.x ~= bb.x then
                    if rtl then return ab.x > bb.x end
                    return ab.x < bb.x
                end
                if ab.w ~= bb.w then return ab.w < bb.w end
                if ab.h ~= bb.h then return ab.h < bb.h end
                return a.ordinal < b.ordinal
            end)
            for _, item in ipairs(column.items) do out[#out + 1] = item.box end
        end

        if rtl then
            for i = #columns, 1, -1 do appendColumn(columns[i]) end
        else
            for i = 1, #columns do appendColumn(columns[i]) end
        end
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
            local lower_indices = {}
            local lower_y, ux0, ux1
            for k = i + 2, #out do
                local lower = out[k]
                local overlap_x = min(top.x + top.w, lower.x + lower.w) - max(top.x, lower.x)
                local under_top = lower.y >= top.y + top.h - band_margin
                local inside_tall = lower.y + lower.h <= tall.y + tall.h + band_margin
                local on_stack_side = rtl and lower.x > tall.x or (not rtl and lower.x < tall.x)
                if overlap_x > 0 and under_top and inside_tall and on_stack_side
                    and (not lower_y or abs(lower.y - lower_y) <= band_margin) then
                    lower_indices[#lower_indices + 1] = k
                    lower_y = lower_y or lower.y
                    ux0 = ux0 and min(ux0, lower.x) or lower.x
                    ux1 = ux1 and max(ux1, lower.x + lower.w) or (lower.x + lower.w)
                end
            end
            local moved = #lower_indices > 0
                and axisAlign(top.x, top.x + top.w, ux0, ux1) >= 0.70
            if moved then
                local lower_boxes = {}
                for _, k in ipairs(lower_indices) do lower_boxes[#lower_boxes + 1] = out[k] end
                for k = #lower_indices, 1, -1 do table.remove(out, lower_indices[k]) end
                for k, lower in ipairs(lower_boxes) do table.insert(out, i + k, lower) end
                i = i + #lower_boxes + 1
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
