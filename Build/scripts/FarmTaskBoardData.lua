-- FarmTaskBoardData.lua
-- The task boards (one per farm) and the rules for changing them. No GUI and no network here,
-- so tests/test_logic.py can run this file on its own.
--
-- data  = { farms = { [farmId] = board } }
-- board = { nextId = 1, tasks = { task, ... } }
-- task  = { id, text, status, order }
--   id      number per farm, given by the server: nextId, then nextId + 1. Never reused.
--   text    one line, trimmed, at most MAX_TEXT_LENGTH characters (UTF-8 characters, not bytes)
--   status  0 = not started, 1 = to do, 2 = done
--   order   place in the column, 0 = top. Kept as 0, 1, 2, ... without gaps.

FarmTaskBoardData = {}
local D = FarmTaskBoardData

D.MAX_TEXT_LENGTH = 500
-- Keeps the network sync and the columns at a sane size
D.MAX_TASKS = 250

D.STATUS_NOT_STARTED = 0
D.STATUS_TODO = 1
D.STATUS_DONE = 2
D.STATUSES = { 0, 1, 2 }

D.FILENAME = "taskBoard.xml"
D.XML_ROOT = "taskBoard"
D.VERSION = 1

function D.new()
    return { farms = {} }
end

function D.newBoard()
    return { nextId = 1, tasks = {} }
end

function D.getBoard(data, farmId, create)
    local board = data.farms[farmId]
    if board == nil and create then
        board = D.newBoard()
        data.farms[farmId] = board
    end
    return board
end

function D.isValidStatus(status)
    return status == D.STATUS_NOT_STARTED or status == D.STATUS_TODO or status == D.STATUS_DONE
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------

-- Number of UTF-8 characters (æ, ø, å, ä, é ... are two bytes, one character)
function D.utf8Len(s)
    local n = 0
    for i = 1, string.len(s) do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then
            n = n + 1
        end
    end
    return n
end

-- The first n characters of s, never half a character
function D.utf8Prefix(s, n)
    if n <= 0 then
        return ""
    end
    local count = 0
    for i = 1, string.len(s) do
        local b = string.byte(s, i)
        if b < 128 or b >= 192 then
            count = count + 1
            if count == n + 1 then
                return string.sub(s, 1, i - 1)
            end
        end
    end
    return s
end

local function trim(s)
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

-- One line: line breaks and other control characters become spaces, trimmed, at most
-- MAX_TEXT_LENGTH characters. "" means the text is not allowed.
function D.cleanText(text)
    if type(text) ~= "string" then
        return ""
    end
    text = string.gsub(text, "%c", " ")
    text = trim(text)
    if D.utf8Len(text) > D.MAX_TEXT_LENGTH then
        text = trim(D.utf8Prefix(text, D.MAX_TEXT_LENGTH))
    end
    return text
end

---------------------------------------------------------------------------
-- Tasks and columns
---------------------------------------------------------------------------

function D.getTask(board, id)
    for i, task in ipairs(board.tasks) do
        if task.id == id then
            return task, i
        end
    end
    return nil
end

-- The tasks of one column, top first
function D.getColumn(board, status)
    local list = {}
    for _, task in ipairs(board.tasks) do
        if task.status == status then
            table.insert(list, task)
        end
    end
    table.sort(list, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.id < b.id
    end)
    return list
end

local function setOrders(list)
    for i, task in ipairs(list) do
        task.order = i - 1
    end
end

function D.renumber(board, status)
    setOrders(D.getColumn(board, status))
end

function D.renumberAll(board)
    for _, status in ipairs(D.STATUSES) do
        D.renumber(board, status)
    end
end

