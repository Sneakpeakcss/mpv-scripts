local opts = {
    mode = "hard", -- can be "hard" or "soft". If hard, use video-crop, if soft use zoom + pan. Or a bonus "delogo" mode
    draw_shade = true,
    shade_opacity = "44",
    light_opacity = "CC",
    draw_frame = false,
    frame_border_width = 1,
    frame_border_color = "FF0000",
    draw_crosshair = true,
    draw_text = true,
    mouse_support = true,
    coarse_movement = 30,
    left_coarse = "LEFT",
    right_coarse = "RIGHT",
    up_coarse = "UP",
    down_coarse = "DOWN",
    fine_movement = 1,
    left_fine = "ALT+LEFT",
    right_fine = "ALT+RIGHT",
    up_fine = "ALT+UP",
    down_fine = "ALT+DOWN",
    accept = "ENTER,MOUSE_BTN0",
    cancel = "ESC",
}
(require 'mp.options').read_options(opts)

-- Convert RRGGBB to BBGGRR for user convenience
local frame_border_color = opts.frame_border_color:gsub("(%x%x)(%x%x)(%x%x)","%3%2%1")

function split(input)
    local ret = {}
    for str in string.gmatch(input, "([^,]+)") do
        ret[#ret + 1] = str
    end
    return ret
end
local msg = require 'mp.msg'

opts.accept = split(opts.accept)
opts.cancel = split(opts.cancel)
function mode_ok(mode)
    return mode == "soft" or mode == "hard" or mode == "delogo"
end
if not mode_ok(opts.mode) then
    msg.error("Invalid mode value: " .. opts.mode)
    return
end

local assdraw = require 'mp.assdraw'
local active = false
local active_mode = "" -- same possible values as opts.mode
local rect_centered = false
local rect_keepaspect = false
local needs_drawing = false
local crop_first_corner = nil -- in normalized video space
local cursor = {
    x = 0,
    y = 0
}

function redraw()
    needs_drawing = true
end

function rect_from_two_points(p1, p2, centered, ratio)
    local c1 = {p1.x, p1.y}
    local c2 = {p2.x, p2.y}
    if ratio then
        -- adjust position of p2, such
        if math.abs(c2[1] - c1[1]) < ratio * math.abs(c2[2] - c1[2]) then
            local is_left = c2[1] < c1[1] and -1 or 1
            c2[1] = c1[1] + is_left * math.abs(c2[2] - c1[2]) * ratio
        else
            local is_up = c2[2] < c1[2] and -1 or 1
            c2[2] = c1[2] + is_up * math.abs(c2[1] - c1[1]) / ratio
        end
    end
    if centered then
        -- p1 is center => convert it into corner
        c1[1] = c1[1] - (c2[1] - c1[1])
        c1[2] = c1[2] - (c2[2] - c1[2])
    end
    -- sort corners
    if c1[1] > c2[1] then c1[1], c2[1] = c2[1], c1[1] end
    if c1[2] > c2[2] then c1[2], c2[2] = c2[2], c1[2] end
    return { x = c1[1], y = c1[2] }, { x = c2[1], y = c2[2] }
end

function round(num, num_decimal_places)
    local mult = 10^(num_decimal_places or 0)
    return math.floor(num * mult + 0.5) / mult
end

function clamp(low, value, high)
    if value <= low then
        return low
    elseif value >= high then
        return high
    else
        return value
    end
end

function clamp_point(point, dim)
    return {
        x = clamp(dim.ml, point.x, dim.w - dim.mr),
        y = clamp(dim.mt, point.y, dim.h - dim.mb)
    }
end

function screen_to_video_norm(point, dim)
    return {
        x = (point.x - dim.ml) / (dim.w - dim.ml - dim.mr),
        y = (point.y - dim.mt) / (dim.h - dim.mt - dim.mb)
    }
end

function video_norm_to_screen(point, dim)
    return {
        x = math.floor(point.x * (dim.w - dim.ml - dim.mr) + dim.ml + 0.5),
        y = math.floor(point.y * (dim.h - dim.mt - dim.mb) + dim.mt + 0.5)
    }
end

function draw_shade(ass, unshaded, window, color, opacity)
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7}")
    ass:append("{\\bord0}")
    ass:append("{\\shad0}")
    ass:append("{\\c&H" .. color .. "&}")
    ass:append("{\\1a&H" .. opacity .. "}")
    ass:append("{\\2a&HFF}")
    ass:append("{\\3a&HFF}")
    ass:append("{\\4a&HFF}")
    local c1, c2 = unshaded.top_left, unshaded.bottom_right
    local v = window
    --          c1.x   c2.x
    --     +-----+------------+
    --     |     |     ur     |
    -- c1.y| ul  +-------+----+
    --     |     |       |    |
    -- c2.y+-----+-------+ lr |
    --     |     ll      |    |
    --     +-------------+----+
    ass:draw_start()
    ass:rect_cw(v.top_left.x, v.top_left.y, c1.x, c2.y) -- ul
    ass:rect_cw(c1.x, v.top_left.y, v.bottom_right.x, c1.y) -- ur
    ass:rect_cw(v.top_left.x, c2.y, c2.x, v.bottom_right.y) -- ll
    ass:rect_cw(c2.x, c1.y, v.bottom_right.x, v.bottom_right.y) -- lr
    ass:draw_stop()
    -- also possible to draw a rect over the whole video
    -- and \iclip it in the middle, but seemingy slower
