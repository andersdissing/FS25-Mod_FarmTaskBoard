-- FarmTaskBoard.lua
-- FS25 mod: a task board (to-do list in three columns) per farm, in the in-game menu (Esc) > Tasks.
--
-- The server keeps every farm's board and stores it in <savegame>/taskBoard.xml when the game is
-- saved (FarmTaskBoardData). A new savegame starts with an empty board.
-- Only the farm manager can create, edit, move and delete tasks; everyone on the farm can see them.
-- Every change goes through the server (FarmTaskBoardSync).

local modDirectory = g_currentModDirectory

source(modDirectory .. "scripts/FarmTaskBoardData.lua")
source(modDirectory .. "scripts/FarmTaskBoardSync.lua")
source(modDirectory .. "scripts/FarmTaskBoardUI.lua")
source(modDirectory .. "scripts/FarmTaskBoardFrame.lua")

FarmTaskBoard = {}
FarmTaskBoard.modDirectory = modDirectory
FarmTaskBoard.data = FarmTaskBoardData.new()
-- Goes up whenever a board changes (change applied, sync received, load)
FarmTaskBoard.dataVersion = 0

-- Farm of the local player (1 in single player; 0 = spectator)
function FarmTaskBoard:getFarmId()
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local farmId = g_currentMission:getFarmId()
        if farmId ~= nil then
            return farmId
        end
    end
    return 1
end

-- User id of the local player
function FarmTaskBoard:getUserId()
    if g_currentMission ~= nil then
        return g_currentMission.playerUserId
    end
    return nil
end

function FarmTaskBoard:isMultiplayer()
    return FarmTaskBoardSync.isMultiplayer()
end

function FarmTaskBoard:isSpectator()
    return self:getFarmId() == FarmTaskBoardSync.spectatorFarmId()
end

-- May the local player change the board of their farm?
function FarmTaskBoard:canManage()
    return FarmTaskBoardSync.canManage(self:getFarmId(), self:getUserId())
end

-- Name of the local player for the role badge
function FarmTaskBoard:getPlayerName()
    local mission = g_currentMission
    if mission ~= nil then
        local userManager = mission.userManager
        local userId = self:getUserId()
        if userManager ~= nil and userManager.getUserByUserId ~= nil and userId ~= nil then
            local user = userManager:getUserByUserId(userId)
            if user ~= nil and user.getNickname ~= nil then
                local name = user:getNickname()
                if type(name) == "string" and name ~= "" then
                    return name
                end
            end
        end
        if type(mission.playerNickname) == "string" and mission.playerNickname ~= "" then
            return mission.playerNickname
        end
    end
    return "-"
end

-- Board of the local player's farm
function FarmTaskBoard:getBoard()
    return FarmTaskBoardData.getBoard(self.data, self:getFarmId(), true)
end

function FarmTaskBoard:dataChanged()
    self.dataVersion = self.dataVersion + 1
end

function FarmTaskBoard:getSavePath()
    local mission = g_currentMission
    if mission == nil or mission.missionInfo == nil or mission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return mission.missionInfo.savegameDirectory .. "/" .. FarmTaskBoardData.FILENAME
end

-- Only the server writes the file. A new career has no savegame folder before its first save;
-- the boards then stay in memory until the save hook below runs.
function FarmTaskBoard:save()
    if g_server ~= nil then
        FarmTaskBoardData.saveToFile(self.data, self:getSavePath())
    end
end

---------------------------------------------------------------------------
-- Mod event listener
---------------------------------------------------------------------------

function FarmTaskBoard:loadMap(filename)
    self.data = FarmTaskBoardData.new()
    if g_server ~= nil then
        local path = self:getSavePath()
        local data, count = FarmTaskBoardData.loadFromFile(path)
        self.data = data
        if count > 0 then
            Logging.info("[FarmTaskBoard] Loaded %d tasks from %s", count, tostring(path))
        end
    end
    -- A client's boards come from the server (TaskBoardSyncEvent when it joins)
    self:dataChanged()
    -- A dedicated server has no screen: no menu tab there
    if g_dedicatedServer == nil then
        FarmTaskBoardFrame.install(modDirectory)
    end
end

function FarmTaskBoard:deleteMap()
    FarmTaskBoardFrame.uninstall()
    FarmTaskBoardUI.finish()
    self.data = FarmTaskBoardData.new()
end

-- Write the file with the savegame (also the first save of a new career, which creates the folder)
if FSBaseMission ~= nil and FSBaseMission.saveSavegame ~= nil then
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function(...)
        FarmTaskBoard:save()
    end)
end

addModEventListener(FarmTaskBoard)
