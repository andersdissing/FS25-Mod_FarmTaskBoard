-- FarmTaskBoardFrame.lua
-- The "Tasks" tab in the in-game menu (Esc), placed directly above the base game Settings tab.
--
-- Below the base game header the page is drawn in Lua (FarmTaskBoardUI):
--   toolbar  "+ New task" (farm manager only) and the role badge
--   board    three columns (not started / to do / done) with one-line cards
--   footer   shortcut hints and "Synced with all players" (multiplayer)
--   dialog   create / edit a task: number, text (500 characters, with a counter), status,
--            delete with confirmation. The text field is the game's own TextInput element.
--
-- Drag and drop (farm manager only), built from mouse events:
--   1. mouse button down on a card and a move of more than 5 px starts the drag; the card stays
--      in its place at alpha 0.25
--   2. a copy of the card (ghost) follows the mouse: alpha 0.7, scaled 1.03, with a shadow
--   3. the column under the mouse gets a green border and a faint green background; a dashed
--      placeholder shows where the card lands and the other cards slide aside
--   4. release: the ghost slides into the placeholder (200 ms, ease-out), then the move is sent.
--      Release outside a column or Esc: the ghost slides back.
-- Every card slides to its new place when the board changes (a move, a sync from the server,
-- a rejected move that puts the card back).

FarmTaskBoardFrame = {}
FarmTaskBoardFrame.GUI_NAME = "FarmTaskBoardFrame"

local Frame = FarmTaskBoardFrame
local Frame_mt = Class(FarmTaskBoardFrame, TabbedMenuFrameElement)
local UI = FarmTaskBoardUI
local D = FarmTaskBoardData
local S = FarmTaskBoardSync
local px, py = UI.px, UI.py

-- Layout in GUI pixels (1920x1080 reference)
Frame.TOOLBAR_H = 52
Frame.FOOTER_H = 40
Frame.COLUMN_GAP = 28
Frame.SIDE_MARGIN = 56
-- Room kept free at the right screen edge and for the menu's button bar at the bottom
Frame.SCREEN_MARGIN_RIGHT = 24
Frame.BUTTON_BAR_H = 64
Frame.COLUMN_HEADER_H = 46
Frame.LIST_PAD = 14
Frame.CARD_H = 48
Frame.CARD_GAP = 10
Frame.DIALOG_W = 640

-- Animation
Frame.DRAG_START_PX = 5
Frame.DOUBLE_CLICK_MS = 400
Frame.LAND_MS = 200
Frame.RETURN_MS = 220
-- Cards follow their place with this time constant: ~95 % of the way after 3x (about 180 ms)
Frame.SLIDE_TAU_MS = 60
Frame.GHOST_SCALE = 1.03
Frame.GHOST_ALPHA = 0.7
Frame.SOURCE_ALPHA = 0.25

local function t(key)
    return g_i18n:getText(key)
end

local function now()
    return g_time or 0
end

local function setText(element, text)
    if element ~= nil and element.setText ~= nil then
        element:setText(text)
    end
end

-- Shows a whole image file (size x size pixels) in a Bitmap. The UVs must be reset too: the
-- header icon profile points at a slice of the game's icon atlas (FS25_CropYearWheelPlanner v1.3.2).
local function setImage(element, filename, size)
    if element == nil or element.setImageFilename == nil then
        return
    end
    element:setImageFilename(filename)
    if element.setImageUVs ~= nil then
        element:setImageUVs(nil, unpack(GuiUtils.getUVs({ 0, 0, size, size }, { size, size })))
    end
end

-- Removes every occurrence of item from list; true if it was there
local function removeFromList(list, item)
    if type(list) ~= "table" then
        return false
    end
    local found = false
    for i = #list, 1, -1 do
        if list[i] == item then
            table.remove(list, i)
            found = true
        end
    end
    return found
end

-- Moves item so it comes directly before anchor in list (at the end if anchor is not in it).
-- getElement maps a list entry to the element it stands for (default: the entry itself).
local function moveBefore(list, item, anchor, getElement)
    if list == nil or anchor == nil then
        return
    end
    getElement = getElement or function(entry) return entry end

    local entry = nil
    for i = 1, #list do
        if getElement(list[i]) == item then
            entry = table.remove(list, i)
            break
        end
    end
    if entry == nil then
        return
    end
    for i = 1, #list do
        if getElement(list[i]) == anchor then
            table.insert(list, i, entry)
            return
        end
    end
    table.insert(list, entry)
end

function Frame.new(target, customMt)
    local self = TabbedMenuFrameElement.new(target, customMt or Frame_mt)
    self.state = { hits = {} }
    self.anim = {}
    self.scroll = { [0] = 0, [1] = 0, [2] = 0 }
    self.cards = {}
    self.drag = nil
    self.pending = nil
    self.dialog = nil
    self.lastClick = nil
    self.canManage = false
    return self
end

---------------------------------------------------------------------------
-- Install / uninstall (same method as FS25_CropYearWheelPlanner, seen working in the game)
---------------------------------------------------------------------------