end

function draw_frame(ass, frame)
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7}")
    ass:append("{\\bord0}")
    ass:append("{\\shad0}")
    ass:append("{\\c&H" .. frame_border_color .. "&}")
    ass:append("{\\1a&H00&}")
    ass:append("{\\2a&HFF&}")
    ass:append("{\\3a&HFF&}")
    ass:append("{\\4a&HFF&}")
    local c1, c2 = frame.top_left, frame.bottom_right
    local b = opts.frame_border_width
    ass:draw_start()
    ass:rect_cw(c1.x, c1.y - b, c2.x + b, c1.y)
    ass:rect_cw(c2.x, c1.y, c2.x + b, c2.y + b)
    ass:rect_cw(c1.x - b, c2.y, c2.x, c2.y + b)
    ass:rect_cw(c1.x - b, c1.y - b, c1.x, c2.y)
    local xm = (c1.x + c2.x) / 2
    local ym = (c1.y + c2.y) / 2
    local bh = b / 2
    ass:rect_cw(c1.x, ym - b, c2.x + b, ym + bh)
    ass:rect_cw(xm - bh, c1.y, xm + bh, c2.y)
    ass:draw_stop()
end

function draw_crosshair(ass, center, window_size)
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7}")
    ass:append("{\\bord0}")
    ass:append("{\\shad0}")
    ass:append("{\\c&HBBBBBB&}")
    ass:append("{\\1a&H00&}")
    ass:append("{\\2a&HFF&}")
    ass:append("{\\3a&HFF&}")
    ass:append("{\\4a&HFF&}")
    ass:draw_start()
    ass:rect_cw(center.x - 0.5, 0, center.x + 0.5, window_size.h)
    ass:rect_cw(0, center.y - 0.5, window_size.w, center.y + 0.5)
    ass:draw_stop()
end

function draw_position_text(ass, text, position, window_size, offset)
    ass:new_event()
    local align = 1
    local ofx = 1
    local ofy = -1
    if position.x > window_size.w / 2 then
        align = align + 2
        ofx = -1
    end
    if position.y < window_size.h / 2 then
        align = align + 6
        ofy = 1
    end
    ass:append("{\\an"..align.."}")
    ass:append("{\\fs26}")
    ass:append("{\\bord1.5}")
    ass:pos(ofx*offset + position.x, ofy*offset + position.y)
    ass:append(text)
end

