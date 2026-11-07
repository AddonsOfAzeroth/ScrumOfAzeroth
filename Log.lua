-- Scrum of Azeroth by DinX: quest log reader (C_QuestLog, every call guarded)
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local Log = SoA:NewModule("Log")
local QL = C_QuestLog

-- "Red Bandana: 4/15" becomes "4/15 Red Bandana".
local function objectiveText(text)
	if not text then return "" end
	local name, a, b = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)$")
	if name and name ~= "" then return a .. "/" .. b .. " " .. name end
	return text
end

local function readyForTurnIn(id)
	if QL and QL.ReadyForTurnIn and flag(try(QL.ReadyForTurnIn, id)) then return true end
	if QL and QL.IsComplete and flag(try(QL.IsComplete, id)) then return true end
	return false
end
Log.ReadyForTurnIn = readyForTurnIn

local function zoneNames()
	local z = GetZoneText and str(try(GetZoneText))
	local m = SoA:PlayerMap()
	local info = m and C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m)
	return z, type(info) == "table" and str(info.name) or nil
end

-- Objectives as plain tables: text, kind, have, need, done, pct
local function readObjectives(id)
	local out = {}
	local list = QL and QL.GetQuestObjectives and try(QL.GetQuestObjectives, id)
	if type(list) ~= "table" then return out end
	for idx, o in ipairs(list) do
		if type(o) == "table" then
			local kind = str(o.type)
			local e = {
				index = idx, kind = kind, text = objectiveText(str(o.text)),
				have = num(o.numFulfilled), need = num(o.numRequired), done = flag(o.finished),
			}
			if kind == "progressbar" and GetQuestProgressBarPercent then
				e.pct = num((try(GetQuestProgressBarPercent, id)))
			end
			out[#out + 1] = e
		end
	end
	return out
end
Log.ReadObjectives = readObjectives

-- Turn-in location text ("Return to ..."), or the map name of the turn-in.
function Log:TurnInText(id)
	if QL and QL.GetNextWaypointText then
		local t = str(try(QL.GetNextWaypointText, id))
		if t then return t end
	end
	if QL and QL.GetNextWaypoint then
		local m = num((try(QL.GetNextWaypoint, id)))
		local info = m and C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m)
		if type(info) == "table" then return str(info.name) end
	end
end

-- Every quest in the log (headers, hidden quests and bounties skipped).
function Log:Read()
	local out = {}
	if not (QL and QL.GetNumQuestLogEntries and QL.GetInfo) then return out end
	local entries = num((try(QL.GetNumQuestLogEntries)), 0)
	local pl = num(UnitLevel("player"), 1)
	local z1, z2 = zoneNames()
	local header
	for i = 1, math.min(entries, 80) do
		local info = try(QL.GetInfo, i)
		if type(info) == "table" then
			local title = str(info.title)
			if flag(info.isHeader) then
				header = title
			elseif not flag(info.isHidden) and not flag(info.isBounty) then
				local id = num(info.questID)
				if id and title then
					local level = num(info.difficultyLevel, 0)
					if level <= 0 then level = num(info.level, 0) end
					if level <= 0 then level = pl end
					local q = {
						id = id, index = i, title = title, level = level,
						showLevel = num(info.level, 0) > 0 and num(info.level, 0) or level,
						group = num(info.suggestedGroup, 0),
						zone = (header ~= nil and (header == z1 or header == z2)) or flag(info.isOnMap),
					}
					q.ready = readyForTurnIn(id)
					q.failed = QL.IsFailed and flag(try(QL.IsFailed, id)) or false
					if QL.GetQuestTagInfo then
						local tag = try(QL.GetQuestTagInfo, id)
						q.elite = type(tag) == "table" and flag(tag.isElite) or false
						q.tagName = type(tag) == "table" and str(tag.tagName) or nil -- Dungeon, Raid, World Quest ...
					end
					-- dailies / weeklies (Enum.QuestFrequency: 0 default, 1 daily, 2 weekly)
					local freq = num(info.frequency, 0)
					if freq == 1 then q.tagName = (q.tagName and q.tagName .. ", " or "") .. SoA.L["Daily"]
					elseif freq == 2 then q.tagName = (q.tagName and q.tagName .. ", " or "") .. SoA.L["Weekly"] end
					q.objectives = readObjectives(id)
					local progress = false
					for _, o in ipairs(q.objectives) do
						if o.done or (o.have and o.have > 0) or (o.pct and o.pct > 0) then progress = true end
					end
					q.progress = progress
					out[#out + 1] = q
				end
			end
		end
	end
	return out
end

function Log:InLog(id)
	if not (QL and QL.GetLogIndexForQuestID) then return nil end
	local i = num(try(QL.GetLogIndexForQuestID, id))
	return i ~= nil and i > 0
end

-- Completed quests from the history import (C_QuestLog.GetAllCompletedQuestIDs).
Log.completed = nil

function Log:ImportCompleted()
	if not (QL and QL.GetAllCompletedQuestIDs) then return nil end
	local list = try(QL.GetAllCompletedQuestIDs)
	if type(list) ~= "table" then return nil end
	local set, n = {}, 0
	for _, id in ipairs(list) do
		id = num(id)
		if id then set[id] = true n = n + 1 end
	end
	self.completed = set
	return n
end

function Log:MarkCompleted(id)
	if self.completed and id then self.completed[id] = true end
end

function Log:IsDone(id)
	if self.completed and self.completed[id] then return true end
	if QL and QL.IsQuestFlaggedCompleted then return flag(try(QL.IsQuestFlaggedCompleted, id)) end
	if IsQuestFlaggedCompleted then return flag(try(IsQuestFlaggedCompleted, id)) end
	return false
end

local requested = {}
function Log:Title(id)
	local t = QL and QL.GetTitleForQuestID and str(try(QL.GetTitleForQuestID, id))
	if not t and QuestUtils_GetQuestName then t = str(try(QuestUtils_GetQuestName, id)) end
	if not t and QL and QL.RequestLoadQuestByID and not requested[id] then
		requested[id] = true
		try(QL.RequestLoadQuestByID, id) -- the name arrives with QUEST_DATA_LOAD_RESULT
	end
	return t
end

function Log:RewardXP(id)
	if GetQuestLogRewardXP then return num((try(GetQuestLogRewardXP, id))) end
end

-- Quest difficulty: "grey", "green", "yellow", "orange", "red"
function Log:Difficulty(level)
	local pl = num(UnitLevel("player"), 1)
	local d = level - pl
	if d >= 5 then return "red" elseif d >= 3 then return "orange" elseif d >= -2 then return "yellow" end
	local grey
	if pl <= 5 then grey = 0 elseif pl <= 39 then grey = pl - 5 - math.floor(pl / 10) else grey = pl - 1 - math.floor(pl / 5) end
	if GetQuestDifficultyColor and QuestDifficultyColors and QuestDifficultyColors.trivial then
		local c = try(GetQuestDifficultyColor, level)
		if c and c == QuestDifficultyColors.trivial then return "grey" end
	end
	if level <= grey then return "grey" end
	return "green"
end

function Log:LevelColor(level)
	local fn = GetQuestDifficultyColor or GetCreatureDifficultyColor
	local c = fn and try(fn, level)
	if type(c) == "table" and c.r then return c.r, c.g, c.b end
	return 1, 0.82, 0
end
