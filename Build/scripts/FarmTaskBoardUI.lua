-- FarmTaskBoardUI.lua
-- Small immediate-mode toolkit for the task board page (same approach as FS25_CropYearWheelPlanner).
--
-- The board is drawn by the frame itself (FarmTaskBoardFrame:draw) with drawFilledRect and
-- renderText, and clicks are matched against the boxes registered while drawing
-- (FarmTaskBoardFrame:mouseEvent). Sizes are given in GUI pixels of the 1920x1080 reference
-- layout and scaled like the rest of the menu. Colours follow the mockups (Docs/mockups).

FarmTaskBoardUI = {}
local UI = FarmTaskBoardUI

local function hex(s, a)
    return { tonumber(string.sub(s, 1, 2), 16) / 255, tonumber(string.sub(s, 3, 4), 16) / 255, tonumber(string.sub(s, 5, 6), 16) / 255, a or 1 }
end
UI.hex = hex

UI.C = {
    text = hex("e8e8e8"),
    muted = hex("9a9a9a"),
    green = hex("8dc63f"),
    greenFaint = hex("8dc63f", 0.08),
    yellow = hex("e0b030"),
    grey = hex("7a7a7a"),
    dark = hex("111111"),
    toolbar = hex("000000", 0.25),
    column = hex("ffffff", 0.035),
    columnLine = hex("2c2f28"),
    card = hex("23271f"),
    cardLine = hex("353b2e"),
    doneText = hex("9a9a9a"),
    buttonLine = hex("555555"),
    key = hex("333333"),
    keyText = hex("dddddd"),
    roleBg = hex("2a3a1a"),
    roleLine = hex("4d6b25"),
    roleText = hex("b8e07a"),
    viewBg = hex("2a2a2a"),
    viewText = hex("bbbbbb"),
    modalShade = hex("000000", 0.55),
    dialog = hex("181b15"),
    dialogLine = hex("3a4130"),
    input = hex("0f110d"),
    inputLine = hex("333333"),
    segLine = hex("444444"),
    danger = hex("e06050"),
    dangerLine = hex("a04030"),
    dangerBg = hex("a04030", 0.12),
    red = hex("c04a38"),
    warn = hex("ffb27a"),
    white = hex("ffffff"),
    shadow = hex("000000", 0.35),
    hover = hex("ffffff", 0.06),
    tooltip = hex("0d0d0d", 0.95),
}

-- Status colours: grey, yellow, green
UI.STATUS_COLORS = { [0] = UI.C.grey, [1] = UI.C.yellow, [2] = UI.C.green }

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------

function UI.px(n)
    return n * (g_pixelSizeScaledX or (1 / 1920))
end

function UI.py(n)
    return n * (g_pixelSizeScaledY or (1 / 1080))
end

-- Colour c with its alpha multiplied by a
function UI.alpha(c, a)
    if a == nil or a >= 1 then
        return c
    end
    return { c[1], c[2], c[3], (c[4] or 1) * a }
end

---------------------------------------------------------------------------
-- Clickable boxes and tooltip of this frame
---------------------------------------------------------------------------

function UI.begin(state)
    state.hits = {}
    state.tooltip = nil
end

function UI.isInside(state, x, y, w, h)
    local mx, my = state.mouseX, state.mouseY
    return mx ~= nil and mx >= x and mx <= x + w and my >= y and my <= y + h
end

-- Registers a clickable box; the last one registered is on top.
-- onClick = UI.PASS: the box takes the click away from the boxes below it, but leaves it to
-- the game's own GUI elements (the text field in the dialog).
UI.PASS = "pass"
function UI.hit(state, x, y, w, h, onClick, tooltip, id)
    if onClick ~= nil then
        table.insert(state.hits, { x = x, y = y, w = w, h = h, onClick = onClick, id = id })
    end
    if tooltip ~= nil and UI.isInside(state, x, y, w, h) then
        state.tooltip = tooltip
    end
end

-- Runs the click of the box under the mouse; true if the click was used
function UI.click(state, mx, my)
    if state.hits == nil then
        return false
    end
    for i = #state.hits, 1, -1 do
        local h = state.hits[i]
        if mx >= h.x and mx <= h.x + h.w and my >= h.y and my <= h.y + h.h then
            if h.onClick == UI.PASS then
                return false
            end
            h.onClick()
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function UI.rect(x, y, w, h, c)
    if w > 0 and h > 0 then
        drawFilledRect(x, y, w, h, c[1], c[2], c[3], c[4] or 1)
    end
