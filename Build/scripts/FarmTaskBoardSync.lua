-- FarmTaskBoardSync.lua
-- Multiplayer: the server owns every farm's board.
--
--   * The menu never changes a board itself; it calls FarmTaskBoardSync.request. On the server
--     (and in single player) the change is applied at once; a client sends it to the server as
--     TaskBoardCreateEvent, TaskBoardUpdateEvent, TaskBoardMoveEvent or TaskBoardDeleteEvent.
--   * The server takes the player from the connection (never from the event) and checks that the
--     player is the farm manager of the farm the board belongs to. Then it checks the change
--     (task exists, text not empty and at most 500 characters, status), applies it and sends the
--     farm's whole board to every client (TaskBoardSyncEvent).
--   * A rejected change is logged; the sender gets the farm's board back, so a card the client
--     already moved slides back to where it was.
--   * A player who joins gets every board (FSBaseMission.sendInitialClientState).
--   * Single player: the player can always change the board.

FarmTaskBoardSync = {}
local S = FarmTaskBoardSync

S.OP_CREATE = 1
S.OP_UPDATE = 2
S.OP_MOVE = 3
S.OP_DELETE = 4

function S.spectatorFarmId()
    if FarmManager ~= nil and FarmManager.SPECTATOR_FARM_ID ~= nil then
        return FarmManager.SPECTATOR_FARM_ID
    end
    return 0
end

function S.isMultiplayer()
    return g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer == true
end

-- True if the user is the farm manager of the farm (FS25 Farm:isUserFarmManager)
function S.isFarmManager(farmId, userId)
    if userId == nil or g_farmManager == nil or g_farmManager.getFarmById == nil then
        return false
    end
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm.isUserFarmManager ~= nil and farm:isUserFarmManager(userId) == true
end

-- True if the user may create, edit, move and delete tasks on the farm's board
function S.canManage(farmId, userId)
    if type(farmId) ~= "number" or farmId == S.spectatorFarmId() then
        return false
    end
    if not S.isMultiplayer() then
        return true
    end
    return S.isFarmManager(farmId, userId)
end

-- Server: user id of the player behind a connection, or nil
function S.getUserIdOfConnection(connection)
    local userManager = g_currentMission ~= nil and g_currentMission.userManager or nil
    if userManager == nil or userManager.getUserIdByConnection == nil then
        return nil
    end
    return userManager:getUserIdByConnection(connection)
end

local function newRequestEvent(op)
    if op.type == S.OP_CREATE then
        return TaskBoardCreateEvent.new(op.farmId, op.text, op.status)
    elseif op.type == S.OP_UPDATE then
        return TaskBoardUpdateEvent.new(op.farmId, op.id, op.text, op.status)
    elseif op.type == S.OP_MOVE then
        return TaskBoardMoveEvent.new(op.farmId, op.id, op.status, op.order)
    elseif op.type == S.OP_DELETE then
        return TaskBoardDeleteEvent.new(op.farmId, op.id)
    end
    return nil
end

-- A change from this machine.
-- op = { type = S.OP_*, farmId, id, text, status, order }
function S.request(op)
    if g_server ~= nil then
        S.apply(op, FarmTaskBoard:getUserId(), nil)
    elseif g_client ~= nil then
        if op.type == S.OP_MOVE then
            -- The card stays where it was dropped; the server's sync confirms it or moves it back
            local board = FarmTaskBoardData.getBoard(FarmTaskBoard.data, op.farmId, false)
            if board ~= nil and FarmTaskBoardData.moveTask(board, op.id, op.status, op.order) then
                FarmTaskBoard:dataChanged()
            end
        end
        local event = newRequestEvent(op)
        if event ~= nil then
            g_client:getServerConnection():sendEvent(event)
        end
    end
end

local function applyToBoard(op, board)
    local D = FarmTaskBoardData
    if op.type == S.OP_CREATE then
        local task, reason = D.createTask(board, op.text, op.status)
        return task ~= nil, reason
    elseif op.type == S.OP_UPDATE then
        return D.updateTask(board, op.id, op.text, op.status)
    elseif op.type == S.OP_MOVE then
        return D.moveTask(board, op.id, op.status, op.order)
    elseif op.type == S.OP_DELETE then
        return D.deleteTask(board, op.id)
    end
    return false, "unknown change"
end