function draw_crop_zone()
    if needs_drawing then
        local dim = mp.get_property_native("osd-dimensions")
        if not dim then
            cancel_crop()
            return
        end

        cursor = clamp_point(cursor, dim)
        local ass = assdraw.ass_new()

        if crop_first_corner and (opts.draw_shade or opts.draw_frame) then
            local frame = {}
            frame.top_left, frame.bottom_right = rect_from_two_points(
                video_norm_to_screen(crop_first_corner, dim),
                cursor,
                rect_centered,
                rect_keepaspect and dim.w/dim.h)
            -- don't draw shade over non-visible video parts
            if opts.draw_shade then
                local window = {
                    top_left = { x = 0, y = 0 },
                    bottom_right = { x = dim.w, y = dim.h },
                }
                if opts.light_opacity:lower() ~= "ff" then draw_shade(ass, frame, window, "FFFFFF", opts.light_opacity) end
                if opts.shade_opacity:lower() ~= "ff" then draw_shade(ass, frame, window, "000000", opts.shade_opacity) end
            end
            if opts.draw_frame then
                draw_frame(ass, frame)
            end
        end


        if opts.draw_crosshair then
            draw_crosshair(ass, cursor, { w = dim.w, h = dim.h })
        end

        if opts.draw_text then
            local vop = mp.get_property_native("video-out-params")
            if vop then
                local cursor_norm = screen_to_video_norm(cursor, dim)
                local text = string.format("%d, %d", cursor_norm.x * vop.w, cursor_norm.y * vop.h)
                if crop_first_corner then
                    local crop_zone_w = math.abs((cursor_norm.x - crop_first_corner.x) * vop.w )
                    local crop_zone_h = math.abs((cursor_norm.y - crop_first_corner.y) * vop.h )
                    local crop_zone_aspect = round(crop_zone_w / crop_zone_h, 3)
                    text = string.format("%s (%dx%d/%s)", text,
                        crop_zone_w,
                        crop_zone_h,
                        crop_zone_aspect
                    )
                end
                draw_position_text(ass, text, cursor, { w = dim.w, h = dim.h }, 6)
            end
        end

        mp.set_osd_ass(dim.w, dim.h, ass.text)
        needs_drawing = false
    end
end

-- history tables
local recursive_crop = {}
local recursive_zoom_pan = {}
local remove_last_filter = {}

function crop_video(x1, y1, x2, y2)
    if active_mode == "soft" then
        local w = x2 - x1
        local h = y2 - y1
        local dim = mp.get_property_native("osd-dimensions")
        if not dim then return end

        local zoom = mp.get_property_number("video-zoom")
        local newZoom1 = math.log(dim.h * (2 ^ zoom) / (dim.h - dim.mt - dim.mb) / h) / math.log(2)
        local newZoom2 = math.log(dim.w * (2 ^ zoom) / (dim.w - dim.ml - dim.mr) / w) / math.log(2)

        local newZoom = math.min(newZoom1, newZoom2)
        local newPanX = 0.5 - (x1 + w / 2)
        local newPanY = 0.5 - (y1 + h / 2)
        
        table.insert(recursive_zoom_pan, {zoom = newZoom, panX = newPanX, panY = newPanY})
        mp.set_property("video-zoom", newZoom)
        mp.set_property("video-pan-x", newPanX)
        mp.set_property("video-pan-y", newPanY)
        table.insert(remove_last_filter, "soft")

    elseif active_mode == "hard" or active_mode == "delogo" then
        x1 = clamp(0, x1, 1)
        y1 = clamp(0, y1, 1)
        x2 = clamp(0, x2, 1)
        y2 = clamp(0, y2, 1)
        local vop = mp.get_property_native("video-out-params")
        if active_mode == "hard" then
            local w = x2 - x1
            local h = y2 - y1
    
            table.insert(recursive_crop, {x = x1, y = y1, w = w, h = h})
            apply_video_crop()
            table.insert(remove_last_filter, "hard")

        elseif active_mode == "delogo" then
            local vf_table = mp.get_property_native("vf")

            local x, y, w, h = adjust_coordinates()

            local x = math.floor((x + x1 * w) * vop.w + 0.5)
            local y = math.floor((y + y1 * h) * vop.h + 0.5)
            local w = math.floor(w * (x2 - x1) * vop.w + 0.5)
            local h = math.floor(h * (y2 - y1) * vop.h + 0.5)
    
            -- delogo is a little special and needs some padding to function
            w = math.min(vop.w - 1, w)
            h = math.min(vop.h - 1, h)
            x = math.max(1, x)
            y = math.max(1, y)
    
            if x + w == vop.w then w = w - 1 end
            if y + h == vop.h then h = h - 1 end
    
            vf_table[#vf_table + 1] = {
                name="delogo",
                params= { x = tostring(x), y = tostring(y), w = tostring(w), h = tostring(h) }
            }
    
            mp.set_property_native("vf", vf_table)
            table.insert(remove_last_filter, "delogo")
        end
    end
end

function update_crop_zone_state()
    local dim = mp.get_property_native("osd-dimensions")
    if not dim then
        cancel_crop()
        return
    end
    cursor = clamp_point(cursor, dim)
    if crop_first_corner == nil then
        crop_first_corner = screen_to_video_norm(cursor, dim)
        redraw()
    else
        local c1, c2 = rect_from_two_points(
            video_norm_to_screen(crop_first_corner, dim),
            cursor,
            rect_centered,
            rect_keepaspect and dim.w/dim.h)
        local c1norm = screen_to_video_norm(c1, dim)
        local c2norm = screen_to_video_norm(c2, dim)
        crop_video(c1norm.x, c1norm.y, c2norm.x, c2norm.y)
        cancel_crop()
    end