-- The frame is added as a child of the menu's paging element (that is how the page gets an id
-- the menu can look up), then registered as page with a tab, and moved so the tab sits directly
-- above the base game Settings tab. Courseplay and AdvancedDamageSystem do the same.
function Frame.install(modDirectory)
    local menu = g_inGameMenu
    if menu == nil or g_gui == nil or menu.pagingElement == nil then
        Logging.warning("[FarmTaskBoard] In-game menu not available, Tasks tab not added")
        return
    end

    if g_gui.frames ~= nil and g_gui.frames[Frame.GUI_NAME] ~= nil then
        g_gui.frames[Frame.GUI_NAME] = nil
    end

    local frame = Frame.new()
    g_gui:loadGui(modDirectory .. "gui/FarmTaskBoardFrame.xml", Frame.GUI_NAME, frame, true)
    if frame.elements[1] == nil then
        Logging.warning("[FarmTaskBoard] Tasks tab GUI could not be loaded")
        return
    end
    frame.elements[1].title = t("ftb_tab_title")
    frame.modDirectory = modDirectory

    local anchor = menu.pageSettings
    if anchor == nil then
        Logging.warning("[FarmTaskBoard] Settings page not found, Tasks tab added at the end")
    end

    menu.pageFarmTaskBoard = frame
    menu.pagingElement:addElement(frame)
    moveBefore(menu.pagingElement.elements, frame, anchor)
    moveBefore(menu.pagingElement.pages, frame, anchor, function(page) return page.element end)
    menu.pagingElement:updateAbsolutePosition()
    menu.pagingElement:updatePageMapping()

    menu:registerPage(frame, nil, nil)
    local uvs = GuiUtils.getUVs({ 0, 0, 256, 256 }, { 256, 256 })
    menu:addPageTab(frame, modDirectory .. "icon_tab.dds", uvs)
    moveBefore(menu.pageFrames, frame, anchor)
    if menu.rebuildTabList ~= nil then
        menu:rebuildTabList()
    end
    frame:updateAbsolutePosition()

    if frame.taskTextInput ~= nil then
        frame.taskTextInput:setVisible(false)
    end

    Frame.instance = frame
end

function Frame.uninstall()
    local frame = Frame.instance
    if frame == nil then
        return
    end
    Frame.instance = nil
    frame:resetInteraction()

    -- Remove the page from every list it was added to (FS25_CropYearWheelPlanner issue #2:
    -- TabbedMenu.lua:285 'iconFilename' when quitting if the tab list still had the page)
    local menu = g_inGameMenu
    if menu ~= nil then
        if menu.unregisterPage ~= nil then
            local class = Frame
            if frame.class ~= nil then
                class = frame:class()
            end
            menu:unregisterPage(class)
        end
        removeFromList(menu.pageFrames, frame)
        removeFromList(menu.enabledPages, frame)
        for _, map in ipairs({ menu.pageTabs, menu.pageRoots, menu.pageEnablingPredicates }) do
            if type(map) == "table" then
                map[frame] = nil
            end
        end
        if type(menu.pageTypeControllers) == "table" then
            for key, controller in pairs(menu.pageTypeControllers) do
                if controller == frame then
                    menu.pageTypeControllers[key] = nil
                end
            end
        end
        if menu.currentPage == frame then
            menu.currentPage = nil
        end
        if menu.pagingElement ~= nil then
            menu.pagingElement:removeElement(frame)
            menu.pagingElement:updatePageMapping()
        end
        if menu.rebuildTabList ~= nil then
            menu:rebuildTabList()
        end
        if type(menu.restorePageIndex) == "number" and type(menu.enabledPages) == "table" and menu.restorePageIndex > #menu.enabledPages then
            menu.restorePageIndex = 1
            menu.restorePageScrollOffset = 0
        end
        menu.pageFarmTaskBoard = nil
    end
    frame:delete()
    if g_gui ~= nil and g_gui.frames ~= nil then
        g_gui.frames[Frame.GUI_NAME] = nil
    end
end

---------------------------------------------------------------------------
-- Page open / close, menu buttons, Esc
---------------------------------------------------------------------------

function Frame:onFrameOpen()
    Frame:superClass().onFrameOpen(self)
    setText(self.headerTitle, t("ftb_header"))
    if self.modDirectory ~= nil then
        setImage(self.headerIcon, self.modDirectory .. "icon_tab.dds", 256)
    end
    self:setupMenuButtons()
    self:resetInteraction()
    -- Cards appear in place when the page opens; they only slide while it is open
    self.anim = {}
    self.lastTime = nil
end

function Frame:onFrameClose()
    self:resetInteraction()
    local superFunc = Frame:superClass().onFrameClose
    if superFunc ~= nil then
        superFunc(self)
    end
end

-- Ends a drag at once and closes the dialog
function Frame:resetInteraction()
    self.drag = nil
    self.pending = nil
    self.lastClick = nil
    if self.dialog ~= nil then
        self:closeDialog()
    end
end

-- Back, previous page and next page as usual, but the page keys do nothing while the player
-- types in the text field, the dialog is open or a card is dragged (as FS25_ProductionAdvisor).
function Frame:setupMenuButtons()
    if self.setMenuButtonInfo == nil or InputAction == nil then
        return
    end
    self.menuButtons = {
        { inputAction = InputAction.MENU_BACK },
        { text = t("ui_ingameMenuPrev"), inputAction = InputAction.MENU_PAGE_PREV, callback = function() self:onPageStep(-1) end },
        { text = t("ui_ingameMenuNext"), inputAction = InputAction.MENU_PAGE_NEXT, callback = function() self:onPageStep(1) end },
    }
    self:setMenuButtonInfo(self.menuButtons)
end

function Frame:onPageStep(direction)
    if self:isTyping() or self.dialog ~= nil or self.drag ~= nil then
        return
    end
    local menu = g_inGameMenu
    if menu == nil then
        return
    end
    if direction < 0 and menu.onPagePrevious ~= nil then
        menu:onPagePrevious()
    elseif direction > 0 and menu.onPageNext ~= nil then
        menu:onPageNext()
    end
end

-- True while the text field takes the keyboard
function Frame:isTyping()
    local element = self.taskTextInput
    return element ~= nil and (element.forcePressed == true or element.isCapturingInput == true)
