-- Scrum of Azeroth by DinX: activity per ticket and per epic. Fights (duration,
-- damage, healing, XP, money, deaths, downtime), walking and history events.
-- Display only and read-only: fight numbers come from the built-in damage meter
-- (C_DamageMeter, never reset or segmented by us). No combat log is used.
-- Every unit value is checked with issecretvalue before it is used.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try
local issecret = SoA.IsSecret

local Act = SoA:NewModule("Activity")
Act.MAX_FIGHTS = 200     -- detailed fights kept; older ones are folded into per-ticket totals
Act.MAX_WALKS = 200
Act.MAX_EVENTS = 60      -- history events per ticket
Act.MAX_EVENT_KEYS = 150 -- tickets with a history
Act.MAX_MOBS = 400       -- learned mob -> quest links
Act.WINDOW = 5           -- s after combat in which objective increments belong to the fight
Act.METER_TRIES = 4      -- reads of the damage meter while values are still secret
Act.DOWN_MAX = 90        -- s of standing still after a fight that count as downtime
Act.WALK_GAP = 5         -- s standing still that end a walk
Act.WALK_MIN = 5         -- s: shorter walks are not stored
Act.TRAVEL = "travel"
Act.NONE = "none"

local DM = C_DamageMeter

---------------------------------------------------------------------------
-- Saved data (ScrumOfAzerothCharDB.activity)
--   fights  = array of { id, t, dur, dmg, dps, heal, died, xp, money, down, sig, targets, parts = { { key, share, role, kills, drops } } }
--   walks   = array of { id, t, dur, key, kind }   kind: "dest", "turnin", "travel", "taxi"
--   totals  = { [ticketKey] = { fights, shared, dur, down, dmg, heal, xp, money, deaths, kills, drops, dropTries, dpsSum, dpsN, walk, walks } }
--   events  = { [ticketKey] = array of { t, kind, ... } }
--   mobs    = { [mob name, lower case] = { [questID] = count } }
--   firstEstimate = { [ticketKey] = minutes }, epicOf / storyOf = { [ticketKey] = epicKey }
--   lastProgress = { [questID] = time }, lastInZone = { [questID] = time }
---------------------------------------------------------------------------
local TABLES = { "fights", "walks", "totals", "events", "mobs", "firstEstimate", "epicOf", "storyOf", "lastProgress", "lastInZone" }

local function db()
	local c = SoA.char
	if not c then
		local t = { nextId = 1 }
		for _, k in ipairs(TABLES) do t[k] = {} end
		return t
	end
	local a = c.activity
	if type(a) ~= "table" then a = { enabled = true } c.activity = a end
	for _, k in ipairs(TABLES) do
		if type(a[k]) ~= "table" then a[k] = {} end
	end
	a.nextId = num(a.nextId, 1)
	return a
end
Act.Data = db

function Act:Enabled()
	return SoA.char ~= nil and type(SoA.char.activity) == "table" and SoA.char.activity.enabled ~= false
end

function Act:Reset()
	local c = SoA.char
	if not c then return end
	local on = not (type(c.activity) == "table" and c.activity.enabled == false)
	c.activity = { enabled = on }
	db()
	SoA:Fire("ACTIVITY")
	SoA:Fire("MODEL_DIRTY")
end

-- Ticket keys: questID (number), "t:<n>" (custom ticket), "travel", "none".
function Act.NormKey(key)
	if type(key) == "string" then
		local id = tonumber(key:match("^[dau]:(%d+)$") or "")
		if id then return id end
	end
	return key
end

function Act:Title(key)
	local L = SoA.L
	if key == self.TRAVEL then return L["Travel"] end
	if key == self.NONE then return L["Unassigned"] end
	if type(key) == "number" then return SoA.Log:Title(key) or (L["Quest"] .. " " .. key) end
	local t = SoA.Tickets and SoA.Tickets:Get(key)
	return (t and t.title) or tostring(key)
end

---------------------------------------------------------------------------
-- History events
---------------------------------------------------------------------------
local function countKeys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