end

local bindings = {}
local bindings_repeat = {}

function cancel_crop()
    crop_first_corner = nil
    for key, _ in pairs(bindings) do
        mp.remove_key_binding("crop-"..key)
    end
    for key, _ in pairs(bindings_repeat) do
        mp.remove_key_binding("crop-"..key)
    end
    mp.unobserve_property(redraw)
    mp.unregister_idle(draw_crop_zone)
    mp.set_osd_ass(1280, 720, '')
    active = false
    if uosc_available and uosc_off then
        mp.commandv('script-message-to', 'uosc', 'disable-elements', mp.get_script_name(), '')
        uosc_off = false
    end
end

-- adjust coordinates based on previous values
function adjust_coordinates()
    local x, y, w, h = 0, 0, 1, 1
    for _, crop in ipairs(recursive_crop) do
        x = x + w * crop.x
        y = y + h * crop.y
        w = w * crop.w
        h = h * crop.h
    end
    return x, y, w, h
end

function apply_video_crop()
    local x, y, w, h = adjust_coordinates()

    local vop = mp.get_property_native("video-out-params")
    local x = math.floor(x * vop.w + 0.5)
    local y = math.floor(y * vop.h + 0.5)
    local w = math.floor(w * vop.w + 0.5)
    local h = math.floor(h * vop.h + 0.5)

    local video_crop = tostring(w) .."x".. tostring(h) .."+".. tostring(x) .."+".. tostring(y)
    mp.set_property_native("video-crop", video_crop)
end

function remove_filter(vf_table, filter_name, filter_number)
    local filter_count = 0
    local remove_last = 0
    for i = 1, #vf_table do
        if vf_table[i].name == filter_name then
            filter_count = filter_count + 1
            remove_last = i
        end
    end
    if filter_count > 0 then
        table.remove(vf_table, remove_last)
        mp.set_property_native("vf", vf_table)
        mp.osd_message("Removed: #" .. tostring(filter_number or filter_count) .. " " .. filter_name)
        return true
    end
    return false
end

