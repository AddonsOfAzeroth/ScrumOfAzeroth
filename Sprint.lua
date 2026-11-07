-- Scrum of Azeroth by DinX: the sprint. Quests in it are a list of quest keys
-- ("id:o" objectives, "id:t" turn-in). Standalone the list lives in our own DB;
-- with CasterKit the bridge swaps the backend so CasterKit's locked route IS
-- the sprint. Custom tickets join the sprint in our own DB in both cases.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local SP = SoA:NewModule("Sprint")
local EMPTY = "0:x"      -- keeps an emptied list from being refilled by CasterKit
local SAMPLE_MAX = 120

local function data()
	local c = SoA.char
	if not c then return {} end
	local s = c.sprint
	if type(s) ~= "table" then s = {} c.sprint = s end
	for _, k in ipairs({ "est", "xp", "done", "titles", "epics", "tickets", "samples" }) do
		if type(s[k]) ~= "table" then s[k] = {} end
	end
	if type(s.goal) ~= "string" then s.goal = "" end
	s.started = num(s.started) or time()
	return s
end
SP.Data = data

---------------------------------------------------------------------------
-- Backends
---------------------------------------------------------------------------
local standalone = {}
function standalone:Kind() return "standalone" end
function standalone:IsActive() return type(SoA.char and SoA.char.sprint) == "table" and type(SoA.char.sprint.keys) == "table" end
function standalone:GetKeys() return SoA.char.sprint and SoA.char.sprint.keys end
function standalone:SetKeys(keys) data().keys = keys end
function standalone:NewSprint()
	local keys = {}
	for _, q in ipairs(SoA.Log:Read()) do
		keys[#keys + 1] = q.id .. (q.ready and ":t" or ":o")
	end
	if #keys == 0 then keys[1] = EMPTY end
	SP:Reset(keys)
end
SP.standalone = standalone
SP.backend = standalone

function SP:Backend() return self.backend or standalone end
function SP:IsActive() return SoA.char ~= nil and self:Backend():IsActive() end

-- questID -> true for every quest in the sprint list
function SP:IDs()
	local ids = {}
	local keys = self:IsActive() and self:Backend():GetKeys()
	if type(keys) == "table" then
		for _, k in ipairs(keys) do
			local id = type(k) == "string" and tonumber(k:match("^(%d+):"))
			if id and id > 0 then ids[id] = true end
		end
	end
	return ids
end

local idCache, idCacheAt = nil, -1
local function ids()
	local t = GetTime()
	if not idCache or t ~= idCacheAt then idCache, idCacheAt = SP:IDs(), t end
	return idCache
end

function SP:Contains(key)
	if not self:IsActive() then return false end
	if type(key) == "number" then return ids()[key] == true and not data().done[key] end
	if type(key) == "string" and key:sub(1, 2) == "t:" then return data().tickets[key] == true end
	return false
end

function SP:DoneList() return self:IsActive() and data().done or {} end
function SP:Title(key) return data().titles[key] end
function SP:Committed(key) return num(data().est[key]) end
function SP:CommittedXP(key) return num(data().xp[key]) end
function SP:EpicKey(key) return data().epics[key] end

local function writeKeys(keys)
	local clean = {}
	for _, k in ipairs(keys) do if k ~= EMPTY then clean[#clean + 1] = k end end
	if #clean == 0 then clean[1] = EMPTY end
	idCache = nil
	SP:Backend():SetKeys(clean)
end

-- Add quests (numbers) and tickets ("t:n") to the sprint.
function SP:AddMany(keys)
	if not self:IsActive() then return false end
	local s = data()
	local list = self:Backend():GetKeys() or {}
	local have = {}
	for _, k in ipairs(list) do have[k] = true end
	local changed = false
	local model = SoA.Model and SoA.Model:Get()
	for _, key in ipairs(keys) do
		if type(key) == "number" then
			local it = model and model.byKey[key]
			local first = key .. ((it and it.ready) and ":t" or ":o")
			local second = key .. ((it and it.ready) and ":o" or ":t")
			if not have[first] then list[#list + 1] = first have[first] = true changed = true end
			if not have[second] then list[#list + 1] = second have[second] = true changed = true end
			s.done[key] = nil
		elseif type(key) == "string" and key:sub(1, 2) == "t:" then
			s.tickets[key] = true
		end
		local it = model and model.byKey[key]
		if it then
			s.est[key], s.xp[key], s.titles[key], s.epics[key] = it.minutes, it.xp, it.title, it.epicKey
		end
	end
	if changed then writeKeys(list) end
	SoA:Fire("SPRINT")
	return true
end

function SP:Add(key) return self:AddMany({ key }) end

function SP:Remove(key)
	local s = data()
	if type(key) == "number" then
		local list = self:Backend():GetKeys()
		if type(list) == "table" then
			local out = {}
			local prefix = key .. ":"
			for _, k in ipairs(list) do
				if type(k) ~= "string" or k:sub(1, #prefix) ~= prefix then out[#out + 1] = k end
			end
			writeKeys(out)
		end
	elseif type(key) == "string" then
		s.tickets[key] = nil
	end
	s.est[key], s.xp[key], s.titles[key], s.epics[key], s.done[key] = nil, nil, nil, nil, nil
	SoA:Fire("SPRINT")
end

function SP:MarkDone(key, title)
	if not self:IsActive() then return end
	local s = data()
	if s.est[key] == nil and not self:Contains(key) then return end
	s.done[key] = time()
	s.titles[key] = s.titles[key] or title
end

function SP:SetGoal(text)
	local s = data()
	s.goal = str(text and strtrim(text)) or ""
	if #s.goal > 80 then s.goal = s.goal:sub(1, 80) end
end

-- New sprint: the old one goes to the review history, burndown and goal start empty.
function SP:Reset(keys)
	local c = SoA.char
	if not c then return end
	local old = c.sprint
	if type(old) == "table" and old.started and SoA.Review then SoA.Review:Store(old, true) end
	c.sprint = nil
	local s = data()
	if keys then s.keys = keys end
	s.startLevel = num(UnitLevel("player"), 1)
	s.startMoney = GetMoney and num((try(GetMoney))) or nil
	s.active, s.combat, s.move, s.deaths, s.xpGained = 0, 0, 0, 0, 0
	idCache = nil
	if SoA.Model then SoA.Model:Dirty() end
	SoA:Fire("SPRINT")
	if old and old.started and SoA.Review and SoA.char.review and SoA.char.review.popup then
		SoA.Review:Show(true)
	end
end

function SP:NewSprint()
	self:Backend():NewSprint()
end

---------------------------------------------------------------------------
-- Sync with the model: snapshot estimates of new members, drop removed ones,
-- sample the burndown. Never fires messages (called while the model builds).
---------------------------------------------------------------------------
function SP:Sync(m)
	if not self:IsActive() then return end
	local s = data()
	local members = {}
	for id in pairs(ids()) do members[id] = true end
	for key in pairs(s.tickets) do members[key] = true end
	for _, it in ipairs(m.items) do
		if members[it.key] and s.est[it.key] == nil then
			s.est[it.key], s.xp[it.key] = it.minutes, it.xp
		end
		if members[it.key] then
			s.titles[it.key], s.epics[it.key] = it.title, it.epicKey
			if (s.xp[it.key] or 0) == 0 and it.xp then s.xp[it.key] = it.xp end
		end
	end
	for key in pairs(s.est) do
		if not members[key] and not s.done[key] then
			s.est[key], s.xp[key], s.titles[key], s.epics[key] = nil, nil, nil, nil
		end
	end
	self:Sample(m)
end

function SP:Status(m)
	if not self:IsActive() then return end
	if m == nil then m = SoA.Model and SoA.Model:Peek() end
	m = m or nil
	local s = data()
	local st = { goal = s.goal, started = s.started, samples = s.samples, items = 0, doneItems = 0,
		committed = 0, delivered = 0, remaining = 0, xpCommitted = 0, xpDelivered = 0, xpRemaining = 0 }
	for key, est in pairs(s.est) do
		st.items = st.items + 1
		st.committed = st.committed + (num(est) or 0)
		st.xpCommitted = st.xpCommitted + (num(s.xp[key]) or 0)
		if s.done[key] then
			st.doneItems = st.doneItems + 1
			st.delivered = st.delivered + (num(est) or 0)
			st.xpDelivered = st.xpDelivered + (num(s.xp[key]) or 0)
		elseif m and m.byKey[key] and m.byKey[key].onHold then
			st.onHold = (st.onHold or 0) + 1 -- paused: not in the remaining work
		else
			local it = m and m.byKey[key]
			st.remaining = st.remaining + ((it and it.minutes) or num(est) or 0)
			st.xpRemaining = st.xpRemaining + ((it and it.xp) or num(s.xp[key]) or 0)
		end
	end
	local cap = SoA.char.capacity
	st.capKind = cap.kind
	if cap.kind == "xp" then
		st.capUsed, st.capTotal = st.xpCommitted, num(cap.xp, 5000)
	else
		st.capUsed, st.capTotal = st.committed, num(cap.minutes, 60)
	end
	return st
end

function SP:Sample(m)
	local s = data()
	local st = self:Status(m)
	if not st then return end
	local last = s.samples[#s.samples]
	local t = time()
	local v = math.floor(st.remaining * 10 + 0.5) / 10
	if last and last.m == v then return end
	if last and t - last.t < 2 then
		last.m, last.t = v, t
		return
	end
	s.samples[#s.samples + 1] = { t = t, m = v }
	while #s.samples > SAMPLE_MAX do table.remove(s.samples, 2) end
end

---------------------------------------------------------------------------
-- Sprint planning: top-priority backlog items that fit the capacity, scaled
-- by the velocity of earlier sprints. Only a proposal until "Accept".
---------------------------------------------------------------------------
function SP:Plan(m)
	m = m or SoA.Model:Get()
	local st = self:Status(m) or { capUsed = 0, capTotal = num(SoA.char.capacity.minutes, 60), capKind = "time" }
	local ratio = SoA.Review and SoA.Review:DeliveryRatio() or nil
	local factor = ratio and math.max(0.5, math.min(1.2, ratio)) or 1
	local budget = st.capTotal * factor - st.capUsed
	local cands = {}
	for _, it in ipairs(m.items) do
		if not it.inSprint and not (it.kind == "ticket" and it.ticket and it.ticket.status == "done") then
			cands[#cands + 1] = it
		end
	end
	table.sort(cands, SoA.Priority.Compare)
	local proposed, skipped, picked = {}, {}, {}
	-- a shared-mob partner of something in the sprint is cheap now
	local function cost(it)
		if st.capKind == "xp" then return it.xp or 0 end
		local sh = it.shared
		if sh and (picked[sh.partnerKey] or self:Contains(sh.partnerKey)) then return sh.extraMin or it.minutes or 0 end
		return it.minutes or 0
	end
	for pass = 1, 2 do
		for _, it in ipairs(cands) do
			if not picked[it.key] then
				if it.onHold and not it.resumeReady then
					if pass == 1 then skipped[#skipped + 1] = { item = it, reason = SoA.L["On hold"] } end
				elseif it.blocked then
					if pass == 1 then skipped[#skipped + 1] = { item = it, reason = it.blockReasons[1] } end
				else
					local c = cost(it)
					if budget > 0 and c <= budget and (pass == 1 or it.shared) then
						proposed[#proposed + 1] = it
						picked[it.key] = true
						budget = budget - c
					end
				end
			end
		end
	end
	return { proposed = proposed, skipped = skipped, factor = factor, ratio = ratio }
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function onTurnedIn(_, questID, xpReward)
	questID = num(questID)
	if not questID then return end
	local m = SoA.Model and SoA.Model:Get()
	local it = m and m.byKey[questID]
	local L = SoA.L
	table.insert(SoA.sessionDone, 1, {
		id = questID, title = (it and it.title) or SoA.Log:Title(questID), xp = (it and it.xp) or num(xpReward),
		minutes = it and it.minutes, epicKey = it and it.epicKey, epicName = it and it.epicName, color = it and it.color, t = time(),
	})
	while #SoA.sessionDone > 50 do table.remove(SoA.sessionDone) end
	if SP:IsActive() and data().est[questID] ~= nil then
		SP:MarkDone(questID, it and it.title)
	end
	if SoA.Log.MarkCompleted then SoA.Log:MarkCompleted(questID) end
	SoA:Fire("SPRINT")
end

-- Abandoned quests leave the sprint (a turned-in quest is flagged completed).
local function onRemoved(_, questID)
	questID = num(questID)
	if not questID then return end
	C_Timer.After(1, function()
		if not SP:IsActive() then return end
		local s = data()
		if s.done[questID] or SoA.Log:IsDone(questID) or SoA.Log:InLog(questID) then return end
		if s.est[questID] ~= nil or ids()[questID] then SP:Remove(questID) end
	end)
end

function SP:OnEnable()
	SoA:On("QUEST_TURNED_IN", onTurnedIn)
	SoA:On("QUEST_REMOVED", onRemoved)
	SoA:On("PLAYER_DEAD", function() if SP:IsActive() then local s = data() s.deaths = num(s.deaths, 0) + 1 end end)
end
