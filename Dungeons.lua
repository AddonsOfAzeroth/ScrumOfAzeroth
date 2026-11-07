-- Scrum of Azeroth by DinX: dungeons and raids. A dungeon is an epic, a run is a
-- short sprint: one card per boss plus a trash card, the next boss in progress.
-- Read-only: GetInstanceInfo, the Encounter Journal (EJ_*), ENCOUNTER_START/END,
-- saved instances (lockouts) and the fights recorded by Activity.lua.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local DG = SoA:NewModule("Dungeons")
DG.COLOR = { 0.86, 0.62, 0.26 }
DG.RESUME = 1800  -- s: leave and come back within this time = the same run
DG.MAX_RUNS = 200
DG.METER_WINDOW = 20 -- s after ENCOUNTER_END: the next recorded fight is the boss fight

-- ScrumOfAzerothCharDB.dungeons = { runs = { run }, best = { ["<key>:<difficultyID>"] = runId },
--   lockouts = { { name, instanceID, difficultyID, difficultyName, isRaid, reset, bosses = { { name, killed } } } },
--   current = runId, nextId }
-- run = { id, key, instanceID, mapID, name, kind = "party"|"raid", difficultyID, difficultyName, groupSize,
--   start, finish, duration, complete, bosses = { { encounterID, name, start, duration, success, wipes, dps, hps, deaths } },
--   trash = { time, pulls }, deaths, xp, money, quests = { questIDs }, leftAt }
-- ScrumOfAzerothDB.dungeonInfo[key] = { name, kind, bosses = { { id = dungeonEncounterID, name } } } (account)
-- ScrumOfAzerothDB.dungeonQuests[key] = { [questID] = title } quests seen for a dungeon (account, learned)
local function db()
	local c = SoA.char
	if type(c.dungeons) ~= "table" then c.dungeons = {} end
	local d = c.dungeons
	d.runs = type(d.runs) == "table" and d.runs or {}
	d.best = type(d.best) == "table" and d.best or {}
	d.lockouts = type(d.lockouts) == "table" and d.lockouts or {}
	d.nextId = num(d.nextId, 1)
	return d
end

local function account(field)
	local a = SoA.db
	if type(a[field]) ~= "table" then a[field] = {} end
	return a[field]
end

local function runById(id)
	if not id then return end
	for i = #db().runs, 1, -1 do
		local r = db().runs[i]
		if r.id == id then return r end
	end
end

function DG:Current()
	local r = runById(db().current)
	if r and not r.finish then return r end
end

-- "1:42" / "1:02:05"
function DG.Clock(sec)
	sec = math.floor(num(sec, 0) + 0.5)
	if sec >= 3600 then return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60) end
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

---------------------------------------------------------------------------
-- Dungeon identity and boss list (Encounter Journal when available)
---------------------------------------------------------------------------
local function journalFor(uiMap)
	if not (uiMap and EJ_GetInstanceForMap) then return end
	local id = num((try(EJ_GetInstanceForMap, uiMap)))
	if id and id > 0 then return id end
end

local function isDungeonMap(uiMap)
	local info = uiMap and C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, uiMap)
	if type(info) ~= "table" then return end
	local DUNGEON = (Enum and Enum.UIMapType and num(Enum.UIMapType.Dungeon)) or 4
	if num(info.mapType) == DUNGEON then return str(info.name) end
end