-- Server: applies a change. userId = the player who asked; connection = the sender
-- (nil for the server's own player).
function S.apply(op, userId, connection)
    local ok, reason = false, "only the farm manager can change the task board"
    if S.canManage(op.farmId, userId) then
        local board = FarmTaskBoardData.getBoard(FarmTaskBoard.data, op.farmId, true)
        ok, reason = applyToBoard(op, board)
    end
    if not ok then
        Logging.warning("[FarmTaskBoard] Change rejected (farm %s, user %s): %s", tostring(op.farmId), tostring(userId), tostring(reason))
        if connection ~= nil and type(op.farmId) == "number" then
            connection:sendEvent(TaskBoardSyncEvent.new({ op.farmId }))
        end
        return false
    end
    FarmTaskBoard:dataChanged()
    S.broadcastBoard(op.farmId)
    return true
end

-- Server: one farm's board to every client
function S.broadcastBoard(farmId)
    if g_server ~= nil and g_server.broadcastEvent ~= nil then
        g_server:broadcastEvent(TaskBoardSyncEvent.new({ farmId }))
    end
end

-- Server: what every client -> server event does when it arrives
local function runRequest(op, connection)
    if not connection:getIsServer() then
        S.apply(op, S.getUserIdOfConnection(connection), connection)
    end
end

---------------------------------------------------------------------------
-- Client -> server: TaskBoardCreateEvent(farmId, text, status)
---------------------------------------------------------------------------

TaskBoardCreateEvent = {}
local TaskBoardCreateEvent_mt = Class(TaskBoardCreateEvent, Event)
InitEventClass(TaskBoardCreateEvent, "TaskBoardCreateEvent")

function TaskBoardCreateEvent.emptyNew()
    return Event.new(TaskBoardCreateEvent_mt)
end

function TaskBoardCreateEvent.new(farmId, text, status)
    local self = TaskBoardCreateEvent.emptyNew()
    self.op = { type = S.OP_CREATE, farmId = farmId, text = text, status = status }
    return self
end

function TaskBoardCreateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.op.farmId)
    streamWriteString(streamId, self.op.text)
    streamWriteUInt8(streamId, self.op.status)
end

function TaskBoardCreateEvent:readStream(streamId, connection)
    self.op = { type = S.OP_CREATE }
    self.op.farmId = streamReadInt32(streamId)
    self.op.text = streamReadString(streamId)
    self.op.status = streamReadUInt8(streamId)
    self:run(connection)
end

function TaskBoardCreateEvent:run(connection)
    runRequest(self.op, connection)
end

---------------------------------------------------------------------------
-- Client -> server: TaskBoardUpdateEvent(farmId, id, text, status)
---------------------------------------------------------------------------

TaskBoardUpdateEvent = {}
local TaskBoardUpdateEvent_mt = Class(TaskBoardUpdateEvent, Event)
InitEventClass(TaskBoardUpdateEvent, "TaskBoardUpdateEvent")

function TaskBoardUpdateEvent.emptyNew()
    return Event.new(TaskBoardUpdateEvent_mt)
end

function TaskBoardUpdateEvent.new(farmId, id, text, status)
    local self = TaskBoardUpdateEvent.emptyNew()
    self.op = { type = S.OP_UPDATE, farmId = farmId, id = id, text = text, status = status }
    return self
end

function TaskBoardUpdateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.op.farmId)
    streamWriteInt32(streamId, self.op.id)
    streamWriteString(streamId, self.op.text)
    streamWriteUInt8(streamId, self.op.status)
end

function TaskBoardUpdateEvent:readStream(streamId, connection)
    self.op = { type = S.OP_UPDATE }
    self.op.farmId = streamReadInt32(streamId)
    self.op.id = streamReadInt32(streamId)
    self.op.text = streamReadString(streamId)
    self.op.status = streamReadUInt8(streamId)
    self:run(connection)
end

function TaskBoardUpdateEvent:run(connection)
    runRequest(self.op, connection)
end

---------------------------------------------------------------------------
-- Client -> server: TaskBoardMoveEvent(farmId, id, newStatus, newOrder)
---------------------------------------------------------------------------

TaskBoardMoveEvent = {}
local TaskBoardMoveEvent_mt = Class(TaskBoardMoveEvent, Event)
InitEventClass(TaskBoardMoveEvent, "TaskBoardMoveEvent")