-- New task last in its column. Returns the task, or nil and the reason.
function D.createTask(board, text, status)
    text = D.cleanText(text)
    if text == "" then
        return nil, "empty text"
    end
    if not D.isValidStatus(status) then
        return nil, "bad status"
    end
    if #board.tasks >= D.MAX_TASKS then
        return nil, "board is full"
    end
    local task = { id = board.nextId, text = text, status = status, order = #D.getColumn(board, status) }
    board.nextId = board.nextId + 1
    table.insert(board.tasks, task)
    return task
end

-- New text and status. A new status puts the task last in that column.
function D.updateTask(board, id, text, status)
    local task = D.getTask(board, id)
    if task == nil then
        return false, "task does not exist"
    end
    text = D.cleanText(text)
    if text == "" then
        return false, "empty text"
    end
    if not D.isValidStatus(status) then
        return false, "bad status"
    end
    task.text = text
    if task.status ~= status then
        local old = task.status
        task.status = status
        task.order = #D.getColumn(board, status) + 1
        D.renumber(board, old)
        D.renumber(board, status)
    end
    return true
end

-- Puts the task in column status at place order (0 = top), counted without the task itself.
function D.moveTask(board, id, status, order)
    local task = D.getTask(board, id)
    if task == nil then
        return false, "task does not exist"
    end
    if not D.isValidStatus(status) then
        return false, "bad status"
    end
    if type(order) ~= "number" or order ~= math.floor(order) or order < 0 then
        return false, "bad order"
    end
    local old = task.status
    local list = {}
    for _, other in ipairs(D.getColumn(board, status)) do
        if other ~= task then
            table.insert(list, other)
        end
    end
    order = math.min(order, #list)
    table.insert(list, order + 1, task)
    task.status = status
    setOrders(list)
    if old ~= status then
        D.renumber(board, old)
    end
    return true
end

function D.deleteTask(board, id)
    local task, index = D.getTask(board, id)
    if task == nil then
        return false, "task does not exist"
    end
    table.remove(board.tasks, index)
    D.renumber(board, task.status)
    return true
end

-- Accepts a task read from a file or a stream if it is valid and its id is free
local function addLoadedTask(board, id, text, status, order)
    text = D.cleanText(text)
    if id == nil or id < 1 or text == "" or not D.isValidStatus(status) or D.getTask(board, id) ~= nil then
        return false
    end
    table.insert(board.tasks, { id = id, text = text, status = status, order = order or 0 })
    if id >= board.nextId then
        board.nextId = id + 1
    end
    return true
end

---------------------------------------------------------------------------
-- Savegame file (server): <savegame>/taskBoard.xml
---------------------------------------------------------------------------

-- Returns data and the number of tasks read. A missing file is an empty board, not an error.
function D.loadFromFile(path)
    local data = D.new()
    if path == nil or not fileExists(path) then
        return data, 0
    end
    local xmlFile = XMLFile.load("farmTaskBoardXML", path)
    if xmlFile == nil then
        return data, 0
    end
    local count = 0
    local i = 0
    while true do
        local key = string.format("%s.farm(%d)", D.XML_ROOT, i)
        if not xmlFile:hasProperty(key) then
            break
        end
        local farmId = xmlFile:getInt(key .. "#id")
        if farmId ~= nil then
            local board = D.getBoard(data, farmId, true)
            board.nextId = math.max(1, xmlFile:getInt(key .. "#nextId", 1))
            local j = 0
            while true do
                local taskKey = string.format("%s.task(%d)", key, j)
                if not xmlFile:hasProperty(taskKey) then
                    break
                end
                local ok = addLoadedTask(board, xmlFile:getInt(taskKey .. "#id"), xmlFile:getString(taskKey .. "#text", ""),
                    xmlFile:getInt(taskKey .. "#status", 0), xmlFile:getInt(taskKey .. "#order", 0))
                if ok then
                    count = count + 1
                end
                j = j + 1
            end
            D.renumberAll(board)
        end
        i = i + 1
    end
    xmlFile:delete()
    return data, count
end

function D.saveToFile(data, path)
    if path == nil then
        return false
    end
    local xmlFile = XMLFile.create("farmTaskBoardXML", path, D.XML_ROOT)
    if xmlFile == nil then
        return false
    end
    xmlFile:setInt(D.XML_ROOT .. "#version", D.VERSION)

    local farmIds = {}
    for farmId in pairs(data.farms) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)

    for f, farmId in ipairs(farmIds) do
        local board = data.farms[farmId]
        local key = string.format("%s.farm(%d)", D.XML_ROOT, f - 1)
        xmlFile:setInt(key .. "#id", farmId)
        xmlFile:setInt(key .. "#nextId", board.nextId)
        local j = 0
        for _, status in ipairs(D.STATUSES) do
            for _, task in ipairs(D.getColumn(board, status)) do
                local taskKey = string.format("%s.task(%d)", key, j)
                xmlFile:setInt(taskKey .. "#id", task.id)
                xmlFile:setInt(taskKey .. "#status", task.status)
                xmlFile:setInt(taskKey .. "#order", task.order)
                xmlFile:setString(taskKey .. "#text", task.text)
                j = j + 1
            end
        end
    end
    xmlFile:save()
    xmlFile:delete()
    return true
end

---------------------------------------------------------------------------
-- Network stream
---------------------------------------------------------------------------

function D.writeBoard(streamId, board)
    streamWriteInt32(streamId, board.nextId)
    streamWriteUInt16(streamId, #board.tasks)
    for _, task in ipairs(board.tasks) do
        streamWriteInt32(streamId, task.id)
        streamWriteUInt8(streamId, task.status)
        streamWriteUInt16(streamId, task.order)
        streamWriteString(streamId, task.text)
    end
end

function D.readBoard(streamId)
    local board = D.newBoard()
    local nextId = streamReadInt32(streamId)
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local id = streamReadInt32(streamId)
        local status = streamReadUInt8(streamId)
        local order = streamReadUInt16(streamId)
        local text = streamReadString(streamId)
        addLoadedTask(board, id, text, status, order)
    end
    board.nextId = math.max(board.nextId, nextId)
    D.renumberAll(board)
    return board
end