-- key, name for a map inside a dungeon (or a quest's dungeon map)
-- Only maps of the Dungeon type count: open-world zones can have a journal entry
-- too (world bosses) and must not become a dungeon.
local function keyForMap(uiMap)
	local mapName = isDungeonMap(uiMap)
	if not mapName then return end
	local jid = journalFor(uiMap)
	if jid then
		local name = EJ_GetInstanceInfo and str((try(EJ_GetInstanceInfo, jid)))
		return "ej:" .. jid, name or mapName, jid
	end
	return "n:" .. mapName, mapName
end

local function ensureInfo(key, name, kind, jid)
	local all = account("dungeonInfo")
	local info = all[key]
	if type(info) ~= "table" then info = { bosses = {} } all[key] = info end
	info.name = name or info.name or "?"
	info.kind = kind or info.kind
	if jid and EJ_GetEncounterInfoByIndex and #info.bosses == 0 then
		for i = 1, 30 do
			local bname, _, _, _, _, _, encID = try(EJ_GetEncounterInfoByIndex, i, jid)
			bname = str(bname)
			if not bname then break end
			info.bosses[#info.bosses + 1] = { id = num(encID), name = bname }
		end
	end
	return info
end

function DG:Info(key) return account("dungeonInfo")[key] end

---------------------------------------------------------------------------
-- Quests that belong to a dungeon (their objective map is inside it)
---------------------------------------------------------------------------
local questKey = {}  -- questID -> key or false
local questAt = {}

function DG:ForQuest(questID)
	questID = num(questID)
	if not questID then return end
	local k = questKey[questID]
	if k == nil or (k == false and GetTime() - (questAt[questID] or 0) > 60) then
		k = false
		local m = GetQuestUiMapID and num((try(GetQuestUiMapID, questID, true)))
		if m and m > 0 then
			local key, name, jid = keyForMap(m)
			if key then
				k = key
				ensureInfo(key, name, nil, jid)
			end
		end
		if not k then
			for key, list in pairs(account("dungeonQuests")) do
				if type(list) == "table" and list[questID] then k = key break end
			end
		end
		questKey[questID], questAt[questID] = k, GetTime()
		if k then
			local list = account("dungeonQuests")
			list[k] = type(list[k]) == "table" and list[k] or {}
			list[k][questID] = list[k][questID] or SoA.Log:Title(questID) or true
		end
	end
	if not k then return end
	local info = self:Info(k)
	return k, info and info.name
end

---------------------------------------------------------------------------
-- Run cards (custom tickets with a dungeon)
---------------------------------------------------------------------------
local function runTickets(run)
	local out = {}
	for _, t in ipairs(SoA.Tickets:All()) do
		if t.run == run.id then out[#out + 1] = t end
	end
	return out
end

local function bestBossTime(key, diff, name)
	local r = runById(db().best[key .. ":" .. tostring(diff)])
	if not r then return end
	for _, b in ipairs(r.bosses) do
		if b.name == name and b.success then return b.duration end
	end
end

local function makeTickets(run, info)
	local T = SoA.Tickets
	local bestRun = runById(db().best[run.key .. ":" .. tostring(run.difficultyID)])
	local per = bestRun and #info.bosses > 0 and math.max(2, bestRun.duration / 60 / (#info.bosses + 1)) or 6
	local function add(title, boss, status)
		local t = T:New()
		t.title, t.status, t.minutes = title, status, math.floor(per + 0.5)
		t.dungeon, t.dungeonName, t.run, t.boss = run.key, run.name, run.id, boss
		T:Save(t)
	end
	add(SoA.L["Trash"], "trash", "doing")
	for i, b in ipairs(info.bosses) do add(b.name, b.id or b.name, i == 1 and "doing" or "todo") end
end

-- The first boss card still open moves to In progress: the next thing to do.
local function advance(run)
	for _, t in ipairs(runTickets(run)) do
		if t.boss ~= "trash" and t.status ~= "done" then
			if t.status == "todo" then SoA.Tickets:SetStatus(t.key, "doing") end
			return t
		end
	end
end

local function closeTickets(run)
	for _, t in ipairs(runTickets(run)) do
		if t.status ~= "done" then
			if run.complete or t.boss == "trash" and #run.bosses > 0 then
				SoA.Tickets:SetStatus(t.key, "done")
			else
				SoA.Tickets:Delete(t.key)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Runs
---------------------------------------------------------------------------
local active          -- encounter in progress { id, name, start }
local lastEncounter   -- { boss, endAt, attached }

local function killed(run)
	local n = 0
	for _, b in ipairs(run.bosses) do if b.success then n = n + 1 end end
	return n
end
DG.Killed = killed

local function totalBosses(run)
	local info = DG:Info(run.key)
	return math.max(info and #info.bosses or 0, killed(run))
end
DG.TotalBosses = totalBosses

function DG:Close(run, complete)
	if not run or run.finish then return end
	run.finish = time()
	run.duration = run.finish - run.start - math.max(0, run.leftAt and (run.finish - run.leftAt) or 0)
	run.complete = complete and true or false
	run.leftAt = nil
	closeTickets(run)
	if db().current == run.id then db().current = nil end
	local L, S = SoA.L, SoA.Style
	if complete then
		local bk = run.key .. ":" .. tostring(run.difficultyID)
		local prev = runById(db().best[bk])
		local pb = not prev or run.duration < num(prev.duration, math.huge)
		if pb then db().best[bk] = run.id end
		local text = L["%s cleared in %s"]:format(run.name, DG.Clock(run.duration))
		if pb and prev then text = text .. "  |cffffd100" .. L["New personal best!"] .. "|r"
		elseif prev then text = text .. "  |cff999999" .. L["(best %s)"]:format(DG.Clock(prev.duration)) .. "|r" end
		SoA.Toast:Show(text, S.gold)
	end
	SoA:Fire("DUNGEON")
	SoA:Fire("MODEL_DIRTY")
end

local function start(key, name, kind, diff, diffName, size, instanceID, mapID, jid)
	local info = ensureInfo(key, name, kind, jid)
	local d = db()
	local run = {
		id = d.nextId, key = key, instanceID = instanceID, mapID = mapID, name = info.name, kind = kind,
		difficultyID = diff, difficultyName = diffName, groupSize = size,
		start = time(), bosses = {}, trash = { time = 0, pulls = 0 }, deaths = 0, xp = 0, money = 0, quests = {},
	}
	d.nextId = d.nextId + 1
	d.runs[#d.runs + 1] = run
	while #d.runs > DG.MAX_RUNS do table.remove(d.runs, 1) end
	d.current = run.id
	makeTickets(run, info)
	local L = SoA.L
	local nb = #info.bosses
	SoA.Toast:Show(nb > 0 and L["Run started: %s (%d bosses)"]:format(run.name, nb) or L["Run started: %s"]:format(run.name), DG.COLOR,
		{ L["Details"], function() SoA.Detail:OpenEpic("dg:" .. key) end })
	SoA:Fire("DUNGEON")
	SoA:Fire("MODEL_DIRTY")
	return run
end

local function check()
	local cur = DG:Current()
	local name, itype, diff, diffName, maxPlayers, _, _, instanceID = try(GetInstanceInfo)
	itype = str(itype)
	if itype == "party" or itype == "raid" then
		local uiMap = SoA:PlayerMap()
		local key, jname, jid = keyForMap(uiMap)
		instanceID = num(instanceID)
		if not key and instanceID then key = "in:" .. instanceID end
		if not key then return end
		diff = num(diff, 0)
		if cur and cur.key == key and cur.difficultyID == diff then
			if cur.leftAt then
				cur.start = cur.start + (time() - cur.leftAt) -- time outside does not count
				cur.leftAt = nil
			end
			return
		end
		if cur then DG:Close(cur, false) end
		start(key, jname or str(name), itype, diff, str(diffName), num(maxPlayers), instanceID, uiMap, jid)
	elseif cur then
		if not cur.leftAt then cur.leftAt = time() end
		if time() - cur.leftAt > DG.RESUME then DG:Close(cur, false) end
	end
end

local function onEncounterStart(_, id, name)
	if not DG:Current() then return end
	active = { id = num(id), name = str(name), start = GetTime() }
end

local function onEncounterEnd(_, id, name, _, _, success)
	local run = DG:Current()
	if not run then return end
	id, name = num(id), str(name)
	local dur = active and (GetTime() - active.start) or nil
	active = nil
	local b
	for _, x in ipairs(run.bosses) do
		if (id and x.encounterID == id) or (name and x.name == name) then b = x break end
	end
	if not b then
		b = { encounterID = id, name = name or "?", wipes = 0, deaths = 0, start = time() }
		run.bosses[#run.bosses + 1] = b
		-- a boss the journal did not list: learn it
		local info = DG:Info(run.key)
		if info and name then
			local known = false
			for _, ib in ipairs(info.bosses) do if ib.name == name or (id and ib.id == id) then known = true end end
			if not known then info.bosses[#info.bosses + 1] = { id = id, name = name } end
		end
	end
	lastEncounter = { boss = b, endAt = GetTime() }
	local L, S = SoA.L, SoA.Style
	if num(success) == 1 or success == true then
		b.success, b.duration = true, dur and math.floor(dur * 10 + 0.5) / 10 or b.duration
		for _, t in ipairs(runTickets(run)) do
			if t.boss == (id or name) or t.title == name then SoA.Tickets:SetStatus(t.key, "done") end
		end
		local best = bestBossTime(run.key, run.difficultyID, b.name)
		local text = L["Boss down: %s"]:format(b.name) .. (b.duration and ("  " .. DG.Clock(b.duration)) or "")
		if best and b.duration then
			text = text .. (b.duration < best and ("  |cffffd100" .. L["best!"] .. "|r") or ("  |cff999999" .. L["(best %s)"]:format(DG.Clock(best)) .. "|r"))
		end
		local nextCard = advance(run)
		if nextCard then text = text .. "  |cff999999" .. L["Next: %s"]:format(nextCard.title) .. "|r" end
		SoA.Toast:Show(text, S.green)
		if RequestRaidInfo then try(RequestRaidInfo) end
		local total = totalBosses(run)
		if total > 0 and killed(run) >= total then DG:Close(run, true) end
	else
		b.wipes = num(b.wipes, 0) + 1
	end
	SoA:Fire("DUNGEON")
	SoA:Fire("MODEL_DIRTY")
end

-- Activity.lua recorded a fight: boss fight (just after ENCOUNTER_END) or trash.
local function onFight(rec)
	local run = DG:Current()
	if not (run and type(rec) == "table") or run.leftAt then return end
	local le = lastEncounter
	if le and not le.attached and GetTime() - le.endAt <= DG.METER_WINDOW then
		le.attached = true
		local b = le.boss
		if rec.dps then b.dps = rec.dps end
		if rec.heal and num(rec.dur, 0) > 0 then b.hps = math.floor(rec.heal / rec.dur + 0.5) end
		if rec.died then b.deaths = num(b.deaths, 0) + 1 end
	else
		run.trash.time = run.trash.time + num(rec.dur, 0)
		run.trash.pulls = run.trash.pulls + 1
	end
	if rec.died then run.deaths = run.deaths + 1 end
	run.xp = run.xp + num(rec.xp, 0)
	run.money = run.money + math.max(0, num(rec.money, 0))
	SoA:Fire("DUNGEON")
end

local function onTurnedIn(_, qid)
	qid = num(qid)
	local run = DG:Current()
	if not (qid and run) or run.leftAt then return end
	run.quests[#run.quests + 1] = qid
	local list = account("dungeonQuests")
	list[run.key] = type(list[run.key]) == "table" and list[run.key] or {}
	list[run.key][qid] = SoA.Log:Title(qid) or true
	questKey[qid] = run.key
end

local function readLockouts()
	if not (GetNumSavedInstances and GetSavedInstanceInfo) then return end
	local out = {}
	for i = 1, num((try(GetNumSavedInstances)), 0) do
		local name, _, reset, diff, locked, _, _, isRaid, _, diffName, numEnc, _, _, instanceID = try(GetSavedInstanceInfo, i)
		if flag(locked) and str(name) then
			local lo = { name = str(name), instanceID = num(instanceID), difficultyID = num(diff), difficultyName = str(diffName),
				isRaid = flag(isRaid), reset = time() + num(reset, 0), bosses = {} }
			for j = 1, num(numEnc, 0) do
				local bname, _, isKilled = try(GetSavedInstanceEncounterInfo, i, j)
				if str(bname) then lo.bosses[#lo.bosses + 1] = { name = str(bname), killed = flag(isKilled) } end
			end
			out[#out + 1] = lo
		end
	end
	db().lockouts = out
	SoA:Fire("DUNGEON")
end

function DG:Lockout(run_or_name)
	local name = type(run_or_name) == "table" and run_or_name.name or run_or_name
	for _, lo in ipairs(db().lockouts) do
		if lo.name == name and num(lo.reset, 0) > time() then return lo end
	end
end

function DG:Runs(key)
	local out = {}
	for i = #db().runs, 1, -1 do
		local r = db().runs[i]
		if not key or r.key == key then out[#out + 1] = r end
	end
	return out
end

function DG:Best(key, diff) return runById(db().best[key .. ":" .. tostring(diff)]) end

---------------------------------------------------------------------------
-- Board line and epic view
---------------------------------------------------------------------------
function DG:InfoText()
	local run = self:Current()
	if not run or run.leftAt then return end
	local L = SoA.L
	local text = L["Run: %s"]:format(run.name) .. "  " .. DG.Clock(time() - run.start)
	local total = totalBosses(run)
	if total > 0 then text = text .. "  ·  " .. L["%d/%d bosses"]:format(killed(run), total) end
	for _, t in ipairs(runTickets(run)) do
		if t.boss ~= "trash" and t.status == "doing" then text = text .. "  ·  " .. L["Next: %s"]:format(t.title) break end
	end
	return "|cffdb9e42" .. text .. "|r"
end

local function runLine(r)
	local L = SoA.L
	local total = totalBosses(r)
	local bits = { date("%d/%m %H:%M", r.start), r.difficultyName or "", DG.Clock(r.duration or (time() - r.start)) }
	if total > 0 then bits[#bits + 1] = L["%d/%d bosses"]:format(killed(r), total) end
	local wipes = 0
	for _, b in ipairs(r.bosses) do wipes = wipes + num(b.wipes, 0) end
	if wipes > 0 then bits[#bits + 1] = L["%d wipes"]:format(wipes) end
	if r.deaths > 0 then bits[#bits + 1] = L["%d deaths"]:format(r.deaths) end
	return table.concat(bits, "  ·  ")
end

function DG:EpicView(cv, tab, D)
	local L, S = SoA.L, SoA.Style
	local key = D.epicKey:sub(4)
	local info = self:Info(key) or { name = key, bosses = {} }
	cv:Text(info.name, { size = 14, color = DG.COLOR })
	cv:Text(info.kind == "raid" and L["Raid"] or L["Dungeon"], { size = 10, color = S.colors.muted })
	local run = self:Current()
	if run and run.key ~= key then run = nil end

	if tab == "overview" then
		-- 1. the run in progress: what is next comes first
		if run then
			cv:Header(L["Run in progress"])
			local total = totalBosses(run)
			cv:Bar(total > 0 and killed(run) / total or 0, DG.COLOR,
				L["%d/%d bosses"]:format(killed(run), total) .. "  ·  " .. DG.Clock(time() - run.start))
			for _, ib in ipairs(info.bosses) do
				local done
				for _, b in ipairs(run.bosses) do if b.name == ib.name and b.success then done = b end end
				local best = bestBossTime(key, run.difficultyID, ib.name)
				cv:Row({ color = done and S.green or S.colors.muted, text = ib.name, textColor = done and S.colors.muted or nil,
					right = done and (DG.Clock(done.duration) .. (best and ("  /  " .. DG.Clock(best)) or "")) or (best and L["best %s"]:format(DG.Clock(best)) or "") })
			end
			cv:Pair(L["Trash"], L["%s in %d pulls"]:format(DG.Clock(run.trash.time), run.trash.pulls))
			cv:Buttons({ { L["End run"], function() DG:Close(run, false) end, L["Stops the timer; open boss cards are removed."] } })
		end

		-- 2. quests to pick up before going in
		local list = account("dungeonQuests")[key]
		local m = SoA.Model:Get()
		local rows = {}
		for _, it in ipairs(m.items) do
			if it.kind == "quest" and it.dungeonKey == D.epicKey then rows[#rows + 1] = { id = it.id, title = it.title, state = it.ready and "ready" or "log", it = it } end
		end
		if type(list) == "table" then
			for qid, title in pairs(list) do
				if not SoA.Log:InLog(qid) then
					rows[#rows + 1] = { id = qid, title = type(title) == "string" and title or SoA.Log:Title(qid) or ("#" .. qid),
						state = SoA.Log:IsDone(qid) and "done" or "missing" }
				end
			end
		end
		if #rows > 0 then
			cv:Header(L["Quests for this dungeon"])
			local order = { missing = 1, log = 2, ready = 3, done = 4 }
			table.sort(rows, function(a, b) if order[a.state] ~= order[b.state] then return order[a.state] < order[b.state] end return a.title < b.title end)
			local LABEL = { missing = L["not picked up"], log = L["in your log"], ready = L["ready to turn in"], done = L["done"] }
			local COLOR = { missing = S.gold, log = S.colors.accent, ready = S.green, done = S.colors.muted }
			for _, r in ipairs(rows) do
				cv:Row({ color = COLOR[r.state], text = r.title, textColor = r.state == "done" and S.colors.muted or nil, right = LABEL[r.state],
					click = r.it and function() D:Open(r.it) end or nil })
			end
		end

		-- 3. lockout (raids, heroics)
		local lo = self:Lockout(info.name)
		if lo then
			local k = 0
			for _, b in ipairs(lo.bosses) do if b.killed then k = k + 1 end end
			cv:Header(L["Saved this week"])
			cv:Pair(lo.difficultyName or "", L["%d/%d bosses, resets in %s"]:format(k, #lo.bosses, S:Minutes((lo.reset - time()) / 60)))
		end

		-- 4. bosses with the best kill times (no run in progress)
		if not run and #info.bosses > 0 then
			cv:Header(L["Bosses"])
			for _, ib in ipairs(info.bosses) do
				local best
				for _, r in ipairs(self:Runs(key)) do
					local t = bestBossTime(key, r.difficultyID, ib.name)
					if t and (not best or t < best) then best = t end
				end
				cv:Row({ color = DG.COLOR, text = ib.name, right = best and L["best %s"]:format(DG.Clock(best)) or "" })
			end
		end
	else
		-- stats: personal bests and the last runs
		local runs = self:Runs(key)
		if #runs == 0 then
			cv:Text(L["No runs yet. A run starts by itself when you enter."], { color = S.colors.muted })
			return
		end
		cv:Header(L["Personal best"])
		local seen = {}
		for _, r in ipairs(runs) do
			local d = r.difficultyID
			if not seen[d] then
				seen[d] = true
				local b = self:Best(key, d)
				if b then cv:Pair(b.difficultyName or "?", DG.Clock(b.duration) .. "  ·  " .. date("%d/%m/%Y", b.start), S.gold) end
			end
		end
		local times = {}
		for i = #runs, 1, -1 do if runs[i].complete then times[#times + 1] = runs[i].duration / 60 end end
		if #times > 1 then
			cv:Header(L["Clear times (minutes)"])
			cv:Spark(times, DG.COLOR)
		end
		cv:Header(L["Last runs"])
		for i = 1, math.min(8, #runs) do
			local r = runs[i]
			cv:Row({ color = r.complete and S.green or (r.finish and S.colors.muted or DG.COLOR), text = runLine(r) })
		end
		local trash, total, n = 0, 0, 0
		for _, r in ipairs(runs) do
			if r.complete then trash, total, n = trash + r.trash.time, total + r.duration, n + 1 end
		end
		if n > 0 and total > 0 then
			cv:Pair(L["Time on trash"], ("%d%%"):format(trash / total * 100 + 0.5))
			cv:Pair(L["Average clear"], DG.Clock(total / n))
		end
	end
end

function DG:OnEnable()
	SoA:On("PLAYER_ENTERING_WORLD", function() C_Timer.After(2, function() SoA.guard("dg-check", check) end) end)
	SoA:On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1, function() SoA.guard("dg-check", check) end) end)
	SoA:On("ENCOUNTER_START", onEncounterStart)
	SoA:On("ENCOUNTER_END", onEncounterEnd)
	SoA:On("QUEST_TURNED_IN", onTurnedIn)
	SoA:On("QUEST_ACCEPTED", function(_, a, b) local q = num(b) or num(a) if q then questKey[q] = nil end end)
	SoA:On("UPDATE_INSTANCE_INFO", readLockouts)
	SoA:Listen("FIGHT", onFight)
	if RequestRaidInfo then try(RequestRaidInfo) end
	-- a run left open on another day (logout inside, never came back) is closed
	local cur = self:Current()
	if cur and time() - num(cur.leftAt or cur.start, 0) > 6 * 3600 then self:Close(cur, false) end
end