end

-- Esc (back): cancels a drag, then closes the dialog, then closes the menu
function Frame:requestClose(callback)
    if self.drag ~= nil then
        if self.drag.phase == "drag" then
            self:cancelDrag()
        end
        return false
    end
    if self.dialog ~= nil then
        if not self:isTyping() then
            self:closeDialog()
        end
        return false
    end
    -- The same Esc that closed the dialog from the text field must not close the menu too
    if self.escAt ~= nil and now() - self.escAt < 250 then
        return false
    end
    local superFunc = Frame:superClass().requestClose
    if superFunc ~= nil then
        return superFunc(self, callback)
    end
    return true
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

-- Area below the base game header, in screen units
function Frame:getBoardArea()
    local root = self.elements ~= nil and self.elements[1] or nil
    if root == nil or root.absPosition == nil or root.absSize == nil then
        return nil
    end
    local x, y, w, h = root.absPosition[1], root.absPosition[2], root.absSize[1], root.absSize[2]
    if w <= 0 or h <= 0 then
        return nil
    end
    local top = y + h
    local header = self.headerPanel
    if header ~= nil and header.absPosition ~= nil and header.absPosition[2] > y and header.absPosition[2] < top then
        top = header.absPosition[2] - py(12)
    end
    -- The menu container reaches past the right screen edge and under the menu's button bar
    -- (E / Q / Esc) at the bottom (seen in the game at 16:9): keep the board on screen and above it
    local right = math.min(x + w, 1 - px(Frame.SCREEN_MARGIN_RIGHT))
    local bottom = math.max(y + py(8), py(Frame.BUTTON_BAR_H))
    if top - bottom <= py(200) or right - x <= px(400) then
        return nil
    end
    return { x = x, y = bottom, w = right - x, h = top - bottom }
end

function Frame:computeLayout(area)
    -- Margin left of the first column and right of the last; toolbar and footer line up with them
    local margin = px(Frame.SIDE_MARGIN)
    local full = area
    area = { x = area.x + margin, y = area.y, w = area.w - 2 * margin, h = area.h }
    local L = { area = area, full = full, columns = {} }
    local top = area.y + area.h
    L.toolbar = { x = area.x, y = top - py(Frame.TOOLBAR_H), w = area.w, h = py(Frame.TOOLBAR_H) }
    L.footer = { x = area.x, y = area.y, w = area.w, h = py(Frame.FOOTER_H) }
    local colTop = L.toolbar.y - py(14)
    local colBottom = L.footer.y + L.footer.h + py(14)
    local gap = px(Frame.COLUMN_GAP)
    local colW = (area.w - 2 * gap) / 3
    for i, status in ipairs(D.STATUSES) do
        local c = { status = status, x = area.x + (i - 1) * (colW + gap), y = colBottom, w = colW, h = colTop - colBottom }
        c.headerH = py(Frame.COLUMN_HEADER_H)
        c.listTop = colTop - c.headerH - py(Frame.LIST_PAD)
        c.listBottom = colBottom + py(Frame.LIST_PAD)
        c.cardX = c.x + px(Frame.LIST_PAD)
        c.cardW = colW - 2 * px(Frame.LIST_PAD)
        c.cardH = py(Frame.CARD_H)
        c.step = py(Frame.CARD_H + Frame.CARD_GAP)
        c.visible = math.max(1, math.floor((c.listTop - c.listBottom + py(Frame.CARD_GAP)) / c.step))
        L.columns[status] = c
    end
    return L
end

-- Bottom y of the card in slot (0 = top of the visible list)
local function slotY(c, slot)
    return c.listTop - c.cardH - slot * c.step
end

local function inside(r, x, y)
    return x ~= nil and y ~= nil and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function Frame:columnAt(x, y)
    if self.layout == nil then
        return nil
    end
    for _, status in ipairs(D.STATUSES) do
        local c = self.layout.columns[status]
        if inside(c, x, y) then
            return c
        end
    end
    return nil
end

function Frame:cardAt(x, y)
    for i = #self.cards, 1, -1 do
        local card = self.cards[i]
        if inside(card, x, y) then
            return card
        end
    end
    return nil
end

-- The board of the local player's farm; a spectator sees an empty board
function Frame:getBoard()
    if FarmTaskBoard:isSpectator() then
        self.emptyBoard = self.emptyBoard or D.newBoard()
        return self.emptyBoard
    end
    return FarmTaskBoard:getBoard()
end

