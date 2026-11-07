-- Scrum of Azeroth by DinX: effort estimates in minutes ("story points").
-- Estimate = walking + work per objective + turn-in walk. Rates are learned from
-- the player's own play, using only PLAYER_REGEN_*, quest log events and
-- C_QuestLog objectives. No combat log, no unit health, no drop database.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local Est = SoA:NewModule("Estimate")

-- Defaults until learned
Est.KILL = 25         -- s per kill (fight + downtime)
Est.DOWNTIME = 8      -- s eat/drink/loot added to each fight
Est.DROP = 0.40       -- mob drop chance
Est.OBJECT = 20       -- s per click / event step
Est.PCT = 6           -- s per percent of a progress bar
Est.SPEED = 7         -- yd/s on foot
Est.DETOUR = 1.3      -- straight line -> real path
Est.TURNIN_WALK = 120 -- s from the objective area to the turn-in (not known in advance)
Est.TURNIN = 10       -- s to talk to the quest giver
Est.UNKNOWN_WALK = 150 -- s when no position is known
Est.LEARNED_N = 5     -- samples before a rate counts as learned
local ALPHA = 0.2
local NEAR_YD = 500

local function db()
	local c = SoA.char
	if not c then return { kill = { n = 0 }, object = { n = 0 }, pct = { n = 0 }, drops = {} } end
	local l = c.learn
	if type(l) ~= "table" then l = {} c.learn = l end
	for _, k in ipairs({ "kill", "object", "pct" }) do
		if type(l[k]) ~= "table" then l[k] = { n = 0 } end
	end
	if type(l.drops) ~= "table" then l.drops = {} end
	return l
end

local function ema(rec, sample, lo, hi)
	if sample < lo or sample > hi then return end
	rec.avg = rec.avg and (rec.avg + (sample - rec.avg) * ALPHA) or sample
	rec.n = (rec.n or 0) + 1
end

function Est:Reset()
	if SoA.char then SoA.char.learn = nil end
	db()
	SoA:Fire("ESTIMATES")
end

function Est:KillTime()
	local k = db().kill
	return num(k.avg, self.KILL), num(k.n, 0)
end

function Est:ObjectTime()
	local o = db().object
	return num(o.avg, self.OBJECT), num(o.n, 0)
end

function Est:PctTime()
	local p = db().pct
	return num(p.avg, self.PCT), num(p.n, 0)
end

function Est:Speed()
	return num(db().speed, self.SPEED)
end

-- Learned drop chance of one objective, shrunk toward the default until
-- there are enough encounters: (drops + K*default) / (encounters + K).
function Est:DropRate(questID, index)
	local d = db().drops[questID .. ":" .. index]
	local K = self.LEARNED_N
	if type(d) ~= "table" then return self.DROP, 0 end
	local enc, drops = num(d.enc, 0), num(d.drops, 0)
	local r = (drops + K * self.DROP) / (enc + K)
	return math.max(0.05, math.min(1, r)), enc
end

