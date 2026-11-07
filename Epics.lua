-- Scrum of Azeroth by DinX: epics = questlines (C_QuestLine), initiatives =
-- campaigns (C_CampaignInfo). Every call is guarded: without these namespaces
-- quests simply have no epic ("Loose tasks") and the board works from the log.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local E = SoA:NewModule("Epics")

local QLINE = C_QuestLine
local CAMP = C_CampaignInfo
local RETRY = 60       -- s before a quest without a line is asked again
local AVAIL_TTL = 30   -- s an available-questline list is reused
local BUMP_WAIT = 1    -- s: quest state changes are merged

-- Stable colours: the same epic gets the same colour in tracker and board.
E.COLORS = {
	{ 0.95, 0.60, 0.25 }, { 0.45, 0.85, 0.45 }, { 0.85, 0.45, 1.00 }, { 1.00, 0.82, 0.25 },
	{ 0.40, 0.70, 1.00 }, { 1.00, 0.45, 0.55 }, { 0.35, 0.90, 0.85 }, { 0.80, 0.80, 0.50 },
}

local lineOf = {}     -- questID -> questLineID / "cp:<campaignID>" key, or false
local missAt = {}     -- questID -> time of the last failed lookup
local epics = {}      -- key -> epic
local gen = 1         -- bumped when quest states change; epics refresh lazily
local availCache = {} -- mapID -> { t, gen, list }
local requestedMap = {}

local function now() return GetTime() end