end

function UI.border(x, y, w, h, c, thick)
    local tx = UI.px(thick or 1)
    local ty = UI.py(thick or 1)
    UI.rect(x, y, w, ty, c)
    UI.rect(x, y + h - ty, w, ty, c)
    UI.rect(x, y + ty, tx, h - 2 * ty, c)
    UI.rect(x + w - tx, y + ty, tx, h - 2 * ty, c)
end

-- Box with a background and a border
function UI.box(x, y, w, h, bg, line, thick)
    if bg ~= nil then
        UI.rect(x, y, w, h, bg)
    end
    if line ~= nil then
        UI.border(x, y, w, h, line, thick)
    end
end

function UI.dashed(x, y, w, h, c)
    local dashX, gapX = UI.px(9), UI.px(6)
    local dashY, gapY = UI.py(9), UI.py(6)
    local tx, ty = UI.px(2), UI.py(2)
    local p = 0
    while p < w do
        local len = math.min(dashX, w - p)
        UI.rect(x + p, y, len, ty, c)
        UI.rect(x + p, y + h - ty, len, ty, c)
        p = p + dashX + gapX
    end
    p = 0
    while p < h do
        local len = math.min(dashY, h - p)
        UI.rect(x, y + p, tx, len, c)
        UI.rect(x + w - tx, y + p, tx, len, c)
        p = p + dashY + gapY
    end
end

local function textWidth(size, text, bold)
    setTextBold(bold == true)
    local w = getTextWidth(size, text)
    setTextBold(false)
    return w
end
UI.textWidth = textWidth

-- Byte positions where each UTF-8 character ends
local function charEnds(s)
    local ends = {}
    local len = string.len(s)
    for i = 1, len do
        local nextByte = string.byte(s, i + 1)
        if nextByte == nil or nextByte < 128 or nextByte >= 192 then
            table.insert(ends, i)
        end
    end
    return ends
end

-- Text shortened with ".." to fit maxWidth. Binary search over whole characters, and cached:
-- a task can be 500 characters and the board is drawn every frame.
UI.fitCache = {}
UI.fitCacheSize = 0
function UI.fit(text, size, maxWidth, bold)
    local key = string.format("%s|%.5f|%.5f|%s", text, size, maxWidth, tostring(bold == true))
    local cached = UI.fitCache[key]
    if cached ~= nil then
        return cached.text, cached.cut
    end
    local result, cut = text, false
    if textWidth(size, text, bold) > maxWidth + UI.px(1) then
        cut = true
        local ends = charEnds(text)
        local lo, hi = 0, #ends
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if textWidth(size, string.sub(text, 1, ends[mid]) .. "..", bold) <= maxWidth then
                lo = mid
            else
                hi = mid - 1
            end
        end
        result = (lo > 0 and string.gsub(string.sub(text, 1, ends[lo]), "%s+$", "") or "") .. ".."
    end
    if UI.fitCacheSize > 2000 then
        UI.fitCache = {}
        UI.fitCacheSize = 0
    end
    UI.fitCache[key] = { text = result, cut = cut }
    UI.fitCacheSize = UI.fitCacheSize + 1
    return result, cut
end

-- Upper case that also works for æ, ø, å, ä, ö, ü, é ... (string.upper only knows A-Z).
-- The game's utf8ToUpper when there is one, otherwise Latin-1 letters by hand.
function UI.upper(text)
    if utf8ToUpper ~= nil then
        return utf8ToUpper(text)
    end
    text = string.upper(text)
    -- UTF-8 C3 A0..C3 BE (à..þ) -> C3 80..C3 9E (À..Þ), except C3 B7 (÷)
    return (string.gsub(text, "\195([\160-\190])", function(c)
        local b = string.byte(c)
        if b == 183 then
            return "\195" .. c
        end
        return "\195" .. string.char(b - 32)
    end))
end

-- renderText is drawn after every drawFilledRect of the frame, so a box can never cover text.
-- While a text mask is set, text that touches the mask box is left out and all other text gets
-- its alpha multiplied by dim (the board behind the dialog).
UI.textMask = nil
function UI.setTextMask(x, y, w, h, dim)
    UI.textMask = { x = x, y = y, w = w, h = h, dim = dim }
end

function UI.clearTextMask()
    UI.textMask = nil
end