function TaskBoardMoveEvent.emptyNew()
    return Event.new(TaskBoardMoveEvent_mt)
end

function TaskBoardMoveEvent.new(farmId, id, status, order)
    local self = TaskBoardMoveEvent.emptyNew()
    self.op = { type = S.OP_MOVE, farmId = farmId, id = id, status = status, order = order }
    return self
end

function TaskBoardMoveEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.op.farmId)
    streamWriteInt32(streamId, self.op.id)
    streamWriteUInt8(streamId, self.op.status)
    streamWriteUInt16(streamId, self.op.order)
end

function TaskBoardMoveEvent:readStream(streamId, connection)
    self.op = { type = S.OP_MOVE }
    self.op.farmId = streamReadInt32(streamId)
    self.op.id = streamReadInt32(streamId)
    self.op.status = streamReadUInt8(streamId)
    self.op.order = streamReadUInt16(streamId)
    self:run(connection)
end

function TaskBoardMoveEvent:run(connection)
    runRequest(self.op, connection)
end

---------------------------------------------------------------------------
-- Client -> server: TaskBoardDeleteEvent(farmId, id)
---------------------------------------------------------------------------

TaskBoardDeleteEvent = {}
local TaskBoardDeleteEvent_mt = Class(TaskBoardDeleteEvent, Event)
InitEventClass(TaskBoardDeleteEvent, "TaskBoardDeleteEvent")

function TaskBoardDeleteEvent.emptyNew()
    return Event.new(TaskBoardDeleteEvent_mt)
end

function TaskBoardDeleteEvent.new(farmId, id)
    local self = TaskBoardDeleteEvent.emptyNew()
    self.op = { type = S.OP_DELETE, farmId = farmId, id = id }
    return self
end

function TaskBoardDeleteEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.op.farmId)
    streamWriteInt32(streamId, self.op.id)
end

function TaskBoardDeleteEvent:readStream(streamId, connection)
    self.op = { type = S.OP_DELETE }
    self.op.farmId = streamReadInt32(streamId)
    self.op.id = streamReadInt32(streamId)
    self:run(connection)
end

function TaskBoardDeleteEvent:run(connection)
    runRequest(self.op, connection)
end

---------------------------------------------------------------------------
-- Server -> client: TaskBoardSyncEvent(farmIds), the whole board of each farm
---------------------------------------------------------------------------

TaskBoardSyncEvent = {}
local TaskBoardSyncEvent_mt = Class(TaskBoardSyncEvent, Event)
InitEventClass(TaskBoardSyncEvent, "TaskBoardSyncEvent")

function TaskBoardSyncEvent.emptyNew()
    return Event.new(TaskBoardSyncEvent_mt)
end

-- farmIds: list of farm ids, or nil for every farm
function TaskBoardSyncEvent.new(farmIds)
    local self = TaskBoardSyncEvent.emptyNew()
    self.farmIds = farmIds
    return self
end

function TaskBoardSyncEvent:writeStream(streamId, connection)
    local data = FarmTaskBoard.data
    local ids = self.farmIds
    if ids == nil then
        ids = {}
        for farmId in pairs(data.farms) do
            table.insert(ids, farmId)
        end
    end
    streamWriteUInt16(streamId, #ids)
    for _, farmId in ipairs(ids) do
        streamWriteInt32(streamId, farmId)
        FarmTaskBoardData.writeBoard(streamId, FarmTaskBoardData.getBoard(data, farmId, true))
    end
end

function TaskBoardSyncEvent:readStream(streamId, connection)
    self.boards = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local farmId = streamReadInt32(streamId)
        self.boards[farmId] = FarmTaskBoardData.readBoard(streamId)
    end
    self:run(connection)
end

function TaskBoardSyncEvent:run(connection)
    if connection:getIsServer() then
        -- Client: take over the server's boards
        for farmId, board in pairs(self.boards) do
            FarmTaskBoard.data.farms[farmId] = board
        end
        FarmTaskBoard:dataChanged()
    end
end

---------------------------------------------------------------------------
-- Players who join get every board
---------------------------------------------------------------------------

if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil then
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
        function(mission, connection, user, farm)
            if g_server ~= nil and connection ~= nil then
                connection:sendEvent(TaskBoardSyncEvent.new(nil))
            end
        end)
end
