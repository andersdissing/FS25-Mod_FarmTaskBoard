"""Smoke test: runs the whole mod (Build/scripts) in Lua against a stubbed FS25 environment.

Not a replacement for testing in the game, but it catches what breaks a mod at runtime: nil
fields, wrong arguments to string.format (the l10n texts are the real ones), errors while drawing,
clicking and dragging, and network streams that are written and read differently.

1. Single player: create, edit, drag (between and within columns, cancelled), delete with
   confirmation, 500-character limit, savegame round trip, then random mouse input for a while.
2. Multiplayer: one server and two clients, each its own Lua runtime running the mod. Events are
   written to a stream on one side and read on the other. The farm manager's changes reach the
   other client; a member who is not farm manager is rejected by the server, also when the
   client is manipulated to send the events anyway.

Usage: python tests/smoke_test.py        Needs: pip install lupa
"""
import os
import random
import re
import sys
import xml.etree.ElementTree as ET

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "Build")

desc = ET.parse(os.path.join(BUILD, "modDesc.xml")).getroot()
l10n_prefix = desc.find("l10n").get("filenamePrefix")
texts = {t.get("name"): t.get("text") for t in ET.parse(os.path.join(BUILD, l10n_prefix + "_da.xml")).getroot().iter("text")}
texts["ui_ingameMenuPrev"] = "Forrige"
texts["ui_ingameMenuNext"] = "Næste"
frame_ids = re.findall(r'\bid="([A-Za-z]+)"', open(os.path.join(BUILD, "gui/FarmTaskBoardFrame.xml"), encoding="utf-8").read())