function Act:Event(key, kind, data)
	key = Act.NormKey(key)
	if key == nil or not SoA.char then return end
	local a = db()
	local list = a.events[key]
	if type(list) ~= "table" then
		list = {}
		a.events[key] = list
		if countKeys(a.events) > self.MAX_EVENT_KEYS then
			-- forget the ticket whose last event is the oldest
			local oldKey, oldT
			for k, l in pairs(a.events) do
				local last = type(l) == "table" and l[#l]
				local t = last and num(last.t, 0) or 0
				if k ~= key and (not oldT or t < oldT) then oldKey, oldT = k, t end
			end
			if oldKey ~= nil then a.events[oldKey] = nil end
		end
	end
	local e = data or {}
	e.kind, e.t = kind, num(e.t) or time()
	-- objective progress of the same objective within a minute: one line
	local last = list[#list]
	if kind == "progress" and last and last.kind == "progress" and last.index == e.index and e.t - num(last.t, 0) < 60 then
		last.have, last.need, last.t = e.have, e.need, e.t
	else
		list[#list + 1] = e
	end
	while #list > self.MAX_EVENTS do table.remove(list, 1) end
	SoA:Fire("ACTIVITY", key)
end

function Act:Events(key)
	local l = db().events[Act.NormKey(key)]
	return type(l) == "table" and l or {}
end

---------------------------------------------------------------------------
-- Totals of trimmed records
---------------------------------------------------------------------------
local FIELDS = { "fights", "shared", "dur", "down", "dmg", "heal", "xp", "money", "deaths", "kills", "drops", "dropTries", "dpsSum", "dpsN", "walk", "walks" }

local function blank()
	local s = {}
	for _, k in ipairs(FIELDS) do s[k] = 0 end
	s.dpsList = {}
	return s
end

local function addFight(s, f, p)
	local w = num(p.share, 1)
	s.fights = s.fights + 1
	if type(f.parts) == "table" and #f.parts > 1 then s.shared = s.shared + 1 end
	s.dur = s.dur + num(f.dur, 0) * w
	s.down = s.down + num(f.down, 0) * w
	s.dmg = s.dmg + num(f.dmg, 0) * w
	s.heal = s.heal + num(f.heal, 0) * w
	s.xp = s.xp + num(f.xp, 0) * w
	s.money = s.money + num(f.money, 0) * w
	if f.died then s.deaths = s.deaths + 1 else s.kills = s.kills + 1 end
	s.drops = s.drops + num(p.drops, 0)
	if p.role == "drop" or p.role == "item" then s.dropTries = s.dropTries + 1 end
	local dps = num(f.dps)
	if dps and dps > 0 then
		s.dpsSum, s.dpsN = s.dpsSum + dps, s.dpsN + 1
		if s.dpsList then s.dpsList[#s.dpsList + 1] = dps end
	end
end

local function foldFight(a, f)
	for _, p in ipairs(type(f.parts) == "table" and f.parts or {}) do
		if p.key ~= nil then
			local t = a.totals[p.key]
			if type(t) ~= "table" then t = blank() t.dpsList = nil a.totals[p.key] = t end
			addFight(t, f, p)
		end
	end
end

local function foldWalk(a, w)
	if w.key == nil then return end
	local t = a.totals[w.key]
	if type(t) ~= "table" then t = blank() t.dpsList = nil a.totals[w.key] = t end
	t.walk = num(t.walk, 0) + num(w.dur, 0)
	t.walks = num(t.walks, 0) + 1
end

local function store(list, rec, max, fold)
	local a = db()
	rec.id = a.nextId
	a.nextId = a.nextId + 1
	list[#list + 1] = rec
	while #list > max do fold(a, table.remove(list, 1)) end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function norm(s)
	if type(s) ~= "string" then return end
	s = s:lower():gsub("%d+%s*/%s*%d+", " "):gsub("%d+%%", " "):gsub("[%p]", " "):gsub("%s+", " ")
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if #s >= 3 then return s end
end
Act.Norm = norm

local function money() return GetMoney and num((try(GetMoney))) or nil end

local function readXP()
	local cur = UnitXP and num((try(UnitXP, "player")))
	local max = UnitXPMax and num((try(UnitXPMax, "player")))
	return cur, max
end

local function inLog(id) return SoA.Log:InLog(id) end

-- quests in the log (read at most once a second)
local logCache, logAt = nil, -1
local function logQuests()
	local t = GetTime()
	if not logCache or t - logAt > 1 then logCache, logAt = SoA.Log:Read(), t end
	return logCache
end

local function questById(id)
	for _, q in ipairs(logQuests()) do if q.id == id then return q end end
end

local function openObjective(q, kind, index)
	for _, o in ipairs(q and q.objectives or {}) do
		if not o.done and (not kind or o.kind == kind) and (not index or o.index == index) then return o end
	end
end

---------------------------------------------------------------------------
-- Where the player is heading (walking) and what they focus on (attribution c)
---------------------------------------------------------------------------
local function routeFirst()
	local B = SoA.Bridge
	if not (B and B.attached and B.GetRoute) then return end
	local ok, r = pcall(B.GetRoute)
	if not ok or type(r) ~= "table" then return end
	local best, bestRank
	for id, e in pairs(r) do
		local rank = num(e.rank)
		if rank and (not bestRank or rank < bestRank) then best, bestRank = id, rank end
	end
	return best
end

local destCache, destAt = nil, -10
local function destination()
	local t = GetTime()
	if destAt and t - destAt < 5 and destCache then return destCache[1], destCache[2] end
	local id = routeFirst() or (SoA.Actions.Selected and SoA.Actions.Selected())
	local key, kind = Act.TRAVEL, "travel"
	if id and inLog(id) then
		key = id
		kind = SoA.Log.ReadyForTurnIn(id) and "turnin" or "dest"
	end
	destCache, destAt = { key, kind }, t
	return key, kind
end
Act.Destination = destination

local function focusKey()
	local Est = SoA.Estimate
	for _, id in ipairs({ routeFirst() or 0, (SoA.Actions.Selected and SoA.Actions.Selected()) or 0 }) do
		if id > 0 and inLog(id) and Est.Near and Est.Near(id) then return id end
	end
	local pm = SoA:PlayerMap()
	for _, t in ipairs(SoA.Tickets:All()) do
		if t.status == "doing" and type(t.map) == "table" and t.map.m == pm then return t.key end
	end
end

---------------------------------------------------------------------------
-- Mob -> quest links (attribution b)
---------------------------------------------------------------------------
local function learn(names, qids, amount)
	local a = db()
	for _, n in ipairs(names or {}) do
		local k = norm(n)
		if k then
			local rec = a.mobs[k]
			if type(rec) ~= "table" then
				if countKeys(a.mobs) >= Act.MAX_MOBS then return end
				rec = {}
				a.mobs[k] = rec
			end
			for _, q in ipairs(qids) do
				if type(q) == "number" then
					rec[q] = math.max(0, num(rec[q], 0) + amount)
					if rec[q] == 0 then rec[q] = nil end
				end
			end
		end
	end
end

-- Best quest for a list of target names: learned links first, then the
-- objective texts (substring both ways, counts stripped: works on any client).
local function matchTargets(names)
	local a = db()
	local quests = logQuests()
	local bestQ, bestScore, bestRole
	local function consider(q, score, role)
		if not bestScore or score > bestScore then bestQ, bestScore, bestRole = q, score, role end
	end
	for _, n in ipairs(names or {}) do
		local k = norm(n)
		if k then
			local links = a.mobs[k]
			for _, q in ipairs(quests) do
				if not q.ready then
					local cnt = type(links) == "table" and num(links[q.id], 0) or 0
					local kill = openObjective(q, "monster")
					local item = openObjective(q, "item")
					if cnt > 0 and (kill or item) then
						consider(q.id, cnt >= 2 and 30 + cnt or 5 + cnt, kill and "kill" or "drop")
					end
					for _, o in ipairs(q.objectives) do
						local ot = not o.done and norm(o.text)
						if ot and (ot:find(k, 1, true) or k:find(ot, 1, true)) then
							consider(q.id, 20, o.kind == "monster" and "kill" or (o.kind == "item" and "drop" or "obj"))
						end
					end
				end
			end
		end
	end
	return bestQ, bestRole
end

-- Name of the mob that serves two shared quests (learned), or nil.
function Act:MobFor(a1, b1)
	local best, bestN
	for name, rec in pairs(db().mobs) do
		if type(rec) == "table" and rec[a1] and rec[b1] then
			local n = num(rec[a1], 0) + num(rec[b1], 0)
			if not bestN or n > bestN then best, bestN = name, n end
		end
	end
	return best
end

---------------------------------------------------------------------------
-- Attribution
---------------------------------------------------------------------------
local function hasPart(parts, key)
	for _, p in ipairs(parts) do if p.key == key then return p end end
end

-- Kill for one quest, drop attempt for the shared item quest (or the reverse
-- once the kill objective is done: then the item quest gets the whole fight).
local function expandShared(parts)
	local Est = SoA.Estimate
	for _, sp in ipairs(Est:SharedPairs()) do
		local pa = hasPart(parts, sp.a)
		if pa and pa.role == "kill" and not hasPart(parts, sp.b) then
			local qb = questById(sp.b)
			if qb and not qb.ready and openObjective(qb, nil, sp.bi) then
				parts[#parts + 1] = { key = sp.b, role = "drop", kills = 0, drops = 0 }
			end
		end
	end
end

local function attribute(f)
	local parts, sig = {}, nil
	local ids = {}
	for qid in pairs(f.inc) do ids[#ids + 1] = qid end
	table.sort(ids)
	-- (a) objective increments in and right after the fight
	if #ids > 0 then
		sig = "objective"
		local learnIds = {}
		for _, qid in ipairs(ids) do
			local inc = f.inc[qid]
			local role = (inc.kills > 0 and "kill") or (inc.drops > 0 and "item") or "objective"
			parts[#parts + 1] = { key = qid, role = role, kills = inc.kills, drops = inc.drops }
			if inc.kills > 0 or inc.drops > 0 then learnIds[#learnIds + 1] = qid end
		end
		if #learnIds > 0 then learn(f.targets, learnIds, 1) end
	end
	-- (b) the target's name against learned links and objective texts
	if #parts == 0 and #f.targets > 0 then
		local qid, role = matchTargets(f.targets)
		if qid then
			sig = "target"
			parts[1] = { key = qid, role = role, kills = 0, drops = 0 }
		end
	end
	-- (c) the quest you follow (route, super-track) or an active custom ticket, when near it
	if #parts == 0 then
		local k = focusKey()
		if k then
			sig = "focus"
			parts[1] = { key = k, role = "focus", kills = 0, drops = 0 }
		end
	end
	-- (d) unassigned
	if #parts == 0 then
		sig = "none"
		parts[1] = { key = Act.NONE, role = "none", kills = 0, drops = 0 }
	end
	if sig == "objective" or sig == "target" then expandShared(parts) end
	for _, p in ipairs(parts) do p.share = math.floor(1000 / #parts + 0.5) / 1000 end
	return parts, sig
end

---------------------------------------------------------------------------
-- Damage meter (read only)
---------------------------------------------------------------------------
local function meterTypes()
	local E = Enum and Enum.DamageMeterType
	return (E and num(E.DamageDone)) or 0, (E and num(E.HealingDone)) or 2
end

local function latestSession()
	if not DM then return end
	if DM.GetAvailableCombatSessions then
		local list = try(DM.GetAvailableCombatSessions)
		if type(list) == "table" then
			local ok, last = pcall(function() return list[#list] end)
			local id = ok and type(last) == "table" and num(last.sessionID)
			if id then return "id", id end
		end
	end
	if DM.GetCombatSessionFromType then return "type", nil end
end

local function getSession(kind, id, meter)
	if kind == "id" and DM.GetCombatSessionFromID then return try(DM.GetCombatSessionFromID, id, meter) end
	if kind == "type" and DM.GetCombatSessionFromType then
		local T = Enum and Enum.DamageMeterSessionType
		return try(DM.GetCombatSessionFromType, (T and num(T.Current)) or 1, meter)
	end
end

-- The player's row of a session: total, perSecond, stillSecret, duration
local function playerRow(s)
	if type(s) ~= "table" then return end
	local ok, src = pcall(function() return s.combatSources end)
	if not ok or type(src) ~= "table" then return end
	local okN, cnt = pcall(function() return #src end)
	if not okN or issecret(cnt) or type(cnt) ~= "number" then return nil, nil, true end
	local okD, dur = pcall(function() return s.durationSeconds end)
	dur = okD and num(dur) or nil
	local me = str((try(UnitName, "player")))
	local solo = not (IsInGroup and flag(try(IsInGroup)))
	local secret = false
	for i = 1, math.min(cnt, 40) do
		local r = src[i]
		if type(r) == "table" then
			local name, mine = r.name, r.isLocalPlayer
			local match = false
			if mine ~= nil and not issecret(mine) and mine == true then
				match = true
			elseif name ~= nil and not issecret(name) and type(name) == "string" and me then
				match = name == me or name:match("^([^%-]+)") == me
			elseif cnt == 1 and solo then
				match = true
			end
			if not match and name ~= nil and issecret(name) then secret = true end
			if match then
				local tot, ps = r.totalAmount, r.amountPerSecond
				if issecret(tot) or issecret(ps) then return nil, nil, true, dur end
				return num(tot), num(ps), false, dur
			end
		end
	end
	return nil, nil, secret, dur
end

local lastSession

local function readMeter(f, n)
	if f.meterDone then return end
	if not (DM and Act:Enabled()) then f.meterDone = true return end
	local kind, id = latestSession()
	if not kind or (kind == "id" and id == lastSession) then f.meterDone = true return end
	local dmgT, healT = meterTypes()
	local d, dps, sec1, sdur = playerRow(getSession(kind, id, dmgT))
	local h, _, sec2 = playerRow(getSession(kind, id, healT))
	if (sec1 or sec2) and n < Act.METER_TRIES then
		C_Timer.After(1, function() SoA.guard("act-meter", readMeter, f, n + 1) end)
		return
	end
	-- a session that clearly is not this fight (other length) is skipped
	if sdur and math.abs(sdur - f.dur) > math.max(5, f.dur) then d, h = nil, nil end
	if d and d > 0 then
		f.dmg = math.floor(d + 0.5)
		f.dps = math.floor((dps and dps > 0 and dps or d / math.max(1, f.dur)) + 0.5)
	end
	if h and h > 0 then f.heal = math.floor(h + 0.5) end
	if kind == "id" then lastSession = id end
	f.meterDone = true
end

---------------------------------------------------------------------------
-- Fight tracking
---------------------------------------------------------------------------
local cur            -- fight in progress
local pending = {}   -- finished fights waiting for their window / the meter
local downFight      -- the fight whose downtime is being counted
local walk           -- the walk in progress
local lastXP, lastXPMax
local learnedKill = setmetatable({}, { __mode = "k" })

local function targetName()
	if not (UnitExists and flag(try(UnitExists, "target"))) then return end
	if UnitIsPlayer and flag(try(UnitIsPlayer, "target")) then return end
	local ca = UnitCanAttack and try(UnitCanAttack, "player", "target")
	if ca ~= nil and not issecret(ca) and not ca then return end
	return str((try(UnitName, "target")))
end

local function noteTarget(f)
	local n = targetName()
	if not n then return end
	for _, v in ipairs(f.targets) do if v == n then return end end
	if #f.targets < 4 then f.targets[#f.targets + 1] = n end
end

local function recentFight()
	if cur then return cur end
	local f = pending[#pending]
	if f and f.endAt and GetTime() - f.endAt <= Act.WINDOW then return f end
end

-- Downtime ended (moved, next pull or the cap): teach the kill time.
local function closeDown()
	local f = downFight
	downFight = nil
	if not f or learnedKill[f] then return end
	learnedKill[f] = true
	local dur = num(f.dur, 0)
	if dur >= 2 and dur <= 180 and SoA.Estimate.LearnFight then SoA.Estimate:LearnFight(dur + num(f.down, 0)) end
end

local function closeWalk()
	local w = walk
	walk = nil
	if not w or w.dur < Act.WALK_MIN then return end
	store(db().walks, { t = w.t, dur = w.dur, key = w.key, kind = w.kind }, Act.MAX_WALKS, foldWalk)
	SoA:Fire("ACTIVITY", w.key)
end

local function finalize(f)
	if not f.meterDone and (f.waits or 0) < 6 then
		f.waits = (f.waits or 0) + 1
		C_Timer.After(1, function() SoA.guard("act-final", finalize, f) end)
		return
	end
	for i, p in ipairs(pending) do if p == f then table.remove(pending, i) break end end
	if f.dur < 1.5 and not next(f.inc) then
		if downFight == f then downFight = nil end
		return
	end
	local m1 = money()
	local parts, sig = attribute(f)
	local rec = {
		t = f.t, dur = math.floor(f.dur * 10 + 0.5) / 10, dmg = f.dmg, dps = f.dps, heal = f.heal,
		died = f.died or nil, xp = (f.xp or 0) > 0 and f.xp or nil,
		money = (m1 and f.money0 and m1 ~= f.money0) and (m1 - f.money0) or nil,
		down = f.down or 0, sig = sig, parts = parts,
		targets = #f.targets > 0 and { f.targets[1], f.targets[2], f.targets[3] } or nil,
	}
	store(db().fights, rec, Act.MAX_FIGHTS, foldFight)
	SoA:Fire("FIGHT", rec) -- Dungeons.lua: boss fight or trash
	if downFight == f then downFight = rec end
	if learnedKill[f] then learnedKill[rec] = true end
	-- drop attempts for the estimates: attributed quests, else every quest close by
	local Est = SoA.Estimate
	if sig == "objective" or sig == "target" then
		for _, p in ipairs(parts) do if type(p.key) == "number" and Est.NoteEncounter then Est:NoteEncounter(p.key) end end
	elseif Est.NoteNearEncounters then
		Est:NoteNearEncounters()
	end
	if rec.died then
		for _, p in ipairs(parts) do Act:Event(p.key, "death", { fight = rec.id }) end
	end
	SoA:Fire("ACTIVITY")
	SoA:Fire("ESTIMATES")
end

local function onStart()
	if not Act:Enabled() then return end
	closeWalk()
	closeDown()
	cur = { start = GetTime(), t = time(), inc = {}, targets = {}, xp = 0, money0 = money() }
	noteTarget(cur)
end

local function onEnd()
	local f = cur
	cur = nil
	if not f then return end
	f.dur = GetTime() - f.start
	f.endAt = GetTime()
	f.down = 0
	downFight = f
	pending[#pending + 1] = f
	C_Timer.After(1, function() SoA.guard("act-meter", readMeter, f, 1) end)
	C_Timer.After(Act.WINDOW + 0.5, function() SoA.guard("act-final", finalize, f) end)
end

local function onXP(_, unit)
	if unit ~= nil and (issecret(unit) or unit ~= "player") then return end
	local c, m = readXP()
	if not c then return end
	if lastXP then
		local gain
		if c >= lastXP then gain = c - lastXP elseif lastXPMax then gain = (lastXPMax - lastXP) + c end
		local f = recentFight()
		if f and gain and gain > 0 and gain < 10000000 then f.xp = (f.xp or 0) + gain end
	end
	lastXP, lastXPMax = c, m
end

local function onDead()
	if not Act:Enabled() then return end
	local f = recentFight()
	if f then f.died = true return end
	local key = destination()
	local a = db()
	local t = a.totals[key]
	if type(t) ~= "table" then t = blank() t.dpsList = nil a.totals[key] = t end
	t.deaths = num(t.deaths, 0) + 1
	Act:Event(key, "death")
end

-- objective increments (from Estimate:Scan)
local function onObjective(qid, index, kind, delta, have, need, text)
	if not Act:Enabled() then return end
	local a = db()
	a.lastProgress[qid] = time()
	local f = recentFight()
	if f then
		local inc = f.inc[qid]
		if not inc then inc = { kills = 0, drops = 0, other = 0 } f.inc[qid] = inc end
		if kind == "monster" then inc.kills = inc.kills + delta
		elseif kind == "item" then inc.drops = inc.drops + delta
		else inc.other = inc.other + delta end
	end
	Act:Event(qid, "progress", { index = index, have = have, need = need, text = text })
end

---------------------------------------------------------------------------
-- Every second: walking, downtime and targets in combat
---------------------------------------------------------------------------
local zoneTick = 0
local function tick()
	if not (SoA.char and Act:Enabled()) then return end
	if InCombatLockdown() then
		if cur then noteTarget(cur) end
		return
	end
	local taxi = UnitOnTaxi and flag(try(UnitOnTaxi, "player"))
	local speed = GetUnitSpeed and num((try(GetUnitSpeed, "player")), 0) or 0
	if taxi or speed > 0.5 then
		if downFight then closeDown() end
		local key, kind = destination()
		if taxi then key, kind = Act.TRAVEL, "taxi" end
		if walk and (walk.key ~= key or walk.kind ~= kind) then closeWalk() end
		if not walk then walk = { key = key, kind = kind, t = time(), dur = 0 } end
		walk.dur = walk.dur + 1
		walk.idle = 0
	else
		if downFight then
			downFight.down = num(downFight.down, 0) + 1
			if downFight.down >= Act.DOWN_MAX then closeDown() end
		end
		if walk then
			walk.idle = (walk.idle or 0) + 1
			if walk.idle >= Act.WALK_GAP then closeWalk() end
		end
	end
	-- every 10 s: are you near the quests in progress? (for the "Put on hold?" hint)
	zoneTick = zoneTick + 1
	if zoneTick >= 10 then
		zoneTick = 0
		local a, Est = db(), SoA.Estimate
		for _, q in ipairs(logQuests()) do
			if q.progress and not q.ready and Est.Near and Est.Near(q.id) then a.lastInZone[q.id] = time() end
		end
	end
end

---------------------------------------------------------------------------
-- Statistics
---------------------------------------------------------------------------
local function finish(s)
	local fightTime = s.dur + s.down
	s.active = fightTime + s.walk
	s.downPct = fightTime > 0 and s.down / fightTime or nil
	s.avgDps = s.dpsN > 0 and s.dpsSum / s.dpsN or nil
	s.xpm = s.active > 30 and s.xp / (s.active / 60) or nil
	s.kpm = fightTime > 30 and s.kills / (fightTime / 60) or nil
	s.dropRate = s.dropTries > 0 and s.drops / s.dropTries or nil
	s.walkPct = s.active > 0 and s.walk / s.active or nil
	return s
end

local function addTotals(s, t)
	if type(t) ~= "table" then return end
	for _, k in ipairs(FIELDS) do s[k] = s[k] + num(t[k], 0) end
end

-- Stats of one ticket (quest ID, "t:n", "travel" or "none").
function Act:Stats(key)
	key = Act.NormKey(key)
	local a = db()
	local s = blank()
	addTotals(s, a.totals[key])
	for _, f in ipairs(a.fights) do
		local p = hasPart(f.parts or {}, key)
		if p then addFight(s, f, p) end
	end
	for _, w in ipairs(a.walks) do
		if w.key == key then s.walk, s.walks = s.walk + num(w.dur, 0), s.walks + 1 end
	end
	for _, e in ipairs(self:Events(key)) do
		if e.kind == "death" and not e.fight then s.deaths = s.deaths + 1 end
	end
	s.firstEstimate = num(a.firstEstimate[key])
	return finish(s)
end

-- Totals and averages of every ticket of an epic, plus time per quest.
function Act:EpicStats(epicKey)
	local a = db()
	local keys = {}
	local seen = {}
	for _, map in ipairs({ a.epicOf, a.storyOf }) do
		for k, e in pairs(map) do
			if e == epicKey and not seen[k] then seen[k] = true keys[#keys + 1] = k end
		end
	end
	local s = blank()
	s.perQuest = {}
	for _, k in ipairs(keys) do
		local q = self:Stats(k)
		for _, f in ipairs(FIELDS) do s[f] = s[f] + q[f] end
		for _, v in ipairs(q.dpsList) do s.dpsList[#s.dpsList + 1] = v end
		if q.active > 0 or q.fights > 0 then
			s.perQuest[#s.perQuest + 1] = { key = k, minutes = q.active / 60, fights = q.fights, estimate = q.firstEstimate }
		end
	end
	table.sort(s.perQuest, function(x, y) return x.minutes > y.minutes end)
	s.quests = #s.perQuest
	return finish(s)
end

-- Unique fights in a time range (sprint review): fights, average DPS, deaths, downtime %.
function Act:RangeStats(t0, t1)
	local out = { fights = 0, deaths = 0, dur = 0, down = 0, dpsSum = 0, dpsN = 0 }
	t1 = t1 or time()
	for _, f in ipairs(db().fights) do
		local t = num(f.t, 0)
		if t >= t0 and t <= t1 then
			out.fights = out.fights + 1
			if f.died then out.deaths = out.deaths + 1 end
			out.dur, out.down = out.dur + num(f.dur, 0), out.down + num(f.down, 0)
			local d = num(f.dps)
			if d and d > 0 then out.dpsSum, out.dpsN = out.dpsSum + d, out.dpsN + 1 end
		end
	end
	out.avgDps = out.dpsN > 0 and out.dpsSum / out.dpsN or nil
	out.downPct = (out.dur + out.down) > 0 and out.down / (out.dur + out.down) or nil
	return out
end

-- Learned seconds per kill (fight + downtime) for one quest: avg, fights.
function Act:KillTimeFor(questID)
	local sum, n = 0, 0
	local list = db().fights
	for i = #list, 1, -1 do
		local f = list[i]
		local p = hasPart(f.parts or {}, questID)
		if p and p.role ~= "none" and p.role ~= "focus" and not f.died then
			local d = num(f.dur, 0)
			if d >= 2 and d <= 180 then
				sum, n = sum + d + math.min(num(f.down, 0), Act.DOWN_MAX), n + 1
				if n >= 20 then break end
			end
		end
	end
	if n > 0 then return sum / n, n end
end

-- Fights and walks of a ticket (newest last).
function Act:FightsOf(key)
	key = Act.NormKey(key)
	local out = {}
	for _, f in ipairs(db().fights) do
		local p = hasPart(f.parts or {}, key)
		if p then out[#out + 1] = { fight = f, part = p } end
	end
	return out
end

function Act:WalksOf(key)
	key = Act.NormKey(key)
	local out = {}
	for _, w in ipairs(db().walks) do if w.key == key then out[#out + 1] = w end end
	return out
end

local function byId(list, id)
	for i, r in ipairs(list) do if r.id == id then return r, i end end
end

---------------------------------------------------------------------------
-- Efficiency score (0..100) and tips
---------------------------------------------------------------------------
function Act:Score(s, estimate)
	local L = SoA.L
	local score, tips = 100, {}
	local actual = (s.active or 0) / 60
	if s.downPct and s.fights >= 3 and s.downPct > 0.25 then
		score = score - math.min(35, (s.downPct - 0.25) * 100)
		local _, class = try(UnitClass, "player")
		if str(class) == "MAGE" then
			tips[#tips + 1] = L["High downtime (%d%%): conjure a stack of food and water (Conjure Refreshment) before you head out, and drink only below about 40%% mana."]:format(s.downPct * 100 + 0.5)
		else
			tips[#tips + 1] = L["High downtime (%d%%): carry food and drink from a vendor, use bandages or self-heals, and pull the next mob a little earlier."]:format(s.downPct * 100 + 0.5)
		end
	end
	if s.deaths > 0 then
		score = score - math.min(30, s.deaths * 10)
		tips[#tips + 1] = L["%d deaths: pull fewer mobs at once, or come back a level higher."]:format(s.deaths)
	end
	if estimate and estimate > 0 and actual > estimate * 1.25 then
		score = score - math.min(25, (actual / estimate - 1.25) * 40)
		tips[#tips + 1] = L["Takes %d%% longer than estimated: consider putting it on hold or doing it in a group."]:format((actual / estimate - 1) * 100 + 0.5)
	end
	if s.walkPct and s.active > 120 and s.walkPct > 0.5 then
		score = score - math.min(15, (s.walkPct - 0.5) * 50)
		tips[#tips + 1] = L["Mostly walking (%d%%): combine it with quests nearby in the same sprint."]:format(s.walkPct * 100 + 0.5)
	end
	local list = s.dpsList or {}
	if #list >= 8 and s.avgDps then
		local recent = 0
		for i = #list - 4, #list do recent = recent + list[i] end
		recent = recent / 5
		if recent < s.avgDps * 0.85 then
			score = score - 10
			tips[#tips + 1] = L["Your recent DPS is below your average here: check gear upgrades and talents."]
		end
	end
	if #tips == 0 then tips[1] = s.fights > 0 and L["No problems found. Keep going!"] or L["Not enough data yet."] end
	return math.max(0, math.min(100, math.floor(score + 0.5))), tips
end

---------------------------------------------------------------------------
-- Manual correction (re-teaches the mob -> quest links)
---------------------------------------------------------------------------
local function reteach(f, newKeys)
	if not f.targets then return end
	local old = {}
	for _, p in ipairs(f.parts or {}) do
		local keep = false
		for _, k in ipairs(newKeys) do if k == p.key then keep = true end end
		if not keep and type(p.key) == "number" then old[#old + 1] = p.key end
	end
	if #old > 0 then learn(f.targets, old, -3) end
	learn(f.targets, newKeys, 3)
end

function Act:MoveFight(id, key)
	key = Act.NormKey(key)
	local f = byId(db().fights, id)
	if not f then return end
	reteach(f, { key })
	f.parts = { { key = key, share = 1, role = "manual", kills = 0, drops = 0 } }
	f.sig = "manual"
	self:Event(key, "corrected", { fight = id })
	SoA:Fire("ACTIVITY")
end

function Act:SplitFight(id, keyA, keyB)
	keyA, keyB = Act.NormKey(keyA), Act.NormKey(keyB)
	local f = byId(db().fights, id)
	if not f or keyA == keyB then return end
	reteach(f, { keyA, keyB })
	f.parts = { { key = keyA, share = 0.5, role = "manual", kills = 0, drops = 0 },
		{ key = keyB, share = 0.5, role = "manual", kills = 0, drops = 0 } }
	f.sig = "manual"
	SoA:Fire("ACTIVITY")
end

function Act:MoveWalk(id, key)
	local w = byId(db().walks, id)
	if not w then return end
	w.key, w.manual = Act.NormKey(key), true
	SoA:Fire("ACTIVITY")
end

function Act:SplitWalk(id, keyB)
	local a = db()
	local w, i = byId(a.walks, id)
	if not w then return end
	local half = math.floor(num(w.dur, 0) / 2)
	if half < 1 then return end
	w.dur, w.manual = w.dur - half, true
	table.insert(a.walks, i + 1, { id = a.nextId, t = w.t, dur = half, key = Act.NormKey(keyB), kind = w.kind, manual = true })
	a.nextId = a.nextId + 1
	SoA:Fire("ACTIVITY")
end

---------------------------------------------------------------------------
-- Model hooks: first estimate and epic of each ticket (for epic totals)
---------------------------------------------------------------------------
function Act:NoteItem(it)
	if not SoA.char then return end
	local key = Act.NormKey(it.key)
	local a = db()
	if it.minutes and a.firstEstimate[key] == nil then a.firstEstimate[key] = math.floor(it.minutes * 10 + 0.5) / 10 end
	if it.epicKey and it.epicKey ~= "loose" then a.epicOf[key] = it.epicKey end
	if it.storyKey then a.storyOf[key] = it.storyKey end
end

-- Keep the per-ticket maps small: forget tickets without fights, walks or events.
local function prune()
	local a = db()
	local used = {}
	for _, f in ipairs(a.fights) do for _, p in ipairs(f.parts or {}) do used[p.key] = true end end
	for _, w in ipairs(a.walks) do used[w.key] = true end
	for k in pairs(a.events) do used[k] = true end
	for k in pairs(a.totals) do used[k] = true end
	for _, map in ipairs({ a.firstEstimate, a.epicOf, a.storyOf }) do
		if countKeys(map) > 600 then
			for k in pairs(map) do
				if not used[k] and not (type(k) == "number" and inLog(k)) then map[k] = nil end
			end
		end
	end
	for _, map in ipairs({ a.lastProgress, a.lastInZone }) do
		for k in pairs(map) do if type(k) ~= "number" or not inLog(k) then map[k] = nil end end
	end
end

function Act:OnEnable()
	db()
	lastXP, lastXPMax = readXP()
	SoA:On("PLAYER_REGEN_DISABLED", onStart)
	SoA:On("PLAYER_REGEN_ENABLED", onEnd)
	SoA:On("PLAYER_TARGET_CHANGED", function() if cur then noteTarget(cur) end end)
	SoA:On("PLAYER_XP_UPDATE", onXP)
	SoA:On("PLAYER_DEAD", onDead)
	SoA:On("QUEST_ACCEPTED", function(_, a1, a2)
		local id = num(a2) or num(a1)
		if id and id > 0 then Act:Event(id, "accepted") end
	end)
	SoA:On("QUEST_TURNED_IN", function(_, id)
		id = num(id)
		if id then
			Act:Event(id, "turnedin")
			local a = db()
			a.lastProgress[id], a.lastInZone[id] = nil, nil
		end
	end)
	SoA:Listen("OBJECTIVE", onObjective)
	SoA:Listen("OBJECTIVE_LOST", function(qid, index, kind, delta, text)
		Act:Event(qid, "lost", { index = index, delta = delta, text = text })
	end)
	C_Timer.NewTicker(1, function() SoA.guard("act-tick", tick) end)
	C_Timer.After(30, function() SoA.guard("act-prune", prune) end)
end
