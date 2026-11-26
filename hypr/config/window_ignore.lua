local M = {}

-- Bulletproof dynamic property extraction for HL.Window userdata
local function get_window_geometry(w)
    local wx, wy, ww, wh

    -- Array of possible position coordinate locations in Hyprland Lua
    local pos_probes = {
        function() return w.at.x, w.at.y end,
        function() return w.at[1], w.at[2] end,
        function() return w.position.x, w.position.y end,
        function() return w.pos.x, w.pos.y end,
        function() return w.x, w.y end
    }

    -- Array of possible dimension locations
    local size_probes = {
        function() return w.size.x, w.size.y end,
        function() return w.size[1], w.size[2] end,
        function() return w.width, w.height end
    }

    for _, probe in ipairs(pos_probes) do
        local success, x, y = pcall(probe)
        if success and type(x) == "number" and type(y) == "number" then
            wx, wy = x, y
            break
        end
    end

    for _, probe in ipairs(size_probes) do
        local success, width, height = pcall(probe)
        if success and type(width) == "number" and type(height) == "number" then
            ww, wh = width, height
            break
        end
    end

    return wx, wy, ww, wh
end

local function is_hovered_window(w, cx, cy)
	local wx, wy, ww, wh = get_window_geometry(w)
    
    local mapped = pcall(function() return w.mapped end) and w.mapped or false
    local hidden = pcall(function() return w.hidden end) and w.hidden or false

	local hovered_addr = nil

	if mapped and not hidden and wx and wy and ww and wh then
		if cx >= wx and cx <= wx + ww and cy >= wy and cy <= wy + wh then
			hovered_addr = w.address
		end
	end

	return hovered_addr
end

local function field(obj, key)
    local ok, value = pcall(function() return obj[key] end)
    if ok then
        return value
    end
    return nil
end

local function workspace_of(w)
    local ws = field(w, "workspace")
    if ws == nil then
        return nil
    end
    return field(ws, "id")
end

local function is_ghosted(w)
    local tags = field(w, "tags") or {}
    for _, tag in ipairs(tags) do
        if tag == "ghosted" then
            return true
        end
    end
    return false
end

local function has_tag(w, wanted)
    local tags = field(w, "tags") or {}
    for _, tag in ipairs(tags) do
        if tag == wanted then
            return true
        end
    end
    return false
end

local function fullscreen_mode(w)
    -- Hyprland reports 0=normal, 1=maximized, 2=fullscreen. Accept the
    -- boolean form too, in case the Lua binding exposes fullscreen as a bool.
    local raw = field(w, "fullscreen")
    if raw == nil then
        raw = field(w, "fullscreenState") or field(w, "fullscreen_state")
    end
    local mode = tonumber(raw)
    if mode == 2 or raw == "fullscreen" then
        return "fullscreen"
    elseif mode == 1 or raw == "maximized" then
        return "maximized"
    elseif raw == true then
        local alternate = tonumber(field(w, "fullscreenMode") or field(w, "fullscreen_mode"))
        return alternate == 1 and "maximized" or "fullscreen"
    end
    return nil
end

local function get_monitor_bounds()
    local ok, mon = pcall(hl.get_monitor_at_cursor)
    if not ok or not mon then
        return nil
    end
    -- width/height are mode pixels; window geometry is in logical pixels.
    local scale = tonumber(field(mon, "scale")) or 1
    local width, height = mon.width / scale, mon.height / scale
    if (tonumber(field(mon, "transform")) or 0) % 2 == 1 then
        width, height = height, width
    end
    return mon.x, mon.y, width, height
end

-- Inactive group members share the group's geometry, and focusing one switches
-- the group's tab. `visible` can't tell them apart: it's also false for every
-- window behind a fullscreen one.
local function is_inactive_group_member(w)
    local group = field(w, "group")
    if group == nil then
        return false
    end
    local current = field(group, "current")
    return current ~= nil and current.address ~= w.address
end

local function collect_candidates(windows, active_addr, active_ws, mx, my, mw, mh)
    local list = {}
    for _, w in pairs(windows) do
        if w.address ~= active_addr and field(w, "mapped") and not field(w, "hidden") and not is_inactive_group_member(w) and not is_ghosted(w) and workspace_of(w) == active_ws then
            local x, y, width, height = get_window_geometry(w)
            if x and y and width and height then
                local center_x, center_y = x + width / 2, y + height / 2
                if center_x >= mx and center_x < mx + mw and center_y >= my and center_y < my + mh then
                    table.insert(list, {
                        address = w.address, x = x, y = y, w = width, h = height,
                        history = tonumber(field(w, "focus_history_id")),
                    })
                end
            end
        end
    end
    return list
end

local function find_side_neighbor(ax, ay, aw, ah, candidates, dir)
    local best, best_gap = nil, nil
    for _, c in ipairs(candidates) do
        local gap
        if dir == "r" then
            gap = c.x - (ax + aw)
        else
            gap = ax - (c.x + c.w)
        end

        local overlaps = c.y < ay + ah and c.y + c.h > ay
        if overlaps and gap >= -2 and (best_gap == nil or gap < best_gap) then
            best, best_gap = c, gap
        end
    end
    return best
end