ENV = r"""
unpack = table.unpack
ERRORS = {}
WARNINGS = {}
RENDERED = {}
g_time = 100000

Logging = {
  info = function(fmt, ...) string.format(fmt, ...) end,
  warning = function(fmt, ...) table.insert(WARNINGS, string.format(fmt, ...)) end,
  error = function(fmt, ...) local m = string.format(fmt, ...) print("ERROR " .. m) table.insert(ERRORS, m) end,
}

g_i18n = { getText = function(self, key)
  local v = TEXTS[key]
  if v == nil then error("missing l10n " .. tostring(key)) end
  return v
end }

g_pixelSizeScaledX = 1 / 1920
g_pixelSizeScaledY = 1 / 1080
RenderText = { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }
Input = { MOUSE_BUTTON_LEFT = 1, MOUSE_BUTTON_WHEEL_UP = 4, MOUSE_BUTTON_WHEEL_DOWN = 5 }
InputAction = { MENU_BACK = 1, MENU_PAGE_PREV = 2, MENU_PAGE_NEXT = 3 }
function drawFilledRect(x, y, w, h, r, g, b, a)
  for _, v in ipairs({ x, y, w, h, r, g, b, a }) do
    if type(v) ~= "number" or v ~= v then error("drawFilledRect with bad value") end
  end
end
function renderText(x, y, size, text)
  if type(text) ~= "string" then error("renderText with " .. type(text)) end
  if type(x) ~= "number" or type(y) ~= "number" or type(size) ~= "number" then error("renderText with bad position") end
  table.insert(RENDERED, text)
end
function setTextColor(r, g, b, a) if a == nil then error("setTextColor needs rgba") end end
function setTextBold(b) end
function setTextAlignment(a) end
function getTextWidth(size, text)
  if type(text) ~= "string" then error("getTextWidth with " .. type(text)) end
  return size * 0.5 * utf8.len(text) * (1080 / 1920)
end

-- Files
FILES = {}
XMLFile = {}
XMLFile.__index = XMLFile
function XMLFile.create(name, path, root) return setmetatable({ path = path, values = {} }, XMLFile) end
function XMLFile.load(name, path)
  local v = FILES[path]
  if v == nil then return nil end
  local copy = {}
  for k, x in pairs(v) do copy[k] = x end
  return setmetatable({ path = path, values = copy }, XMLFile)
end
local function get(self, key, default) local v = self.values[key] if v == nil then return default end return v end
local function set(self, key, v) self.values[key] = v end
XMLFile.getInt, XMLFile.getString = get, get
XMLFile.setInt, XMLFile.setString = set, set
function XMLFile:hasProperty(key)
  for k in pairs(self.values) do
    if k == key or string.sub(k, 1, #key + 1) == key .. "#" or string.sub(k, 1, #key + 1) == key .. "." then return true end
  end
  return false
end
function XMLFile:save() FILES[self.path] = self.values end
function XMLFile:delete() end
function fileExists(path) return FILES[path] ~= nil end

Utils = { appendedFunction = function(f, g) return function(...) f(...) g(...) end end }
FSBaseMission = { saveSavegame = function() end, sendInitialClientState = function() end }
GuiUtils = { getUVs = function() return { 0, 0, 0, 1, 1, 0, 1, 1 } end }
FocusManager = { setFocus = function(self, e) FOCUSED = e end }
function addModEventListener(obj) MOD = obj end

-- Network: events are written to a list of values and read back on the other side
FarmManager = { SPECTATOR_FARM_ID = 0 }
NET_OUT = {}
EVENTS = {}
Event = { new = function(mt) return setmetatable({}, mt) end }
function InitEventClass(class, name) EVENTS[name] = class class.eventName = name end
local W, R, RPOS = nil, nil, 1
local function put(v) table.insert(W, v) end
local function int(v, lo, hi, what)
  if type(v) ~= "number" or math.floor(v) ~= v or v < lo or v > hi then error(what .. " out of range: " .. tostring(v)) end
end
function streamWriteInt32(id, v) int(v, -2147483648, 2147483647, "Int32") put(v) end
function streamWriteUInt8(id, v) int(v, 0, 255, "UInt8") put(v) end
function streamWriteUInt16(id, v) int(v, 0, 65535, "UInt16") put(v) end
function streamWriteString(id, v) if type(v) ~= "string" then error("String expected, got " .. type(v)) end put(v) end
local function take() local v = R[RPOS] RPOS = RPOS + 1 if v == nil then error("read past end of stream") end return v end
streamReadInt32, streamReadUInt8, streamReadUInt16, streamReadString = take, take, take, take
function capture(event, target)
  W = {}
  event:writeStream(1, nil)
  table.insert(NET_OUT, { name = event.eventName, target = target, values = W })
  W = nil
end
function makeConnection(isServer, userId)
  return {
    isServer = isServer, userId = userId,
    getIsServer = function(self) return self.isServer end,
    sendEvent = function(self, event) capture(event, "user:" .. tostring(self.userId)) end,
  }
end
function deliver(name, values, fromServer, userId)
  R, RPOS = values, 1
  local event = EVENTS[name].emptyNew()
  event:readStream(1, makeConnection(fromServer, userId))
  if RPOS ~= #values + 1 then error("stream of " .. name .. " not read to the end") end
  R = nil
end
if IS_SERVER then
  g_server = { broadcastEvent = function(self, event) capture(event, "all") end }
end
g_client = { getServerConnection = function() return { sendEvent = function(self, event) capture(event, "server") end } end }
-- user 1: farm 1 manager, user 2: farm 2 manager, user 3: spectator, user 4: farm 2, not manager
MANAGERS = { [1] = { [1] = true }, [2] = { [2] = true } }
g_farmManager = {
  getFarmById = function(self, farmId)
    return { farmId = farmId, isUserFarmManager = function(farm, userId)
      return MANAGERS[farmId] ~= nil and MANAGERS[farmId][userId] == true
    end }
  end,
}

-- GUI elements
GuiElement = {}
GuiElement.__index = GuiElement
function GuiElement.stub(id)
  return setmetatable({ id = id, elements = {}, visible = true, absPosition = { 0.1, 0.05 }, absSize = { 0.85, 0.75 }, size = { 0.05, 0.03 } }, GuiElement)
end
function GuiElement:setText(t) if type(t) ~= "string" then error("setText " .. type(t)) end self.text = t end
function GuiElement:getText() return self.text or "" end
function GuiElement:setVisible(v) self.visible = v end
function GuiElement:getIsVisible() return self.visible end
function GuiElement:setSize(w, h) if type(w) ~= "number" or type(h) ~= "number" then error("setSize") end self.absSize = { w, h } end
function GuiElement:setAbsolutePosition(x, y) if type(x) ~= "number" or type(y) ~= "number" then error("setAbsolutePosition") end self.absPosition = { x, y } end
function GuiElement:setForcePressed(v) self.forcePressed = v end
function GuiElement:setImageFilename(f) end
function GuiElement:setImageUVs(s, ...) if select("#", ...) ~= 8 then error("setImageUVs needs 8 values") end end
function GuiElement:updateAbsolutePosition() end
function GuiElement:delete() end
function GuiElement:draw() end
function GuiElement:mouseEvent(x, y, isDown, isUp, button, eventUsed) return eventUsed end

function Class(members, baseClass)
  members = members or {}
  if baseClass ~= nil then setmetatable(members, { __index = baseClass }) end
  members.superClass = function() return baseClass end
  return { __index = members }
end
TabbedMenuFrameElement = setmetatable({}, { __index = GuiElement })
function TabbedMenuFrameElement.new(target, mt)
  return setmetatable({ elements = {}, visible = true }, mt)
end
function TabbedMenuFrameElement:onFrameOpen() end
-- Like the game's TextInputElement: a click outside the active field ends typing and calls the
-- field's Esc callback with mouseClickedOutside = true
function TabbedMenuFrameElement:mouseEvent(x, y, isDown, isUp, button, eventUsed)
  local e = self.taskTextInput
  if e ~= nil and e.visible and e.forcePressed and (isDown or isUp) then
    local p, sz = e.absPosition, e.absSize
    local inField = x >= p[1] and x <= p[1] + sz[1] and y >= p[2] and y <= p[2] + sz[2]
    if not inField then
      e.forcePressed = false
      self:onTaskTextEsc(e, true)
    end
  end
  return eventUsed
end
function TabbedMenuFrameElement:onFrameClose() end
function TabbedMenuFrameElement:requestClose(callback) MENU_CLOSED = true return true end
function TabbedMenuFrameElement:setMenuButtonInfo(info)
  for _, b in ipairs(info) do if b.inputAction == nil then error("menu button without action") end end
  self.menuButtonInfo = info
end

g_gui = { frames = {} }
function g_gui:loadGui(file, name, frame)
  for _, id in ipairs(FRAME_IDS) do frame[id] = GuiElement.stub(id) end
  local root = GuiElement.stub("root")
  root.absPosition, root.absSize = { 0.05, 0.08 }, { 0.9, 0.82 }
  frame.headerPanel.absPosition = { 0.05, 0.84 }
  frame.elements[1] = root
  self.frames[name] = frame
end

local pageMap, pageSettings = GuiElement.stub("pageMap"), GuiElement.stub("pageSettings")
g_inGameMenu = {
  pageSettings = pageSettings,
  pageFrames = { pageMap, pageSettings },
  pagingElement = {
    elements = { pageMap, pageSettings },
    pages = { { element = pageMap }, { element = pageSettings } },
    addElement = function(self, e) table.insert(self.elements, e) table.insert(self.pages, { element = e }) end,
    removeElement = function(self, e) end,
    updateAbsolutePosition = function() end,
    updatePageMapping = function() end,
  },
  pageTabs = { [pageMap] = { iconFilename = "map" }, [pageSettings] = { iconFilename = "settings" } },
  enabledPages = { pageMap, pageSettings },
  registerPage = function(self, f) table.insert(self.pageFrames, f) end,
  addPageTab = function(self, f, icon) self.pageTabs[f] = { iconFilename = icon } end,
  rebuildTabList = function(self)
    self.enabledPages = {}
    for _, page in ipairs(self.pageFrames) do table.insert(self.enabledPages, page) end
  end,
  unregisterPage = function() return false end,
  onPagePrevious = function() end,
  onPageNext = function() end,
}

g_currentMission = {
  missionInfo = { savegameDirectory = IS_SERVER and "/savegame1" or nil },
  getFarmId = function() return LOCAL_FARM end,
  playerUserId = USER_ID,
  playerNickname = "Anders",
  missionDynamicInfo = { isMultiplayer = IS_MP },
  userManager = {
    getUserIdByConnection = function(self, connection) return connection.userId end,
    getUserByUserId = function(self, id) return { getNickname = function() return "Spiller " .. tostring(id) end } end,
  },
}

-- Test helpers ------------------------------------------------------------

function F() return FarmTaskBoardFrame.instance end
function frameStep(ms)
  g_time = g_time + (ms or 16)
  RENDERED = {}
  F():draw()
end
function mouse(x, y, down, up, button)
  return F():mouseEvent(x, y, down == true, up == true, button or Input.MOUSE_BUTTON_LEFT, false)
end
function findHit(id)
  for _, h in ipairs(F().state.hits) do if h.id == id then return h end end
  return nil
end
function clickHit(id)
  local h = findHit(id)
  if h == nil then error("no clickable box " .. id) end
  local x, y = h.x + h.w / 2, h.y + h.h / 2
  mouse(x, y, true, false)
  mouse(x, y, false, true)
  frameStep()
end
function cardRect(id)
  for _, c in ipairs(F().cards) do if c.id == id then return c end end
  return nil
end
function column(status) return F().layout.columns[status] end
function board() return FarmTaskBoard:getBoard() end
function columnIds(status)
  local ids = {}
  for _, t in ipairs(FarmTaskBoardData.getColumn(board(), status)) do table.insert(ids, t.id) end
  return table.concat(ids, ",")
end
function rendered(text)
  for _, r in ipairs(RENDERED) do if r == text then return true end end
  return false
end
-- Drags card id to (x, y) and lets the landing animation finish
function dragTo(id, x, y, release)
  local c = cardRect(id)
  if c == nil then error("card not drawn: " .. id) end
  local sx, sy = c.x + c.w * 0.3, c.y + c.h * 0.5
  mouse(sx, sy, true, false)
  frameStep()
  for i = 1, 10 do
    local px, py = sx + (x - sx) * i / 10, sy + (y - sy) * i / 10
    mouse(px, py)
    frameStep()
  end
  if release ~= false then
    mouse(x, y, false, true)
    for _ = 1, 20 do frameStep(20) end
  end
end
function newTask(text, status)
  clickHit("new")
  F().taskTextInput:setText(text)
  if status ~= nil then clickHit("status:" .. status) end
  frameStep()
  clickHit("save")
end
"""


