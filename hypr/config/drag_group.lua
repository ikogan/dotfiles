local mainMod = "SUPER"

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

local function rect(w)
    local ok, x, y = pcall(function() return w.at.x, w.at.y end)
    local ok2, width, height = pcall(function() return w.size.x, w.size.y end)
    if ok and ok2 and x and y and width and height then
        return x, y, width, height
    end
    return nil
end

local function window_under_cursor(dragged, cursor)
    local active_ws = workspace_of(dragged)
    for _, w in pairs(hl.get_windows()) do
        if w.address ~= dragged.address and field(w, "visible") and workspace_of(w) == active_ws then
            local x, y, width, height = rect(w)
            if x and cursor.x >= x and cursor.x <= x + width and cursor.y >= y and cursor.y <= y + height then
                return w
            end
        end
    end
    return nil
end

local function side_of(dragged, target)
    local dx, dy, dw, dh = rect(dragged)
    local tx, ty, tw, th = rect(target)
    if not (dx and tx) then
        return nil
    end
    local offset_x = (dx + dw / 2) - (tx + tw / 2)
    local offset_y = (dy + dh / 2) - (ty + th / 2)
    if math.abs(offset_x) > math.abs(offset_y) then
        return offset_x > 0 and "l" or "r"
    end
    return offset_y > 0 and "u" or "d"
end

hl.bind(mainMod .. " + SHIFT + mouse:272", hl.dsp.window.drag())

hl.bind(mainMod .. " + SHIFT + mouse:272", function()
    local dragged = hl.get_active_window()
    local cursor = hl.get_cursor_pos()
    if not dragged or not cursor then
        return
    end
    local target = window_under_cursor(dragged, cursor)
    if not target then
        return
    end
    local direction = side_of(dragged, target)
    if direction then
        hl.dispatch(hl.dsp.window.move({ into_group = direction }))
    end
end, { release = true })