-- Same, looked up by objective text (for CasterKit's planner via the bridge).
local function textKey(text)
	if type(text) ~= "string" then return end
	local k = text:gsub("%d+%s*/%s*%d+", ""):gsub("[:%(%)]", ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
	if k ~= "" then return k end
end
Est.TextKey = textKey

function Est:DropRateByText(text)
	local key = textKey(text)
	if not key then return end
	for id, d in pairs(db().drops) do
		if type(d) == "table" and d.text == key and num(d.enc, 0) >= self.LEARNED_N then
			local q, i = id:match("^(%d+):(%d+)$")
			if q then return (self:DropRate(tonumber(q), tonumber(i))) end
		end
	end
end

-- Range factor from the number of samples: wide with defaults, narrow when learned.
local function range(n)
	local t = math.min(1, (n or 0) / Est.LEARNED_N)
	return 0.6 + 0.2 * t, 1.7 - 0.45 * t
end

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------
local function worldPos(m, x, y)
	if not (m and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
	local vec = try(CreateVector2D, x, y)
	if not vec then return end
	local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, m, vec)
	if not ok or type(pos) ~= "table" or not pos.GetXY then return end
	local ok2, wx, wy = pcall(pos.GetXY, pos)
	if not ok2 then return end
	return num(cont), num(wx), num(wy)
end

local function playerWorld()
	local m = SoA:PlayerMap()
	if not (m and C_Map.GetPlayerMapPosition) then return end
	local pos = try(C_Map.GetPlayerMapPosition, m, "player")
	if type(pos) ~= "table" or not pos.GetXY then return end
	local ok, x, y = pcall(pos.GetXY, pos)
	if not ok then return end
	x, y = num(x), num(y)
	if not (x and y) then return end
	return worldPos(m, x, y)
end

local function questSpot(questID)
	local QL = C_QuestLog
	if QL and QL.GetNextWaypoint then
		local m, x, y = try(QL.GetNextWaypoint, questID)
		m, x, y = num(m), num(x), num(y)
		if m and m > 0 and x and y then return m, x, y end
	end
	local pm = SoA:PlayerMap()
	local qm = GetQuestUiMapID and num((try(GetQuestUiMapID, questID, true)))
	for _, m in ipairs({ pm or 0, qm or 0 }) do
		if m > 0 and QL and QL.GetQuestsOnMap then
			local pins = try(QL.GetQuestsOnMap, m)
			if type(pins) == "table" then
				for _, p in ipairs(pins) do
					if type(p) == "table" and num(p.questID) == questID and num(p.x) and num(p.y) then return m, p.x, p.y end
				end
			end
		end
		if m > 0 and C_TaskQuest and C_TaskQuest.GetQuestLocation then
			local x, y = try(C_TaskQuest.GetQuestLocation, questID, m)
			x, y = num(x), num(y)
			if x and y then return m, x, y end
		end
	end
end
Est.QuestSpot = questSpot

-- Straight-line yards from the player to the quest's next spot, or nil.
function Est:Distance(questID)
	local QL = C_QuestLog
	if QL and QL.GetDistanceSqToQuest then
		local d2, onCont = try(QL.GetDistanceSqToQuest, questID)
		d2 = num(d2)
		if d2 and d2 >= 0 and flag(onCont) then return math.sqrt(d2) end
	end
	local m, x, y = questSpot(questID)
	if not m then return end
	local c1, x1, y1 = worldPos(m, x, y)
	local c2, x2, y2 = playerWorld()
	if c1 and c2 and c1 == c2 and x1 and x2 then
		return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
	end
end

---------------------------------------------------------------------------
-- The estimate
---------------------------------------------------------------------------
-- q: a quest from Log:Read(). distance: yards from CasterKit's planner, else measured.
-- Returns { minutes, low, high, learned, parts = { text, ... } }
function Est:Quest(q, distance)
	local L, S = SoA.L, SoA.Style
	local secs, lo, hi = 0, 0, 0
	local parts = {}
	local allLearned = true
	local function add(s, n)
		local a, b = range(n)
		secs, lo, hi = secs + s, lo + s * a, hi + s * b
		if (n or 0) < self.LEARNED_N then allLearned = false end
	end

	-- walking
	local d = num(distance) or self:Distance(q.id)
	local speed = self:Speed()
	if d then
		local w = d * self.DETOUR / speed
		local a, b = 0.8, 1.4
		secs, lo, hi = secs + w, lo + w * a, hi + w * b
		parts[#parts + 1] = L["Walk %s"]:format(S:Minutes(w / 60))
	else
		local w = self.UNKNOWN_WALK
		secs, lo, hi = secs + w, lo + w * 0.4, hi + w * 2.5
		parts[#parts + 1] = L["Walk ?"]
	end

	if q.ready then
		secs, lo, hi = secs + self.TURNIN, lo + self.TURNIN, hi + self.TURNIN * 2
	else
		local kt, kn = self:KillTime()
		-- this quest's own fights (Activity.lua), once there are a few
		local Act = SoA.Activity
		if Act and Act:Enabled() then
			local qkt, qn = Act:KillTimeFor(q.id)
			if qkt and qn >= 3 then kt, kn = qkt, math.max(kn, qn) end
		end
		for _, o in ipairs(q.objectives or {}) do
			if not o.done then
				local rem
				if o.need and o.need > 0 then rem = math.max(0, o.need - (o.have or 0)) else rem = 1 end
				if o.kind == "monster" then
					add(rem * kt, kn)
					parts[#parts + 1] = L["%d kills x %ds"]:format(rem, kt + 0.5)
				elseif o.kind == "item" then
					local rate, enc = self:DropRate(q.id, o.index)
					local kills = rem / rate
					add(kills * kt, math.min(kn, enc))
					parts[#parts + 1] = L["%d drops @ %d%% = %d kills"]:format(rem, rate * 100 + 0.5, math.ceil(kills))
				elseif o.kind == "progressbar" then
					local pt, pn = self:PctTime()
					local left = 100 - math.max(0, math.min(100, o.pct or 0))
					add(left * pt, pn)
					parts[#parts + 1] = L["%d%% x %ds"]:format(left, pt + 0.5)
				else
					local ot, on = self:ObjectTime()
					add(rem * ot, on)
					parts[#parts + 1] = L["%d steps x %ds"]:format(rem, ot + 0.5)
				end
			end
		end
		-- walk on to the turn-in, then hand in
		local w = self.TURNIN_WALK + self.TURNIN
		secs, lo, hi = secs + w, lo + w * 0.5, hi + w * 2
		parts[#parts + 1] = L["turn-in %s"]:format(S:Minutes(w / 60))
	end
	return {
		minutes = secs / 60, low = lo / 60, high = hi / 60,
		learned = allLearned, parts = parts,
	}
end

-- "~14 min (10-20)"
function Est:Format(e)
	local S = SoA.Style
	if not e then return "" end
	local lo, hi = math.floor(e.low + 0.5), math.ceil(e.high)
	return "~" .. S:Minutes(e.minutes) .. " (" .. lo .. "-" .. hi .. ")"
end

---------------------------------------------------------------------------
-- Learning
---------------------------------------------------------------------------
local prev = {}       -- "qid:idx" -> { have, pct, t, kind, quest, done, fresh }
local fightStart
local fightEnd = 0
local fightInc = {}   -- objective increments of the current fight (and 5 s after it)
local SHARED_WINDOW = 5

-- One fight moved a kill objective of one quest and an item objective of
-- another: the same mobs serve both quests (a shared-mob pair).
local function noteIncrement(q, o)
	if not (InCombatLockdown() or GetTime() - fightEnd <= SHARED_WINDOW) then return end
	fightInc[#fightInc + 1] = { quest = q, index = o.index, kind = o.kind }
	local l = db()
	if type(l.shared) ~= "table" then l.shared = {} end
	for _, a in ipairs(fightInc) do
		for _, b in ipairs(fightInc) do
			if a.kind == "monster" and b.kind == "item" and a.quest ~= b.quest then
				local key = a.quest .. ":" .. a.index .. "|" .. b.quest .. ":" .. b.index
				local rec = l.shared[key]
				if type(rec) ~= "table" then
					rec = { a = a.quest, ai = a.index, b = b.quest, bi = b.index, n = 0, t = 0 }
					l.shared[key] = rec
				end
				if rec.t ~= fightEnd then rec.n, rec.t = rec.n + 1, fightEnd end
			end
		end
	end
end

-- Learned pairs: { a = killQuest, ai, b = itemQuest, bi, n }
function Est:SharedPairs()
	local out = {}
	local l = db()
	for _, rec in pairs(type(l.shared) == "table" and l.shared or {}) do
		if type(rec) == "table" and num(rec.a) and num(rec.b) then out[#out + 1] = rec end
	end
	return out
end

local function near(questID)
	local QL = C_QuestLog
	if QL and QL.GetDistanceSqToQuest then
		local d2, onCont = try(QL.GetDistanceSqToQuest, questID)
		d2 = num(d2)
		if d2 then return flag(onCont) and d2 <= NEAR_YD * NEAR_YD end
	end
	local qm = GetQuestUiMapID and num((try(GetQuestUiMapID, questID, true)))
	return qm ~= nil and qm == SoA:PlayerMap()
end
Est.Near = near

-- Compare objectives with the last scan: progress steps teach the rates.
function Est:Scan()
	local l = db()
	local t = GetTime()
	local seen = {}
	for _, q in ipairs(SoA.Log:Read()) do
		for _, o in ipairs(q.objectives) do
			local key = q.id .. ":" .. o.index
			seen[key] = true
			local p = prev[key]
			local have, pct = o.have or 0, o.pct or 0
			if p then
				local delta = have - p.have
				if (delta > 0 or pct > p.pct) and not p.fresh then
					noteIncrement(q.id, o)
					if delta > 0 then
						SoA:Fire("OBJECTIVE", q.id, o.index, o.kind, delta, have, o.need, o.text)
					else
						SoA:Fire("OBJECTIVE", q.id, o.index, o.kind, pct - p.pct, pct, 100, o.text)
					end
				elseif delta < 0 and o.kind == "item" and not p.fresh then
					-- a genuine regression (an item lost)
					SoA:Fire("OBJECTIVE_LOST", q.id, o.index, o.kind, -delta, o.text)
				end
				if o.kind == "item" and delta > 0 then
					local d = l.drops[key]
					if type(d) ~= "table" then d = { enc = 0, drops = 0 } l.drops[key] = d end
					d.drops = num(d.drops, 0) + delta
					d.text = textKey(o.text)
				elseif (o.kind == "object" or o.kind == "event" or o.kind == "log") and delta > 0 and not p.fresh then
					ema(l.object, (t - p.t) / delta, 2, 300)
				elseif o.kind == "progressbar" and pct > p.pct and not p.fresh then
					ema(l.pct, (t - p.t) / (pct - p.pct), 0.5, 120)
				end
				if delta > 0 or pct > p.pct then
					p.t, p.fresh = t, false
				end
				p.have, p.pct, p.done = have, pct, o.done
			else
				prev[key] = { have = have, pct = pct, t = t, kind = o.kind, quest = q.id, done = o.done, fresh = true }
			end
		end
	end
	for key in pairs(prev) do if not seen[key] then prev[key] = nil end end
end

local function onCombatStart()
	fightStart = GetTime()
	wipe(fightInc)
end

local function encounter(key)
	local l = db()
	local d = l.drops[key]
	if type(d) ~= "table" then d = { enc = 0, drops = 0 } l.drops[key] = d end
	d.enc = num(d.enc, 0) + 1
end

-- One drop attempt for every unfinished item objective of a quest close by.
function Est:NoteNearEncounters()
	for key, p in pairs(prev) do
		if p.kind == "item" and not p.done and near(p.quest) then encounter(key) end
	end
end

-- One drop attempt for the unfinished item objectives of one quest (a fight
-- that Activity.lua attributed to it by objective progress or the target).
function Est:NoteEncounter(questID)
	for key, p in pairs(prev) do
		if p.quest == questID and p.kind == "item" and not p.done then encounter(key) end
	end
end

-- Seconds per kill with the measured downtime (from Activity.lua).
function Est:LearnFight(secs)
	secs = num(secs)
	if secs then ema(db().kill, secs, 6, 200) end
end

local function onCombatEnd()
	if not fightStart then return end
	local dur = GetTime() - fightStart
	fightStart = nil
	fightEnd = GetTime()
	-- with activity tracking the kill time uses the measured downtime and drop
	-- attempts go to the quests the fight was attributed to (Activity.lua)
	if SoA.Activity and SoA.Activity:Enabled() then return end
	local l = db()
	if dur >= 2 and dur <= 180 then ema(l.kill, dur + Est.DOWNTIME, 6, 200) end
	Est:NoteNearEncounters()
end

-- Every second: travel speed (out of combat, on the ground or mounted) and time split.
local function tick()
	if not SoA.char then return end
	if InCombatLockdown() then return end
	if UnitOnTaxi and flag(try(UnitOnTaxi, "player")) then return end
	local speed = GetUnitSpeed and num((try(GetUnitSpeed, "player")))
	if speed and speed > 0.5 then
		if speed < 40 then
			local l = db()
			local s = num(l.speed, Est.SPEED)
			l.speed = math.max(4, math.min(30, s + (speed - s) * 0.02))
		end
	end
end

function Est:OnEnable()
	db()
	local function scan() SoA:Throttle("est-scan", 0.5, function() Est:Scan() end) end
	for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_WATCH_UPDATE", "PLAYER_ENTERING_WORLD" }) do
		SoA:On(ev, scan)
	end
	SoA:On("UNIT_QUEST_LOG_CHANGED", function(_, unit)
		if not SoA.IsSecret(unit) and unit == "player" then scan() end
	end)
	SoA:On("PLAYER_REGEN_DISABLED", onCombatStart)
	SoA:On("PLAYER_REGEN_ENABLED", onCombatEnd)
	C_Timer.NewTicker(1, function() SoA.guard("est-tick", tick) end)
end