class Failed(Exception):
    pass


def check(cond, what):
    if not cond:
        raise Failed(what)


def make_runtime(is_server, is_mp, farm, user):
    lua = LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.IS_SERVER = is_server
    g.IS_MP = is_mp
    g.LOCAL_FARM = farm
    g.USER_ID = user
    t = lua.table()
    for k, v in texts.items():
        t[k] = v
    g.TEXTS = t
    g.FRAME_IDS = lua.table(*frame_ids)
    lua.execute(ENV)
    g.g_currentModDirectory = BUILD.replace("\\", "/") + "/"
    lua.execute('function source(path) dofile(path) end')
    lua.execute('dofile(g_currentModDirectory .. "scripts/FarmTaskBoard.lua")')
    lua.execute("MOD:loadMap('map.xml')")
    check(g.FarmTaskBoardFrame.instance is not None, "frame installed")
    lua.execute("F():onFrameOpen() frameStep()")
    return lua


def single_player():
    lua = make_runtime(True, False, 1, 1)
    ev = lua.eval
    run = lua.execute

    # Empty board, manager view
    check(ev("#board().tasks") == 0, "new savegame starts empty")
    check(ev("findHit('new') ~= nil"), "+ Ny opgave shown to the farm manager")
    check(ev("rendered('Farm manager · Spiller 1')"), "role badge")

    # Create: numbers 1, 2, 3, 4
    run("newTask('Pløj mark 6+7')")
    check(ev("F().dialog == nil"), "dialog closes on save")
    run("newTask('Høst havre mark 8', 1)")
    run("newTask('Så hvede mark 3,4,5', 2)")
    run("newTask('Kalk mark 23+25 før vintersæd')")
    check(ev("columnIds(0)") == "1,4" and ev("columnIds(1)") == "2" and ev("columnIds(2)") == "3", "create puts tasks last in their column")
    check(ev("rendered('#4')"), "card number drawn")

    # Empty text is not saved
    run("clickHit('new') F().taskTextInput:setText('   ') frameStep()")
    check(ev("findHit('save') == nil"), "Gem disabled for empty text")
    run("clickHit('cancel')")
    check(ev("#board().tasks") == 4 and ev("F().dialog == nil"), "cancel creates nothing")

    # Counter next to the text field, 500 characters
    run("clickHit('new') F().taskTextInput:setText(string.rep('æ', 520)) frameStep()")
    check(ev("rendered('520/500')"), "counter shows characters, not bytes")
    run("clickHit('save')")
    check(ev("FarmTaskBoardData.utf8Len(board().tasks[5].text)") == 500, "text cut to 500 characters")
    check(ev("board().tasks[5].id") == 5, "next number")
    run("clickHit('new') F().taskTextInput:setText('a\\nb') frameStep()")
    check(ev("rendered('3/500')"), "counter")
    run("clickHit('save')")
    check(ev("board().tasks[6].text") == "a b", "line break removed")

    # Edit via the Ret button: text and status, the card goes to the new column
    run("clickHit('edit:1')")
    check(ev("F().dialog.taskId") == 1 and ev("F().taskTextInput:getText()") == "Pløj mark 6+7", "edit dialog filled")
    check(ev("F().taskTextInput.visible") and ev("F().taskTextInput.forcePressed"), "text field shown and active")
    check(ev("rendered('#1')") and ev("rendered('RET OPGAVE')"), "edit dialog drawn")
    run("F().taskTextInput:setText('Pløj mark 6+7 og 8') clickHit('status:1') clickHit('save')")
    check(ev("columnIds(1)") == "2,1" and ev("board().tasks[1].text") == "Pløj mark 6+7 og 8", "edit moves to the end of the new column")

    # Double-click opens the dialog
    run("""
      local c = cardRect(4)
      local x, y = c.x + c.w * 0.4, c.y + c.h * 0.5
      mouse(x, y, true) mouse(x, y, false, true) g_time = g_time + 100 mouse(x, y, true) mouse(x, y, false, true)
      frameStep()
    """)
    check(ev("F().dialog ~= nil and F().dialog.taskId == 4"), "double-click opens the dialog")
    check(ev("F().taskTextInput.forcePressed == true"), "text field still active after the double-click's mouse-up")
    run("local h = findHit('shade') mouse(h.x + 0.001, h.y + 0.001, true) mouse(h.x + 0.001, h.y + 0.001, false, true) frameStep()")
    check(ev("F().dialog ~= nil"), "a click outside the text field does not close the dialog")
    run("clickHit('cancel')")

    # Drag between columns: card 4 to the top of Todo
    run("local c = column(1) dragTo(4, c.x + c.w / 2, c.listTop - 10 / 1080)")
    check(ev("columnIds(1)") == "4,2,1" and ev("columnIds(0)") == "5,6", "drag to the top of another column")
    check(ev("F().drag == nil"), "drag finished")

    # Drag within a column: 4 to the bottom of Todo
    run("local c = column(1) dragTo(4, c.x + c.w / 2, c.listBottom + 20 / 1080)")
    check(ev("columnIds(1)") == "2,1,4", "drag within a column changes only the order")

    # Placeholder and faded source while dragging, then Esc slides it back
    run("local c = column(2) dragTo(2, c.x + c.w / 2, c.listTop - 80 / 1080, false)")
    check(ev("F().drag ~= nil and F().drag.target == 2"), "target column under the mouse")
    check(ev("F():requestClose() == false"), "Esc cancels the drag, not the menu")
    run("for _ = 1, 20 do frameStep(20) end")
    check(ev("F().drag == nil") and ev("columnIds(1)") == "2,1,4", "cancelled drag changes nothing")

    # Released outside the columns: back to where it was
    run("local c = column(0) dragTo(2, c.x + c.w / 2, column(0).y + column(0).h + 30 / 1080)")
    check(ev("columnIds(1)") == "2,1,4", "drop outside a column changes nothing")

    # Delete with confirmation
    run("clickHit('edit:3') clickHit('delete')")
    check(ev("F().dialog.confirmDelete"), "delete asks first")
    check(ev("rendered('Annuller')") and ev("findHit('confirmDelete') ~= nil"), "confirmation drawn")
    run("clickHit('cancelDelete')")
    check(ev("#board().tasks") == 6, "cancel keeps the task")
    run("clickHit('delete') clickHit('confirmDelete')")
    check(ev("FarmTaskBoardData.getTask(board(), 3) == nil") and ev("#board().tasks") == 5, "delete removes one task")
    run("newTask('Ny efter sletning')")
    check(ev("board().tasks[#board().tasks].id") == 7, "numbers are not reused")

    # Esc: closes the dialog first, then the menu
    run("clickHit('new') F().taskTextInput.forcePressed = false")
    check(ev("F():requestClose() == false") and ev("F().dialog == nil"), "Esc closes the dialog")
    run("F():onTaskTextEsc()")
    check(ev("F():requestClose() == false"), "same Esc from the text field does not close the menu")
    run("g_time = g_time + 1000")
    check(ev("F():requestClose() == true"), "Esc closes the menu")

    # Save and load
    run("FSBaseMission.saveSavegame()")
    check(ev("FILES['/savegame1/taskBoard.xml'] ~= nil"), "taskBoard.xml written on save")
    before = ev("columnIds(0) .. '|' .. columnIds(1) .. '|' .. columnIds(2)")
    run("MOD:deleteMap() MOD:loadMap('map.xml') F():onFrameOpen() frameStep()")
    after = ev("columnIds(0) .. '|' .. columnIds(1) .. '|' .. columnIds(2)")
    check(before == after, f"board survives save/load ({before} vs {after})")
    check(ev("board().nextId") == 8, "nextId survives save/load")
    check(ev("#WARNINGS") == 0, "no warnings: " + str(list(ev("WARNINGS").values())))

    # Many tasks: scrolling, more indicator
    run("for i = 1, 30 do newTask('Opgave ' .. i) end")
    check(ev("rendered('+%d flere')") or any(str(v).endswith("flere") for v in ev("RENDERED").values()), "more indicator")
    run("local c = column(0) for _ = 1, 40 do mouse(c.x + c.w / 2, c.y + c.h / 2, true, false, Input.MOUSE_BUTTON_WHEEL_DOWN) end frameStep()")
    check(ev("F().scroll[0]") > 0, "wheel scrolls the column")

    # Random input
    rnd = random.Random(7)
    run("TOTAL_EVENTS = 0")
    for i in range(4000):
        x, y = rnd.uniform(0.04, 0.96), rnd.uniform(0.06, 0.92)
        r = rnd.random()
        if r < 0.3:
            run(f"mouse({x}, {y}, true) mouse({x}, {y}, false, true) frameStep()")
        elif r < 0.5:
            run(f"mouse({x}, {y}, true) frameStep() mouse({x + 0.05}, {y - 0.05}) frameStep() mouse({x + 0.1}, {y - 0.1}, false, true) frameStep(50)")
        elif r < 0.55:
            run(f"if F().dialog ~= nil then F().taskTextInput:setText(string.rep('x', {rnd.randint(0, 600)})) end frameStep()")
        elif r < 0.6:
            run("F():requestClose() frameStep()")
        elif r < 0.65:
            run(f"mouse({x}, {y}, true, false, Input.MOUSE_BUTTON_WHEEL_{'UP' if rnd.random() < 0.5 else 'DOWN'}) frameStep()")
        else:
            run(f"mouse({x}, {y}) frameStep({rnd.randint(1, 60)})")
    for status in (0, 1, 2):
        orders = list(lua.eval(f"(function() local o = {{}} for _, t in ipairs(FarmTaskBoardData.getColumn(board(), {status})) do table.insert(o, t.order) end return o end)()").values())
        check(orders == list(range(len(orders))), f"orders stay 0..n-1 in column {status}: {orders}")
    ids = list(lua.eval("(function() local o = {} for _, t in ipairs(board().tasks) do table.insert(o, t.id) end return o end)()").values())
    check(len(ids) == len(set(ids)), "ids unique")
    check(ev("#ERRORS") == 0, "no errors")
    run("MOD:deleteMap()")
    print("single player OK")