local function other_monitor_id(active_win)
    local current = field(field(active_win, "monitor"), "id")
    local ok, monitors = pcall(hl.get_monitors)
    if not ok or type(monitors) ~= "table" then
        return nil
    end

    for _, m in ipairs(monitors) do
        local id = field(m, "id")
        if id ~= nil and id ~= current then
            return id
        end
    end
    return nil
end

local function choose_target(active_win, windows, cx)
    local mx, my, mw, mh = get_monitor_bounds()
    local ax, ay, aw, ah = get_window_geometry(active_win)

    if mx and ax and ay and aw and ah then
        local candidates = collect_candidates(windows, active_win.address, workspace_of(active_win), mx, my, mw, mh)
        local target = nil

        if fullscreen_mode(active_win) then
            -- The other windows sit under a fullscreen or maximized window, not
            -- beside it, so hand focus to the most recently used one.
            for _, c in ipairs(candidates) do
                if c.history and (target == nil or c.history < target.history) then
                    target = c
                end
            end
            target = target or candidates[1]
        elseif field(active_win, "floating") then
            local acx, acy = ax + aw / 2, ay + ah / 2
            local best_dist = nil
            for _, c in ipairs(candidates) do
                local dist = (c.x + c.w / 2 - acx) ^ 2 + (c.y + c.h / 2 - acy) ^ 2
                if best_dist == nil or dist < best_dist then
                    target, best_dist = c, dist
                end
            end
        else
            local near = (cx > ax + aw / 2) and "r" or "l"
            local far = (near == "r") and "l" or "r"
            target = find_side_neighbor(ax, ay, aw, ah, candidates, near)
                or find_side_neighbor(ax, ay, aw, ah, candidates, far)
        end

        if target then
            return { window = target.address }
        end
    end

    local monitor_id = other_monitor_id(active_win)
    if monitor_id then
        return { monitor = monitor_id }
    end
    return nil
end

function M.toggle()
    local cursor = hl.get_cursor_pos()
    if not cursor then 
        return 
    end
    
    local cx, cy = cursor.x, cursor.y

    local active_win = hl.get_active_window()
    local active_addr = active_win and active_win.address or "none"

    local windows = hl.get_windows()
    if type(windows) ~= "table" then
        return
    end

    -- Restore an ignored window before considering the active window. The
    -- active window can overlap a ghosted window, and checking it first would
    -- otherwise select the active window again instead of reaching the restore
    -- branch below. Do not restrict this lookup to the active workspace: a
    -- no-focus window cannot become active to satisfy that condition.
    for _, w in pairs(windows) do
        if is_ghosted(w) then
            local ghosted_addr = is_hovered_window(w, cx, cy)
            if ghosted_addr then
                local addr_str = "address:" .. ghosted_addr
                local restore_mode = has_tag(w, "ghosted-fullscreen") and "fullscreen"
                    or (has_tag(w, "ghosted-maximized") and "maximized" or nil)
                hl.dispatch(hl.dsp.window.set_prop({ window = addr_str, prop = "no_focus", value = "0" }))
                hl.dispatch(hl.dsp.window.tag({ tag = "-ghosted", window = addr_str }))
                hl.dispatch(hl.dsp.window.tag({ tag = "-ghosted-fullscreen", window = addr_str }))
                hl.dispatch(hl.dsp.window.tag({ tag = "-ghosted-maximized", window = addr_str }))
                hl.dispatch(hl.dsp.focus({ window = addr_str }))
                if restore_mode then
                    hl.dispatch(hl.dsp.window.fullscreen({ mode = restore_mode, action = "set" }))
                end
                return
            end
        end
    end

    local active_ws = active_win and workspace_of(active_win)
    local hovered_addr = active_win and is_hovered_window(active_win, cx, cy) or nil

    if not hovered_addr then
        for _, w in pairs(windows) do
            if field(w, "visible") and workspace_of(w) == active_ws then
                hovered_addr = is_hovered_window(w, cx, cy)
                if hovered_addr then
                    break
                end
            end
        end
    end

    if hovered_addr then
        local addr_str = "address:" .. hovered_addr
        
        if hovered_addr == active_addr then
            local target = choose_target(active_win, windows, cx)
            if not target then
                return
            end

            local mode_to_restore = fullscreen_mode(active_win)

            hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen", action = "unset" }))
            hl.dispatch(hl.dsp.window.fullscreen({ mode = "maximized", action = "unset" }))
            
            hl.dispatch(hl.dsp.window.set_prop({ window = addr_str, prop = "no_focus", value = "1" }))
            hl.dispatch(hl.dsp.window.tag({ tag = "+ghosted", window = addr_str }))
            if mode_to_restore == "fullscreen" then
                hl.dispatch(hl.dsp.window.tag({ tag = "+ghosted-fullscreen", window = addr_str }))
            elseif mode_to_restore == "maximized" then
                hl.dispatch(hl.dsp.window.tag({ tag = "+ghosted-maximized", window = addr_str }))
            end
            if target.monitor then
                hl.dispatch(hl.dsp.focus({ monitor = target.monitor }))
            else
                hl.dispatch(hl.dsp.focus({ window = "address:" .. target.window }))
            end
        else
            hl.dispatch(hl.dsp.window.set_prop({ window = addr_str, prop = "no_focus", value = "0" }))
            hl.dispatch(hl.dsp.window.tag({ tag = "-ghosted", window = addr_str }))
            hl.dispatch(hl.dsp.focus({ window = addr_str }))
        end
    end
end

return M