function remove_video_crop(filter_number)
    if #recursive_crop > 0 then
        table.remove(recursive_crop)
        -- reapply each crop in the table
        apply_video_crop()
        if #recursive_crop == 0 then
            mp.set_property_native("video-crop", "")
        end
        mp.osd_message("Removed: #" .. tostring(filter_number or #recursive_crop + 1) .. " " .. "video-crop")
        return true
    end
    return false
end

function remove_zoom_pan(filter_number)
    if #recursive_zoom_pan > 0 then
        table.remove(recursive_zoom_pan)
        if #recursive_zoom_pan > 0 then
            local lastZoomPan = recursive_zoom_pan[#recursive_zoom_pan]
            mp.set_property("video-zoom", lastZoomPan.zoom)
            mp.set_property("video-pan-x", lastZoomPan.panX)
            mp.set_property("video-pan-y", lastZoomPan.panY)
        else
            mp.set_property("video-zoom", 0)
            mp.set_property("video-pan-x", 0)
            mp.set_property("video-pan-y", 0)
        end
        mp.osd_message("Removed: #" .. tostring(filter_number or #recursive_zoom_pan + 1) .. " " .. "soft-crop")
        return true
    end
    return false
end

-- remove an entry in 'remove_last_filter' at correct position to keep it in sync when 'remove_crop' and 'toggle_crop' are used in the same session
function remove_last_filter_entry(filter_type)
    for i = #remove_last_filter, 1, -1 do
        if remove_last_filter[i] == filter_type then
            table.remove(remove_last_filter, i)
            break
        end
    end
end

function remove_crop(mode, order)
    local vf_table = mp.get_property_native("vf")
    local total_filters = #remove_last_filter

    -- 'remove-crop all order' removes all filters starting with most recently added
    if order == "order" then
        if total_filters == 0 then
            mp.osd_message("Nothing to remove")
            return
        end
        local last_filter = table.remove(remove_last_filter)
        if last_filter == "hard" then
            remove_video_crop(total_filters)
        elseif last_filter == "delogo" then
            remove_filter(vf_table, "delogo", total_filters)
        elseif last_filter == "soft" then
            remove_zoom_pan(total_filters)
        end
    else
        local modes = {"delogo", "hard", "soft"}
        if order == "hard" then
            modes = {"hard", "soft", "delogo"}
        elseif order == "soft" then
            modes = {"soft", "hard", "delogo"}
        end

        for _, mode_name in ipairs(modes) do
            if not mode or mode == "all" or mode == mode_name then
                if mode_name == "delogo" and remove_filter(vf_table, "delogo") then
                    remove_last_filter_entry("delogo")
                    return
                elseif mode_name == "hard" and remove_video_crop() then
                    remove_last_filter_entry("hard")
                    return
                elseif mode_name == "soft" and remove_zoom_pan() then
                    remove_last_filter_entry("soft")
                    return
                end
            end
        end
        mp.osd_message("Nothing to remove")
    end
end

function start_crop(mode)
    if active then return end
    if not mp.get_property_native("osd-dimensions") then return end
    if mode and not mode_ok(mode) then
        msg.error("Invalid mode value: " .. mode)
        return
    end
    local mode_maybe = mode or opts.mode
    if mode_maybe == "delogo" then
        local hwdec = mp.get_property("hwdec-current")
        if hwdec and hwdec ~= "no" and not string.find(hwdec, "-copy$") then
            msg.error("Cannot crop with hardware decoding active (see manual)")
            return
        end
    end
    active = true
    active_mode = mode_maybe

    if uosc_available then
        mp.commandv('script-message-to', 'uosc', 'disable-elements', mp.get_script_name(), 'timeline,controls,volume,top_bar')
        uosc_off = true
    end
    if opts.mouse_support then
        cursor.x, cursor.y = mp.get_mouse_pos()
    end
    redraw()
    for key, func in pairs(bindings) do
        mp.add_forced_key_binding(key, "crop-"..key, func)
    end
    for key, func in pairs(bindings_repeat) do
        mp.add_forced_key_binding(key, "crop-"..key, func, { repeatable = true })
    end
    mp.register_idle(draw_crop_zone)
    mp.observe_property("osd-dimensions", nil, redraw)
end

function toggle_crop(mode)
    if mode and not mode_ok(mode) then
        msg.error("Invalid mode value: " .. mode)
    end
    local toggle_mode = mode or opts.mode

    if toggle_mode == "soft" and not remove_zoom_pan() then
        start_crop(mode)
    elseif toggle_mode == "soft" then
        remove_last_filter_entry("soft")
    end

    local vf_table = mp.get_property_native("vf")
    if toggle_mode == "delogo" and not remove_filter(vf_table, "delogo") then
        start_crop(mode)
    elseif toggle_mode == "delogo" then
        remove_last_filter_entry("delogo")
    end

    if toggle_mode == "hard" and not remove_video_crop() then
        start_crop(mode)
    elseif toggle_mode == "hard" then
        remove_last_filter_entry("hard")
    end
end

-- check if uosc is available
mp.register_script_message('uosc-version', function(version)
    uosc_available = true
end)

-- bindings
if opts.mouse_support then
    bindings["MOUSE_MOVE"] = function() cursor.x, cursor.y = mp.get_mouse_pos(); redraw() end
end
for _, key in ipairs(opts.accept) do
    bindings[key] = update_crop_zone_state
end
for _, key in ipairs(opts.cancel) do
    bindings[key] = cancel_crop
end
function movement_func(move_x, move_y)
    return function()
        cursor.x = cursor.x + move_x
        cursor.y = cursor.y + move_y
        redraw()
    end
end
bindings_repeat[opts.left_coarse]  = movement_func(-opts.coarse_movement, 0)
bindings_repeat[opts.right_coarse] = movement_func(opts.coarse_movement, 0)
bindings_repeat[opts.up_coarse]    = movement_func(0, -opts.coarse_movement)
bindings_repeat[opts.down_coarse]  = movement_func(0, opts.coarse_movement)
bindings_repeat[opts.left_fine]    = movement_func(-opts.fine_movement, 0)
bindings_repeat[opts.right_fine]   = movement_func(opts.fine_movement, 0)
bindings_repeat[opts.up_fine]      = movement_func(0, -opts.fine_movement)
bindings_repeat[opts.down_fine]    = movement_func(0, opts.fine_movement)


mp.add_key_binding(nil, "remove-crop", remove_crop)
mp.add_key_binding(nil, "start-crop", start_crop)
mp.add_key_binding(nil, "toggle-crop", toggle_crop)