-- What each column shows, top to bottom: { task } or { task, faded } or { placeholder }
function Frame:buildColumns(board)
    local lists = {}
    local drag = self.drag
    for _, status in ipairs(D.STATUSES) do
        local entries = {}
        for _, task in ipairs(D.getColumn(board, status)) do
            if drag ~= nil and task.id == drag.id then
                -- Over its own column the placeholder takes the card's place
                if drag.target ~= status then
                    table.insert(entries, { task = task, faded = true })
                end
            else
                table.insert(entries, { task = task })
            end
        end
        if drag ~= nil and drag.target == status then
            table.insert(entries, math.min(drag.insert, #entries) + 1, { placeholder = true })
        end
        lists[status] = entries
    end
    return lists
end

-- Moves the card's drawn position towards its place
function Frame:animate(id, tx, ty, dt)
    local a = self.anim[id]
    if a == nil then
        a = { x = tx, y = ty }
        self.anim[id] = a
        return a
    end
    local k = 1 - math.exp(-dt / Frame.SLIDE_TAU_MS)
    a.x = a.x + (tx - a.x) * k
    a.y = a.y + (ty - a.y) * k
    if math.abs(tx - a.x) < px(0.5) then
        a.x = tx
    end
    if math.abs(ty - a.y) < py(0.5) then
        a.y = ty
    end
    return a
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function Frame:draw(...)
    Frame:superClass().draw(self, ...)

    local area = self:getBoardArea()
    if area == nil then
        return
    end
    local time = now()
    local dt = 0
    if self.lastTime ~= nil then
        dt = math.max(0, math.min(100, time - self.lastTime))
    end
    self.lastTime = time

    local state = self.state
    self.canManage = FarmTaskBoard:canManage()
    local board = self:getBoard()

    -- The board may have changed under the player (sync from the server)
    if not self.canManage and (self.drag ~= nil or self.pending ~= nil or self.dialog ~= nil) then
        self:resetInteraction()
    end
    if self.drag ~= nil and D.getTask(board, self.drag.id) == nil then
        self.drag = nil
    end
    if self.dialog ~= nil and self.dialog.taskId ~= nil and D.getTask(board, self.dialog.taskId) == nil then
        self:closeDialog()
    end

    UI.begin(state)
    local L = self:computeLayout(area)
    self.layout = L
    if self.drag ~= nil then
        self:updateDragTarget(L, board)
    end
    local lists = self:buildColumns(board)

    -- No hover effects on the board under the dialog or while a card is dragged
    local mouseX, mouseY = state.mouseX, state.mouseY
    if self.dialog ~= nil or self.drag ~= nil then
        state.mouseX, state.mouseY = nil, nil
    end
    -- The engine draws all text after all rectangles, so the board's text would show through
    -- the dialog. Under the dialog it is left out; elsewhere it is dimmed like the shade.
    if self.dialog ~= nil then
        local dx, dy, dw, dh = self:getDialogRect(L, board)
        UI.setTextMask(dx, dy, dw, dh, 1 - UI.C.modalShade[4])
    end
    self.cards = {}
    self:drawColumns(L, lists, board, dt)
    self:drawToolbar(L, board)
    self:drawFooter(L)
    UI.clearTextMask()
    state.mouseX, state.mouseY = mouseX, mouseY

    self:drawGhost(board, dt)
    if self.dialog ~= nil then
        self:drawDialog(L, board)
    end
    UI.drawTooltip(state)
    UI.finish()

    -- The text field is drawn once more on top of the dialog
    if self.dialog ~= nil and self.taskTextInput ~= nil then
        self.taskTextInput:draw()
    end
end

function Frame:drawToolbar(L, board)
    local state = self.state
    local tb = L.toolbar
    UI.rect(tb.x, tb.y, tb.w, tb.h, UI.C.toolbar)
    UI.rect(tb.x, tb.y, tb.w, py(2), UI.C.green)

    local buttonH = py(38)
    local buttonY = tb.y + (tb.h - buttonH) * 0.5
    if self.canManage then
        local full = #board.tasks >= D.MAX_TASKS
        local label = t("ftb_new")
        local size = py(15)
        local w = UI.textWidth(size, label, true) + px(40)
        local tooltip = nil
        if full then
            tooltip = string.format(t("ftb_boardFull"), D.MAX_TASKS)
        end
        UI.button(state, tb.x + px(16), buttonY, w, buttonH, label, {
            bg = UI.C.green, fg = UI.C.dark, bold = true, size = size, disabled = full,
            onClick = function() self:openDialog(nil) end, tooltip = tooltip, id = "new",
        })
    end

    local text, bg, line, fg
    if FarmTaskBoard:isSpectator() then
        text, bg, line, fg = t("ftb_role_spectator"), UI.C.viewBg, UI.C.buttonLine, UI.C.viewText
    elseif self.canManage then
        text, bg, line, fg = string.format(t("ftb_role_manager"), FarmTaskBoard:getPlayerName()), UI.C.roleBg, UI.C.roleLine, UI.C.roleText
    else
        text, bg, line, fg = string.format(t("ftb_role_viewer"), FarmTaskBoard:getPlayerName()), UI.C.viewBg, UI.C.buttonLine, UI.C.viewText
    end
    local size = py(14)
    text = UI.fit(text, size, tb.w * 0.5)
    local w = UI.textWidth(size, text) + px(26)
    local h = py(30)
    local x = tb.x + tb.w - px(16) - w
    local y = tb.y + (tb.h - h) * 0.5
    UI.box(x, y, w, h, bg, line)
    UI.textIn(x + w * 0.5, y, h, size, text, fg, "center")
end

function Frame:drawColumns(L, lists, board, dt)
    local drag = self.drag
    for _, status in ipairs(D.STATUSES) do
        local c = L.columns[status]
        local entries = lists[status]
        local over = drag ~= nil and drag.phase ~= "return" and drag.target == status

        UI.box(c.x, c.y, c.w, c.h, over and UI.C.greenFaint or UI.C.column, over and UI.C.green or UI.C.columnLine, over and 2 or 1)

        local maxScroll = math.max(0, #entries - c.visible)
        self.scroll[status] = math.max(0, math.min(maxScroll, self.scroll[status] or 0))
        local scroll = self.scroll[status]

        for k, entry in ipairs(entries) do
            local slot = k - 1 - scroll
            local tx, ty = c.cardX, slotY(c, slot)
            if entry.placeholder then
                if slot >= 0 and slot < c.visible then
                    UI.rect(tx, ty, c.cardW, c.cardH, UI.C.greenFaint)
                    UI.dashed(tx, ty, c.cardW, c.cardH, UI.C.green)
                end
                drag.slotX, drag.slotY = tx, ty
            else
                local a = self:animate(entry.task.id, tx, ty, dt)
                local visible = a.y >= c.listBottom - py(2) and a.y + c.cardH <= c.listTop + py(2)
                if entry.faded then
                    drag.homeX, drag.homeY = tx, ty
                    if visible then
                        self:drawCard(entry.task, a.x, a.y, c.cardW, c.cardH, Frame.SOURCE_ALPHA, 1, false)
                    end
                elseif visible then
                    self:drawCard(entry.task, a.x, a.y, c.cardW, c.cardH, 1, 1, true)
                    table.insert(self.cards, { id = entry.task.id, task = entry.task, x = a.x, y = a.y, w = c.cardW, h = c.cardH })
                end
            end
        end

        -- Header on top of cards sliding in from above
        local headerY = c.y + c.h - c.headerH
        local color = UI.STATUS_COLORS[status]
        UI.rect(c.x, c.y + c.h - py(3), c.w, py(3), color)
        UI.rect(c.x + px(1), headerY, c.w - px(2), py(1), UI.C.columnLine)
        local size = py(15)
        local count = #D.getColumn(board, status)
        UI.textIn(c.x + px(16), headerY, c.headerH - py(3), size, UI.upper(t("ftb_status_" .. status)), UI.C.text, "left", true)
        UI.textIn(c.x + c.w - px(16), headerY, c.headerH - py(3), size, tostring(count), UI.C.muted, "right")

        -- More cards above / below than fit
        local small = py(12)
        if scroll > 0 then
            UI.text(c.x + c.w * 0.5, c.listTop + py(1), small, string.format(t("ftb_more"), scroll), UI.C.muted, "center")
        end
        local below = #entries - scroll - c.visible
        if below > 0 then
            UI.text(c.x + c.w * 0.5, c.y + py(2), small, string.format(t("ftb_more"), below), UI.C.muted, "center")
        end
    end
end

-- One card. alpha and scale for the faded source and the ghost; interactive = the card under
-- the mouse can be hovered and has its Edit button.
function Frame:drawCard(task, x, y, w, h, alpha, scale, interactive)
    if scale ~= nil and scale ~= 1 then
        local nw, nh = w * scale, h * scale
        x, y = x - (nw - w) * 0.5, y - (nh - h) * 0.5
        w, h = nw, nh
    end
    local state = self.state
    local color = UI.STATUS_COLORS[task.status] or UI.C.grey
    UI.box(x, y, w, h, UI.alpha(UI.C.card, alpha), UI.alpha(UI.C.cardLine, alpha))
    UI.rect(x, y, px(4), h, UI.alpha(color, alpha))
    if interactive and self.canManage and UI.isInside(state, x, y, w, h) then
        UI.rect(x, y, w, h, UI.C.hover)
    end

    local size = py(15)
    local number = "#" .. tostring(task.id)
    UI.textIn(x + px(16), y, h, size, number, UI.alpha(UI.C.green, alpha), "left", true)
    local textX = x + px(16) + math.max(px(40), UI.textWidth(size, number, true) + px(12))

    local editW, editH = px(56), py(26)
    local showEdit = interactive and self.canManage
    local right = x + w - px(12)
    if showEdit then
        right = right - editW - px(10)
    end
    local fitted, cut = UI.fit(task.text, size, right - textX)
    local done = task.status == D.STATUS_DONE
    local fg = UI.alpha(done and UI.C.doneText or UI.C.text, alpha)
    UI.textIn(textX, y, h, size, fitted, fg)
    if done then
        -- Struck through
        local baseY = y + (h - size) * 0.5 + size * 0.15
        UI.rect(textX, baseY + size * 0.32, UI.textWidth(size, fitted), py(1), fg)
    end

    if interactive then
        if cut then
            UI.hit(state, x, y, w, h, nil, string.format("#%d %s", task.id, task.text))
        end
        if showEdit then
            UI.button(state, x + w - px(12) - editW, y + (h - editH) * 0.5, editW, editH, t("ftb_edit"), {
                line = UI.C.buttonLine, fg = UI.alpha(UI.C.text, 0.7), size = py(13),
                onClick = function() self:openDialog(task) end, id = "edit:" .. tostring(task.id),
            })
        end
    end
end

function Frame:drawFooter(L)
    local f = L.footer
    local size = py(13)
    UI.rect(f.x, f.y + f.h - py(1), f.w, py(1), UI.C.columnLine)
    local x = f.x + px(16)

    local function hint(key, description)
        local kw = UI.textWidth(size, key) + px(14)
        local kh = py(22)
        local ky = f.y + (f.h - kh) * 0.5
        UI.box(x, ky, kw, kh, UI.C.key, UI.C.buttonLine)
        UI.textIn(x + kw * 0.5, ky, kh, size, key, UI.C.keyText, "center")
        x = x + kw + px(8)
        UI.textIn(x, f.y, f.h, size, description, UI.C.muted)
        x = x + UI.textWidth(size, description) + px(28)
    end

    if self.canManage then
        hint(t("ftb_key_drag"), t("ftb_hint_drag"))
        hint(t("ftb_key_doubleClick"), t("ftb_hint_doubleClick"))
    else
        local text = t("ftb_hint_readOnly")
        UI.textIn(x, f.y, f.h, size, text, UI.C.muted)
        x = x + UI.textWidth(size, text) + px(28)
    end
    hint("Esc", t("ftb_hint_close"))

    if FarmTaskBoard:isMultiplayer() then
        UI.textIn(f.x + f.w - px(16), f.y, f.h, size, t("ftb_synced"), UI.C.muted, "right")
    end
end

---------------------------------------------------------------------------
-- Drag and drop
---------------------------------------------------------------------------

function Frame:startDrag(pending)
    self.pending = nil
    local board = self:getBoard()
    local task = D.getTask(board, pending.id)
    if task == nil then
        return
    end
    local index = 0
    for i, other in ipairs(D.getColumn(board, task.status)) do
        if other == task then
            index = i - 1
        end
    end
    self.drag = {
        id = task.id, phase = "drag",
        srcStatus = task.status, srcIndex = index,
        target = task.status, insert = index,
        grabDX = pending.x - pending.cardX, grabDY = pending.y - pending.cardY,
        w = pending.w, h = pending.h,
        homeX = pending.cardX, homeY = pending.cardY,
        slotX = pending.cardX, slotY = pending.cardY,
        mouseX = pending.x, mouseY = pending.y,
    }
end

-- Column and place under the ghost
function Frame:updateDragTarget(L, board)
    local d = self.drag
    if d.phase ~= "drag" then
        return
    end
    d.target = nil
    for _, status in ipairs(D.STATUSES) do
        if inside(L.columns[status], d.mouseX, d.mouseY) then
            d.target = status
        end
    end
    if d.target == nil then
        return
    end
    local c = L.columns[d.target]
    local count = 0
    for _, task in ipairs(D.getColumn(board, d.target)) do
        if task.id ~= d.id then
            count = count + 1
        end
    end
    local ghostCenter = d.mouseY - d.grabDY + c.cardH * 0.5
    local slot = math.floor((c.listTop - ghostCenter) / c.step)
    local scroll = self.scroll[d.target] or 0
    d.insert = math.max(scroll, math.min(slot + scroll, scroll + c.visible - 1, count))
    d.insert = math.max(0, math.min(d.insert, count))
end

function Frame:getGhostPosition()
    local d = self.drag
    return d.mouseX - d.grabDX, d.mouseY - d.grabDY
end

-- Mouse released while dragging
function Frame:dropDrag()
    local d = self.drag
    if d.target == nil then
        self:cancelDrag()
        return
    end
    d.fromX, d.fromY = self:getGhostPosition()
    d.toX, d.toY = d.slotX, d.slotY
    d.phase = "land"
    d.elapsed = 0
    d.duration = Frame.LAND_MS
end

-- Esc or released outside the columns: the ghost slides back
function Frame:cancelDrag()
    local d = self.drag
    if d == nil or d.phase ~= "drag" then
        return
    end
    d.fromX, d.fromY = self:getGhostPosition()
    d.target = nil
    d.toX, d.toY = d.homeX, d.homeY
    d.phase = "return"
    d.elapsed = 0
    d.duration = Frame.RETURN_MS
end

-- The ghost has arrived: send the move (only if the card really moved)
function Frame:finishDrag()
    local d = self.drag
    self.drag = nil
    if d.phase ~= "land" then
        return
    end
    if d.target == d.srcStatus and d.insert == d.srcIndex then
        return
    end
    self.anim[d.id] = { x = d.toX, y = d.toY }
    S.request({ type = S.OP_MOVE, farmId = FarmTaskBoard:getFarmId(), id = d.id, status = d.target, order = d.insert })
end

function Frame:drawGhost(board, dt)
    local d = self.drag
    if d == nil then
        return
    end
    local task = D.getTask(board, d.id)
    if task == nil then
        self.drag = nil
        return
    end
    local x, y = self:getGhostPosition()
    local scale, alpha = Frame.GHOST_SCALE, Frame.GHOST_ALPHA
    if d.phase ~= "drag" then
        d.elapsed = d.elapsed + dt
        local p = math.min(1, d.elapsed / d.duration)
        if p >= 1 then
            self:finishDrag()
            return
        end
        local e = 1 - (1 - p) * (1 - p) * (1 - p)
        x = d.fromX + (d.toX - d.fromX) * e
        y = d.fromY + (d.toY - d.fromY) * e
        scale = Frame.GHOST_SCALE + (1 - Frame.GHOST_SCALE) * e
        alpha = Frame.GHOST_ALPHA + (1 - Frame.GHOST_ALPHA) * e
    end
    -- The ghost shows the colour of the column it is over
    local shown = { id = task.id, text = task.text, status = d.target or task.status }
    UI.rect(x + px(8), y - py(12), d.w, d.h, UI.C.shadow)
    self:drawCard(shown, x, y, d.w, d.h, alpha, scale, false)
end

---------------------------------------------------------------------------
-- Dialog: create / edit / delete
---------------------------------------------------------------------------

function Frame:getInputText()
    local element = self.taskTextInput
    if element ~= nil and element.getText ~= nil then
        return element:getText() or ""
    end
    return ""
end

-- task = nil: new task
function Frame:openDialog(task)
    if not self.canManage or self.drag ~= nil then
        return
    end
    self.pending = nil
    self.lastClick = nil
    self.dialog = {
        taskId = task ~= nil and task.id or nil,
        status = task ~= nil and task.status or D.STATUS_NOT_STARTED,
        confirmDelete = false,
    }
    -- The mouse-up of the click that opened the dialog must not reach the text field: it would
    -- count as a click outside the field and end typing at once
    self.swallowMouseUp = true
    local element = self.taskTextInput
    if element ~= nil then
        element:setText(task ~= nil and task.text or "")
        element:setVisible(true)
        if FocusManager ~= nil and FocusManager.setFocus ~= nil then
            FocusManager:setFocus(element)
        end
        if element.setForcePressed ~= nil then
            element:setForcePressed(true)
        end
    end
end

function Frame:closeDialog()
    local element = self.taskTextInput
    if element ~= nil then
        if element.setForcePressed ~= nil and self:isTyping() then
            element:setForcePressed(false)
        end
        element:setVisible(false)
    end
    self.dialog = nil
end

function Frame:saveDialog()
    local dialog = self.dialog
    if dialog == nil then
        return
    end
    local text = D.cleanText(self:getInputText())
    if text == "" then
        return
    end
    local farmId = FarmTaskBoard:getFarmId()
    if dialog.taskId == nil then
        S.request({ type = S.OP_CREATE, farmId = farmId, text = text, status = dialog.status })
    else
        S.request({ type = S.OP_UPDATE, farmId = farmId, id = dialog.taskId, text = text, status = dialog.status })
    end
    self:closeDialog()
end

function Frame:deleteDialogTask()
    local dialog = self.dialog
    if dialog == nil or dialog.taskId == nil then
        return
    end
    S.request({ type = S.OP_DELETE, farmId = FarmTaskBoard:getFarmId(), id = dialog.taskId })
    self:closeDialog()
end

-- Text field callbacks (gui/FarmTaskBoardFrame.xml)
function Frame:onTaskTextEnter()
    if self.dialog ~= nil and not self.dialog.confirmDelete then
        self:saveDialog()
    end
end

-- The game also calls this when the player clicks outside the field (mouseClickedOutside = true),
-- e.g. the mouse-up of the double-click that opened the dialog. That only ends typing; only the
-- Esc key cancels the dialog.
function Frame:onTaskTextEsc(element, mouseClickedOutside)
    if mouseClickedOutside == true then
        return
    end
    self.escAt = now()
    if self.dialog ~= nil then
        self:closeDialog()
    end
end

-- Places the game's text field over the dialog's text box
function Frame:placeTextInput(x, y, w, h)
    local element = self.taskTextInput
    if element == nil then
        return
    end
    local pos = element.absPosition
    local size = element.absSize
    local eps = 0.00001
    if size == nil or math.abs(size[1] - w) > eps or math.abs(size[2] - h) > eps then
        if element.setSize ~= nil then
            element:setSize(w, h)
        end
    end
    if pos == nil or math.abs(pos[1] - x) > eps or math.abs(pos[2] - y) > eps then
        if element.setAbsolutePosition ~= nil then
            element:setAbsolutePosition(x, y)
        end
    end
end

-- Size and place of the dialog, and the lines of the delete question (nil when not asked)
function Frame:getDialogRect(L, board)
    local dialog = self.dialog
    local A = L.full
    local w = px(Frame.DIALOG_W)
    local innerW = w - 2 * px(30)

    local confirmLines = nil
    local hpx = 26 + 22 + 22 + 62 + 18 + 62 + 18 + 60 + 26 + 40 + 26
    if dialog.confirmDelete then
        local task = D.getTask(board, dialog.taskId)
        local quoted = task ~= nil and task.text or ""
        if D.utf8Len(quoted) > 60 then
            quoted = D.utf8Prefix(quoted, 60) .. ".."
        end
        confirmLines = UI.wrap(string.format(t("ftb_confirm_delete"), dialog.taskId, quoted), py(14), innerW - px(28), 4)
        hpx = hpx - 40 + (#confirmLines * 20 + 14 + 12 + 34 + 14)
    end
    local h = py(hpx)
    return A.x + (A.w - w) * 0.5, A.y + (A.h - h) * 0.5, w, h, confirmLines
end

function Frame:drawDialog(L, board)
    local state = self.state
    local dialog = self.dialog
    local A = L.full

    -- Shade over the board; clicks there do nothing
    UI.rect(A.x, A.y, A.w, A.h, UI.C.modalShade)
    UI.hit(state, A.x, A.y, A.w, A.h, function() end, nil, "shade")

    local pad = px(30)
    local labelSize = py(12)
    local size = py(15)
    local x, y, w, h, confirmLines = self:getDialogRect(L, board)
    local innerW = w - 2 * pad
    local top = y + h

    UI.box(x, y, w, h, UI.C.dialog, UI.C.dialogLine)
    UI.rect(x, top - py(3), w, py(3), UI.C.green)
    -- Clicks on the dialog's empty parts do nothing either
    UI.hit(state, x, y, w, h, function() end, nil, "dialog")

    local cy = top
    local function take(n)
        cy = cy - py(n)
        return cy
    end
    local left = x + pad

    take(26)
    local titleKey = dialog.taskId ~= nil and "ftb_dialog_edit" or "ftb_dialog_new"
    UI.text(left, take(22) + py(2), py(19), UI.upper(t(titleKey)), UI.C.text, "left", true)
    take(22)

    -- Number (read-only)
    UI.text(left, take(14) + py(1), labelSize, UI.upper(t("ftb_field_number")), UI.C.muted, "left", true)
    take(6)
    local boxY = take(42)
    UI.box(left, boxY, px(120), py(42), UI.C.input, UI.C.inputLine)
    local number = dialog.taskId ~= nil and ("#" .. tostring(dialog.taskId)) or t("ftb_number_new")
    UI.textIn(left + px(12), boxY, py(42), size, number, UI.C.green, "left", true)
    take(18)

    -- Text, with the character counter next to it
    UI.text(left, take(14) + py(1), labelSize, UI.upper(t("ftb_field_text")), UI.C.muted, "left", true)
    take(6)
    local fieldY = take(42)
    local counterW = px(96)
    local fieldW = innerW - counterW
    UI.box(left, fieldY, fieldW, py(42), UI.C.input, UI.C.green)
    self:placeTextInput(left + px(1), fieldY + py(1), fieldW - px(2), py(40))
    UI.hit(state, left, fieldY, fieldW, py(42), UI.PASS, nil, "textField")
    local length = D.utf8Len(self:getInputText())
    local counterColor = UI.C.muted
    if length >= D.MAX_TEXT_LENGTH then
        counterColor = UI.C.danger
    elseif length >= D.MAX_TEXT_LENGTH - 50 then
        counterColor = UI.C.warn
    end
    UI.textIn(left + innerW, fieldY, py(42), py(14), string.format("%d/%d", length, D.MAX_TEXT_LENGTH), counterColor, "right")
    take(18)

    -- Status: three buttons
    UI.text(left, take(14) + py(1), labelSize, UI.upper(t("ftb_field_status")), UI.C.muted, "left", true)
    take(6)
    local segY = take(40)
    local segGap = px(8)
    local segW = (innerW - 2 * segGap) / 3
    for i, status in ipairs(D.STATUSES) do
        local selected = dialog.status == status
        local color = UI.STATUS_COLORS[status]
        UI.button(state, left + (i - 1) * (segW + segGap), segY, segW, py(40), t("ftb_status_" .. status), {
            bg = selected and color or nil, line = selected and color or UI.C.segLine,
            fg = selected and UI.C.dark or UI.C.text, bold = selected, size = py(14),
            onClick = function() dialog.status = status end, id = "status:" .. status,
        })
    end
    take(26)

    local buttonH = py(40)
    if dialog.confirmDelete then
        local boxH = py(#confirmLines * 20 + 14 + 12 + 34 + 14)
        local by = take(#confirmLines * 20 + 14 + 12 + 34 + 14)
        UI.box(left, by, innerW, boxH, UI.C.dangerBg, UI.C.dangerLine)
        local ly = by + boxH - py(14)
        for _, line in ipairs(confirmLines) do
            ly = ly - py(20)
            UI.text(left + px(14), ly + py(5), py(14), line, UI.C.text)
        end
        local bw = px(120)
        UI.button(state, left + innerW - px(14) - bw, by + py(14), bw, py(34), t("ftb_confirm_yes"), {
            bg = UI.C.red, fg = UI.C.white, bold = true, size = py(14),
            onClick = function() self:deleteDialogTask() end, id = "confirmDelete",
        })
        UI.button(state, left + innerW - px(14) - 2 * bw - px(10), by + py(14), bw, py(34), t("ftb_cancel"), {
            line = UI.C.buttonLine, fg = UI.C.text, size = py(14),
            onClick = function() dialog.confirmDelete = false end, id = "cancelDelete",
        })
    else
        local ay = take(40)
        local saveW, cancelW = px(120), px(140)
        local canSave = D.cleanText(self:getInputText()) ~= ""
        UI.button(state, left + innerW - saveW, ay, saveW, buttonH, t("ftb_save"), {
            bg = UI.C.green, fg = UI.C.dark, bold = true, size = py(15), disabled = not canSave,
            onClick = function() self:saveDialog() end, id = "save",
        })
        UI.button(state, left + innerW - saveW - px(10) - cancelW, ay, cancelW, buttonH, t("ftb_cancel"), {
            line = UI.C.buttonLine, fg = UI.C.text, size = py(15),
            onClick = function() self:closeDialog() end, id = "cancel",
        })
        if dialog.taskId ~= nil then
            UI.button(state, left, ay, px(180), buttonH, t("ftb_delete"), {
                line = UI.C.dangerLine, fg = UI.C.danger, bold = true, size = py(15),
                onClick = function() dialog.confirmDelete = true end, id = "delete",
            })
        end
    end
end

---------------------------------------------------------------------------
-- Mouse
---------------------------------------------------------------------------

function Frame:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    local state = self.state
    state.mouseX, state.mouseY = posX, posY
    if not self:getIsVisible() then
        return Frame:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
    end
    local left = button == Input.MOUSE_BUTTON_LEFT

    if self.swallowMouseUp then
        if isUp then
            self.swallowMouseUp = false
            return true
        end
        if isDown then
            self.swallowMouseUp = false
        end
    end

    -- Dragging: the board takes every mouse event
    local d = self.drag
    if d ~= nil then
        if d.phase == "drag" then
            d.mouseX, d.mouseY = posX, posY
            if isUp and left then
                self:dropDrag()
            end
        end
        return true
    end

    -- Button down on a card: a drag starts once the mouse has moved more than 5 px
    local p = self.pending
    if p ~= nil then
        if isUp and left then
            self.pending = nil
            return true
        end
        if math.abs(posX - p.x) > px(Frame.DRAG_START_PX) or math.abs(posY - p.y) > py(Frame.DRAG_START_PX) then
            self:startDrag(p)
            return true
        end
    end

    if not eventUsed and isDown and self.layout ~= nil then
        if left then
            if UI.click(state, posX, posY) then
                return true
            end
            if self.dialog == nil and self.canManage then
                local card = self:cardAt(posX, posY)
                if card ~= nil then
                    local time = now()
                    local last = self.lastClick
                    if last ~= nil and last.id == card.id and time - last.time <= Frame.DOUBLE_CLICK_MS then
                        self:openDialog(card.task)
                        return true
                    end
                    self.lastClick = { id = card.id, time = time }
                    self.pending = { id = card.id, x = posX, y = posY, cardX = card.x, cardY = card.y, w = card.w, h = card.h }
                    return true
                end
            end
        elseif button == Input.MOUSE_BUTTON_WHEEL_UP or button == Input.MOUSE_BUTTON_WHEEL_DOWN then
            if self.dialog == nil then
                local c = self:columnAt(posX, posY)
                if c ~= nil then
                    local direction = button == Input.MOUSE_BUTTON_WHEEL_UP and -1 or 1
                    self.scroll[c.status] = math.max(0, (self.scroll[c.status] or 0) + direction)
                    return true
                end
            end
        end
    end

    return Frame:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
end