def multiplayer():
    server = make_runtime(True, True, 1, 1)
    manager = make_runtime(False, True, 2, 2)     # farm 2, farm manager
    member = make_runtime(False, True, 2, 4)      # farm 2, not farm manager
    clients = {2: manager, 4: member}

    def carry(rt, values):
        """The stream values of one runtime as a table of another."""
        n = len(values)
        return rt.table_from([values[i] for i in range(1, n + 1)])

    def pump():
        """Delivers every captured event until nothing is left."""
        moved = True
        while moved:
            moved = False
            for user, rt in list(clients.items()):
                out = list(rt.eval("NET_OUT").values())
                rt.execute("NET_OUT = {}")
                for msg in out:
                    check(msg["target"] == "server", "clients only talk to the server")
                    server.globals().deliver(msg["name"], carry(server, msg["values"]), False, user)
                    moved = True
            out = list(server.eval("NET_OUT").values())
            server.execute("NET_OUT = {}")
            for msg in out:
                for user, rt in clients.items():
                    if msg["target"] == "all" or msg["target"] == f"user:{user}":
                        rt.globals().deliver(msg["name"], carry(rt, msg["values"]), True, None)
                        moved = True
            for rt in clients.values():
                rt.execute("frameStep()")

    # Join: the server sends every board
    server.execute("FarmTaskBoardData.createTask(FarmTaskBoardData.getBoard(FarmTaskBoard.data, 2, true), 'Fra serveren', 0)")
    for user, rt in clients.items():
        server.execute(f"FSBaseMission.sendInitialClientState(nil, makeConnection(false, {user}), nil, nil)")
    pump()
    check(member.eval("columnIds(0)") == "1", "joining player sees the board")

    # Member view: read-only
    check(member.eval("findHit('new') == nil") and member.eval("findHit('edit:1') == nil"), "member has no buttons")
    check(member.eval("rendered('Kun visning · Spiller 4 (deltager)')"), "member role badge")
    check(member.eval("rendered('Kun farm manager kan oprette, rette, flytte og slette opgaver')"), "member footer text")
    check(member.eval("rendered('Synkroniseret med alle spillere')"), "synced text in multiplayer")
    member.execute("local c = cardRect(1) mouse(c.x + 0.01, c.y + 0.01, true) mouse(c.x + 0.1, c.y - 0.1) frameStep()")
    check(member.eval("F().drag == nil"), "member cannot drag")

    # Manager creates, edits, moves; the member sees it
    manager.execute("newTask('Pløj mark 6+7', 1)")
    pump()
    check(server.eval("FarmTaskBoardData.getColumn(FarmTaskBoardData.getBoard(FarmTaskBoard.data, 2), 1)[1].id") == 2, "server assigned id 2")
    check(member.eval("columnIds(1)") == "2", "member sees the new task at once")
    manager.execute("local c = column(2) dragTo(2, c.x + c.w / 2, c.listTop - 10 / 1080)")
    check(manager.eval("columnIds(2)") == "2", "manager sees the move at once")
    pump()
    check(member.eval("columnIds(2)") == "2", "member sees the move")
    check(server.eval("#FarmTaskBoardData.getBoard(FarmTaskBoard.data, 1).tasks") == 0, "other farm untouched")

    # Manipulated client: the member sends events anyway
    member.execute("FarmTaskBoardSync.request({ type = FarmTaskBoardSync.OP_DELETE, farmId = 2, id = 1 })")
    member.execute("FarmTaskBoardSync.request({ type = FarmTaskBoardSync.OP_MOVE, farmId = 2, id = 1, status = 2, order = 0 })")
    check(member.eval("columnIds(2)") == "1,2", "client moved the card before the server answered")
    member.execute("FarmTaskBoardSync.request({ type = FarmTaskBoardSync.OP_CREATE, farmId = 2, text = 'Hack', status = 0 })")
    # ... and for another farm
    manager.execute("FarmTaskBoardSync.request({ type = FarmTaskBoardSync.OP_CREATE, farmId = 1, text = 'Hack', status = 0 })")
    pump()
    check(server.eval("#FarmTaskBoardData.getBoard(FarmTaskBoard.data, 2).tasks") == 2, "server rejected the member's changes")
    check(server.eval("#FarmTaskBoardData.getBoard(FarmTaskBoard.data, 1).tasks") == 0, "server rejected a change to another farm")
    check(server.eval("#WARNINGS") == 4, "rejections logged")
    check(member.eval("columnIds(0)") == "1" and member.eval("columnIds(2)") == "2", "rejected move slides back on the client")

    # Concurrent: the manager edits a task the server has deleted meanwhile
    manager.execute("clickHit('edit:1')")
    server.execute("MANAGERS[2][1] = true FarmTaskBoardSync.request({ type = FarmTaskBoardSync.OP_DELETE, farmId = 2, id = 1 })")
    manager.execute("F().taskTextInput:setText('For sent') clickHit('save')")
    pump()
    check(manager.eval("columnIds(0)") == "" and server.eval("#FarmTaskBoardData.getBoard(FarmTaskBoard.data, 2).tasks") == 1, "edit of a deleted task ignored")

    # Dedicated server style save
    server.execute("FSBaseMission.saveSavegame()")
    check(server.eval("FILES['/savegame1/taskBoard.xml'] ~= nil"), "server saves")
    check(manager.eval("FILES['/savegame1/taskBoard.xml'] == nil"), "clients do not save")
    for rt in [server, manager, member]:
        check(rt.eval("#ERRORS") == 0, "no errors")
    print("multiplayer OK")


def spectator():
    rt = make_runtime(True, True, 0, 3)
    check(rt.eval("rendered('Ikke på en farm')"), "spectator badge")
    check(rt.eval("findHit('new') == nil"), "spectator cannot create")
    rt.execute("FSBaseMission.saveSavegame()")
    check(rt.eval("FarmTaskBoard.data.farms[0] == nil"), "no board stored for the spectator farm")
    print("spectator OK")


if __name__ == "__main__":
    try:
        single_player()
        multiplayer()
        spectator()
    except Failed as e:
        print("FAILED:", e)
        sys.exit(1)
    print("OK")