local function isMasked(x, y, size, text, align, bold)
    local m = UI.textMask
    local w = textWidth(size, text, bold)
    local left = x
    if align == "center" then
        left = x - w * 0.5
    elseif align == "right" then
        left = x - w
    end
    -- y is the baseline; descenders go a little below it
    local bottom, top = y - size * 0.3, y + size
    return left < m.x + m.w and left + w > m.x and bottom < m.y + m.h and top > m.y
end

-- align: "left" (default), "center", "right"; x is the left edge, centre or right edge
function UI.text(x, y, size, text, c, align, bold)
    c = c or UI.C.text
    if UI.textMask ~= nil then
        if isMasked(x, y, size, text, align, bold) then
            return
        end
        c = UI.alpha(c, UI.textMask.dim)
    end
    setTextColor(c[1], c[2], c[3], c[4] or 1)
    setTextBold(bold == true)
    if align == "center" then
        setTextAlignment(RenderText.ALIGN_CENTER)
    elseif align == "right" then
        setTextAlignment(RenderText.ALIGN_RIGHT)
    else
        setTextAlignment(RenderText.ALIGN_LEFT)
    end
    renderText(x, y, size, text)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- Text vertically centred in a box of height h at y
function UI.textIn(x, y, h, size, text, c, align, bold)
    UI.text(x, y + (h - size) * 0.5 + size * 0.15, size, text, c, align, bold)
end

-- Wraps text into lines that fit maxWidth; words longer than a line are cut
function UI.wrap(text, size, maxWidth, maxLines)
    local lines = {}
    local line = ""
    for word in string.gmatch(text, "%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if getTextWidth(size, candidate) > maxWidth and line ~= "" then
            table.insert(lines, line)
            line = word
        else
            line = candidate
        end
        if maxLines ~= nil and #lines >= maxLines then
            break
        end
    end
    if line ~= "" and (maxLines == nil or #lines < maxLines) then
        table.insert(lines, line)
    end
    for i, l in ipairs(lines) do
        lines[i] = UI.fit(l, size, maxWidth)
    end
    return lines
end

-- Button: opts = { bg, fg, line, size, bold, disabled, onClick, tooltip, id, alpha }
function UI.button(state, x, y, w, h, label, opts)
    opts = opts or {}
    local a = opts.alpha
    UI.box(x, y, w, h, opts.bg and UI.alpha(opts.bg, a), opts.line and UI.alpha(opts.line, a))
    local hovered = not opts.disabled and opts.onClick ~= nil and UI.isInside(state, x, y, w, h)
    if hovered then
        UI.rect(x, y, w, h, UI.C.hover)
    end
    if label ~= nil and label ~= "" then
        local size = opts.size or UI.py(14)
        local fg = opts.fg or UI.C.text
        if opts.disabled then
            fg = UI.alpha(fg, 0.4)
        end
        local text = UI.fit(label, size, w - UI.px(16), opts.bold)
        UI.textIn(x + w * 0.5, y, h, size, text, UI.alpha(fg, a), "center", opts.bold)
    end
    if not opts.disabled then
        UI.hit(state, x, y, w, h, opts.onClick, opts.tooltip, opts.id or label)
    elseif opts.tooltip ~= nil then
        UI.hit(state, x, y, w, h, nil, opts.tooltip)
    end
    return hovered
end

-- Tooltip at the mouse, drawn last
function UI.drawTooltip(state)
    if state.tooltip == nil or state.mouseX == nil then
        return
    end
    local size = UI.py(14)
    local lines = UI.wrap(state.tooltip, size, UI.px(420), 14)
    local w = 0
    for _, line in ipairs(lines) do
        w = math.max(w, getTextWidth(size, line))
    end
    local pad = UI.px(10)
    local lineH = size * 1.4
    local h = #lines * lineH + UI.py(12)
    local x = state.mouseX + UI.px(16)
    local y = state.mouseY - h - UI.py(8)
    if x + w + 2 * pad > 1 then
        x = 1 - w - 2 * pad
    end
    if y < 0 then
        y = state.mouseY + UI.py(20)
    end
    UI.box(x, y, w + 2 * pad, h, UI.C.tooltip, UI.C.buttonLine)
    local ty = y + h - UI.py(6)
    for _, line in ipairs(lines) do
        ty = ty - lineH
        UI.text(x + pad, ty + size * 0.3, size, line, UI.C.text)
    end
end

-- Reset render state for the rest of the GUI
function UI.finish()
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end