function E:ColorFor(id)
	id = num(id, 0)
	return self.COLORS[(math.floor(id) % #self.COLORS) + 1]
end

-- Maps worth asking for a quest's line: its own map, the player's map and parents.
local function mapsFor(questID)
	local maps, seen = {}, {}
	local function add(m)
		m = num(m)
		if m and m > 0 and not seen[m] then seen[m] = true maps[#maps + 1] = m end
	end
	if GetQuestUiMapID then add((try(GetQuestUiMapID, questID, true))) end
	local pm = SoA:PlayerMap()
	add(pm)
	local info = pm and C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, pm)
	if type(info) == "table" then add(info.parentMapID) end
	return maps
end

local function lineInfo(questID)
	if not (QLINE and QLINE.GetQuestLineInfo) then return end
	for _, m in ipairs(mapsFor(questID)) do
		local info = try(QLINE.GetQuestLineInfo, questID, m)
		if type(info) == "table" and num(info.questLineID) then return info end
	end
	local info = try(QLINE.GetQuestLineInfo, questID) -- some builds accept no map
	if type(info) == "table" and num(info.questLineID) then return info end
end

-- campaignID, name, chapter name, chapter index, chapter count
local function campaignOf(questID)
	if not (CAMP and CAMP.GetCampaignID) then return end
	local id = num(try(CAMP.GetCampaignID, questID))
	if not id or id <= 0 then return end
	local info = CAMP.GetCampaignInfo and try(CAMP.GetCampaignInfo, id)
	local name = type(info) == "table" and str(info.name) or nil
	local cur = CAMP.GetCurrentChapterID and num(try(CAMP.GetCurrentChapterID, id))
	local chapter
	if cur and CAMP.GetCampaignChapterInfo then
		local ci = try(CAMP.GetCampaignChapterInfo, cur)
		chapter = type(ci) == "table" and str(ci.name) or nil
	end
	local idx, count
	local chapters = CAMP.GetChapterIDs and try(CAMP.GetChapterIDs, id)
	if type(chapters) == "table" then
		count = #chapters
		for i, c in ipairs(chapters) do if num(c) == cur then idx = i end end
	end
	return id, name, chapter, idx, count
end

local function newEpic(key, name, colorID)
	local e = epics[key]
	if e then return e end
	e = { key = key, name = name or "?", color = E:ColorFor(colorID), seen = {}, order = {}, gen = 0 }
	epics[key] = e
	return e
end

local function lookup(questID)
	local info = lineInfo(questID)
	local lid = info and num(info.questLineID)
	local cid, cname, chapter, idx, count = campaignOf(questID)
	local e
	if lid then
		e = newEpic("ql:" .. lid, str(info.questLineName), lid)
		e.lineID = lid
		if flag(info.isCampaign) then e.campaign = true end
	elseif cid then
		-- no questline data, but a campaign: the campaign is the epic
		e = newEpic("cp:" .. cid, cname, cid)
	end
	if not e then return false end
	if cid then
		e.campaign = true
		e.campaignName = cname
		e.chapter = chapter
		e.chapterIndex, e.chapterCount = idx, count
	end
	if not e.seen[questID] then
		e.seen[questID] = true
		e.order[#e.order + 1] = questID
	end
	return e.key
end

-- Steps of a line with state: "done", "ready", "log" or "future".
local function refresh(e)
	if e.gen == gen then return e end
	e.gen = gen
	local Log = SoA.Log
	if e.lineID and not e.ids and QLINE and QLINE.GetQuestLineQuests then
		local list = try(QLINE.GetQuestLineQuests, e.lineID)
		if type(list) == "table" then
			local ids = {}
			for _, v in ipairs(list) do
				local id = num(v) or (type(v) == "table" and num(v.questID)) or nil
				if id then ids[#ids + 1] = id end
			end
			if #ids > 0 then e.ids = ids end
		end
	end
	local ids = e.ids or e.order
	e.steps = {}
	e.done, e.total, e.inLog = 0, #ids, 0
	for i, id in ipairs(ids) do
		local st
		if Log:IsDone(id) then
			st = "done"
			e.done = e.done + 1
		elseif Log:InLog(id) then
			st = Log.ReadyForTurnIn(id) and "ready" or "log"
			e.inLog = e.inLog + 1
		else
			st = "future"
		end
		e.steps[i] = { questID = id, state = st }
	end
	if e.lineID and QLINE and QLINE.IsComplete then
		e.complete = flag(try(QLINE.IsComplete, e.lineID))
	end
	-- tag shown after the name: campaign / chapter
	if e.campaign then
		local L = SoA.L
		if e.chapter and e.chapterIndex and e.chapterCount then
			e.tag = L["Initiative: %s (%d/%d)"]:format(e.chapter, e.chapterIndex, e.chapterCount)
		elseif e.campaignName and e.campaignName ~= e.name then
			e.tag = L["Initiative: %s"]:format(e.campaignName)
		else
			e.tag = L["Initiative"]
		end
	end
	return e
end

-- The epic of a quest, or nil (a "loose task").
function E:Get(questID)
	questID = num(questID)
	if not questID then return end
	local key = lineOf[questID]
	if key == nil or (key == false and now() - (missAt[questID] or 0) > RETRY) then
		key = lookup(questID)
		lineOf[questID] = key
		if not key then missAt[questID] = now() end
	end
	if not key then return end
	return refresh(epics[key])
end

function E:ByKey(key)
	local e = epics[key]
	return e and refresh(e)
end

-- Step after questID in its line (the quest it unlocks), or nil.
function E:NextStep(questID)
	local e = self:Get(questID)
	if not (e and e.steps) then return end
	for i, s in ipairs(e.steps) do
		if s.questID == questID then return e.steps[i + 1], e end
	end
end

-- Questlines that can be picked up on a map (the giver's quest and position).
function E:Available(mapID)
	mapID = num(mapID) or SoA:PlayerMap()
	if not (mapID and QLINE and QLINE.GetAvailableQuestLines) then return {} end
	local c = availCache[mapID]
	if c and c.gen == gen and now() - c.t < AVAIL_TTL then return c.list end
	if QLINE.RequestQuestLinesForMap and now() - (requestedMap[mapID] or -999) > AVAIL_TTL then
		requestedMap[mapID] = now()
		try(QLINE.RequestQuestLinesForMap, mapID) -- answers with QUEST_LINES_UPDATE
	end
	local raw = try(QLINE.GetAvailableQuestLines, mapID)
	local list = {}
	local Log = SoA.Log
	if type(raw) == "table" then
		for _, info in ipairs(raw) do
			if type(info) == "table" then
				local lid, qid = num(info.questLineID), num(info.questID)
				if qid and not Log:InLog(qid) and not Log:IsDone(qid) then
					local key = lid and ("ql:" .. lid) or nil
					if lid then
						local e = newEpic(key, str(info.questLineName), lid)
						e.lineID = lid
						if flag(info.isCampaign) then e.campaign = true end
					end
					list[#list + 1] = {
						questID = qid, questLineID = lid, key = key,
						epicName = str(info.questLineName),
						title = str(info.questName) or Log:Title(qid),
						mapID = mapID, x = num(info.x), y = num(info.y),
						color = lid and E:ColorFor(lid) or nil,
					}
				end
			end
		end
	end
	availCache[mapID] = { t = now(), gen = gen, list = list }
	return list
end

-- Later steps of active epics that are not in the log, not done and not
-- available yet; each with the title of the step before it ("after: ...").
function E:Upcoming(activeKeys, availSet)
	local out = {}
	local Log = SoA.Log
	for key in pairs(activeKeys) do
		local e = self:ByKey(key)
		if e and e.ids then
			local started = false
			for i, s in ipairs(e.steps) do
				if s.state ~= "future" then
					started = true
				elseif started and not (availSet and availSet[s.questID]) then
					local prev = e.steps[i - 1]
					out[#out + 1] = {
						questID = s.questID, key = e.key, epicName = e.name, color = e.color,
						title = Log:Title(s.questID), after = prev and Log:Title(prev.questID), order = i,
					}
					if #out >= 40 then return out end
				end
			end
		end
	end
	return out
end

-- Tooltip with every step of an epic: done / in log / not yet available.
function E:Tooltip(tt, e)
	if not (tt and e) then return false end
	local L, S = SoA.L, SoA.Style
	local c = e.color or S.colors.accent
	tt:SetText(e.name or "?", c[1], c[2], c[3])
	if e.tag then tt:AddLine(e.tag, 0.6, 0.65, 0.71) end
	if e.total and e.total > 0 then
		tt:AddLine(L["%d of %d steps done"]:format(e.done or 0, e.total), 1, 1, 1)
	end
	local shown = 0
	for _, s in ipairs(e.steps or {}) do
		shown = shown + 1
		if shown > 25 then
			tt:AddLine(L["... and %d more"]:format(#e.steps - 25), 0.6, 0.65, 0.71)
			break
		end
		local title = SoA.Log:Title(s.questID) or (L["Quest"] .. " " .. s.questID)
		if s.state == "done" then
			tt:AddDoubleLine("|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t " .. title, L["Done"], 0.45, 0.85, 0.45, 0.45, 0.85, 0.45)
		elseif s.state == "ready" then
			tt:AddDoubleLine("  " .. title, L["Ready to turn in"], 1, 1, 1, 0.3, 0.9, 0.3)
		elseif s.state == "log" then
			tt:AddDoubleLine("  " .. title, L["In your log"], 1, 1, 1, 0.41, 0.8, 0.94)
		else
			tt:AddDoubleLine("  " .. title, L["Not yet available"], 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
		end
	end
	return true
end

-- Quest states changed: refresh epics lazily, merged to once a second.
function E:Bump()
	SoA:Throttle("epics-bump", BUMP_WAIT, function()
		gen = gen + 1
		SoA:Fire("EPICS")
	end)
end

function E:OnEnable()
	for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_DATA_LOAD_RESULT" }) do
		SoA:On(ev, function() E:Bump() end)
	end
	SoA:On("QUEST_LINES_UPDATE", function()
		wipe(availCache)
		for id, key in pairs(lineOf) do if key == false then lineOf[id] = nil end end
		E:Bump()
	end)
	SoA:On("ZONE_CHANGED_NEW_AREA", function() E:Bump() end)
end
