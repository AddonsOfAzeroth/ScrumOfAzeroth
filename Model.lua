-- Scrum of Azeroth by DinX: the board's data model. Quests, custom tickets,
-- available and upcoming questline steps and done items, each with epic,
-- estimate, XP, priority, blockers and sprint membership.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local M = SoA:NewModule("Model")
local MAX_AGE = 3 -- s a built model is reused

local cache, builtAt, dirty = nil, 0, true

function M:Dirty() dirty = true end

-- The last built model without building (for callers inside CasterKit's planner).
function M:Peek() return cache end

function M:Get()
	if cache and not dirty and GetTime() - builtAt < MAX_AGE then return cache end
	local ok, res = pcall(self.Build, self)
	if ok and res then
		cache, builtAt, dirty = res, GetTime(), false
	elseif not ok and SoA.debug then
		SoA:Print("model: " .. tostring(res))
	end
	return cache or { items = {}, avail = {}, upcoming = {}, done = {}, sprintDone = {}, byKey = {}, epics = {}, ctx = {} }
end

local function labelColor(text)
	local h = 0
	for i = 1, #text do h = (h * 31 + text:byte(i)) % 100000 end
	return SoA.Epics:ColorFor(h)
end

local function median(list)
	if #list == 0 then return nil end
	table.sort(list)
	local m = math.floor((#list + 1) / 2)
	return list[m]
end

function M:Build()
	local Log, E, Est, P, B, SP, T, U = SoA.Log, SoA.Epics, SoA.Estimate, SoA.Priority, SoA.Blockers, SoA.Sprint, SoA.Tickets, SoA.Upgrade
	local L = SoA.L
	local hooks = SoA.Hooks or {}
	local plan = {}
	if hooks.Plan then
		local ok, p = pcall(hooks.Plan)
		if ok and type(p) == "table" then plan = p end
	end
	local ctx = {
		level = num(UnitLevel("player"), 1),
		solo = not (IsInGroup and flag(try(IsInGroup))),
		weighting = SoA.char.priority.weighting or "balanced",
	}
	local m = { items = {}, avail = {}, upcoming = {}, done = {}, sprintDone = {}, byKey = {}, epics = {}, ctx = ctx }
	local function addEpic(key, name, color)
		if key and not m.epics[key] then m.epics[key] = { key = key, name = name or "?", color = color } end
	end
	local active, inLog = {}, {}

	-- quests in the log
	for _, q in ipairs(Log:Read()) do
		local pe = plan[q.id]
		local it = {
			kind = "quest", key = q.id, id = q.id, title = q.title, level = q.level, showLevel = q.showLevel,
			ready = q.ready, failed = q.failed, progress = q.progress, objectives = q.objectives,
			elite = q.elite, group = q.group, index = q.index, tagName = q.tagName,
		}
		inLog[q.id] = true
		it.rank = pe and num(pe.rank)
		it.planDistance = pe and num(pe.distance)
		it.zone = q.zone or (pe and pe.zoneMatch) or false
		it.xp = (pe and num(pe.xp)) or Log:RewardXP(q.id)
		it.est = Est:Quest(q, pe and pe.distance)
		it.minutes = it.est.minutes
		if it.xp and it.minutes > 0 then it.xpm = it.xp / it.minutes end
		local e = E:Get(q.id)
		if e then
			it.epic, it.epicKey, it.epicName, it.color, it.campaign = e, e.key, e.name, e.color, e.campaign
			active[e.key] = true
			addEpic(e.key, e.name, e.color)
		else
			it.epicKey = "loose"
		end
		local nextStep = E:NextStep(q.id)
		if nextStep and nextStep.state == "future" then
			it.unlocks = true
			it.blocks = Log:Title(nextStep.questID)
		end
		it.difficulty = Log:Difficulty(q.level)
		it.upgrade = U:ForQuest(q.id)
		if q.ready then it.turnIn = Log:TurnInText(q.id) end
		it.column = q.ready and "ready" or (q.progress and "doing" or "todo")
		SoA.Flow:Apply(it) -- manual moves: forward only until "Resume automatic"
		-- zone story (achievement): the epic of a quest without a questline
		-- dungeon quest: also part of the dungeon's epic (shown as a badge)
		local dk, dn
		if SoA.Dungeons then dk, dn = SoA.Dungeons:ForQuest(q.id) end
		if dk then
			it.dungeonKey, it.dungeonName = "dg:" .. dk, dn
			addEpic(it.dungeonKey, dn, SoA.Dungeons.COLOR)
		end
		local st = SoA.Stories and SoA.Stories:ForQuest(q.id)
		if st then
			it.story, it.storyKey = st, st.key
			addEpic(st.key, st.name, st.color)
			if it.epicKey == "loose" then
				it.epic, it.epicKey, it.epicName, it.color = st, st.key, st.name, st.color
			end
		end
		-- the quest's usable item (display only; the secure button lives in the tracker)
		if GetQuestLogSpecialItemInfo and q.index then
			local link, tex = try(GetQuestLogSpecialItemInfo, q.index)
			local icon = num(tex) or str(tex)
			if str(link) and icon then it.itemLink, it.itemTex = str(link), icon end
		end
		m.items[#m.items + 1] = it
	end

	-- custom tickets (done ones: in the sprint's Done, and this session's in Kanban's Done)
	m.ticketsDone = {}
	for _, t in ipairs(T:All()) do
		local recent = t.status == "done" and num(t.doneAt, 0) >= (SoA.loginTime or 0)
		if t.status ~= "done" or SP:Contains(t.key) or recent then
			local objectives = {}
			for i, c in ipairs(t.checklist or {}) do
				objectives[#objectives + 1] = { text = c.text, done = c.done, check = i }
			end
			local have
			if t.item then
				have = T:ItemCount(t)
				objectives[#objectives + 1] = { text = ("%d/%d %s"):format(math.min(have or 0, t.item.need), t.item.need, tostring(t.item.label or t.item.spec)),
					done = (have or 0) >= t.item.need, have = have, need = t.item.need }
			end
			T:AutoStatus(t, have)
			local mins = num(t.minutes, 15)
			local it = {
				kind = "ticket", key = t.key, title = t.title, ticket = t, objectives = objectives,
				minutes = mins, est = { minutes = mins, low = mins * 0.75, high = mins * 1.5, parts = { L["your estimate"] } },
				ready = t.status == "ready", progress = t.status ~= "todo", column = t.status,
				map = t.map, zone = t.map ~= nil and t.map.m == SoA:PlayerMap(),
			}
			if t.dungeon then
				-- a run card (Dungeons.lua): the dungeon is the epic
				local info = SoA.Dungeons and SoA.Dungeons:Info(t.dungeon)
				local name = (info and info.name) or t.dungeonName or t.dungeon
				it.epicKey, it.epicName, it.color = "dg:" .. t.dungeon, name, SoA.Dungeons.COLOR
				it.dungeonKey = it.epicKey
				addEpic(it.epicKey, name, it.color)
			elseif t.label then
				it.epicKey, it.epicName, it.color = "lb:" .. t.label, t.label, labelColor(t.label)
				addEpic(it.epicKey, t.label, it.color)
			else
				it.epicKey = "loose"
			end
			if t.status == "done" then
				it.doneAt = t.doneAt
				it.kind = "done"
				it.ticketKind = true
				if SP:Contains(t.key) then m.sprintDone[#m.sprintDone + 1] = it end
				if recent then m.ticketsDone[#m.ticketsDone + 1] = it end
			else
				m.items[#m.items + 1] = it
			end
		end
	end

	-- shared mobs: one quest's kills drop another quest's items
	self:Shared(m, ctx)

	-- on hold (manual) with an optional resume condition
	for _, it in ipairs(m.items) do
		local h = SoA.Hold:Get(it.key)
		if h then
			it.onHold, it.holdText = true, SoA.Hold:Text(h)
			it.resumeReady = SoA.Hold:CondMet(h, ctx)
		end
	end

	-- priority, blockers, sprint membership
	local rates = {}
	for _, it in ipairs(m.items) do if it.xpm then rates[#rates + 1] = it.xpm end end
	ctx.median = median(rates)
	for _, it in ipairs(m.items) do
		local reasons = B:Reasons(it, ctx)
		it.blockReasons = reasons
		it.blocked = #reasons > 0
		local auto, why = P:Auto(it, ctx)
		local manual = P:Manual(it.key)
		it.autoPriority, it.why = auto, why
		it.priority = manual or auto
		it.pinned = manual ~= nil
		it.inSprint = SP:Contains(it.key)
		it.holdHint = SoA.Flow:HoldHint(it)
		if SoA.Activity then SoA.Activity:NoteItem(it) end
		m.byKey[it.key] = it
	end

	-- questlines to pick up on this map
	local availSet = {}
	for _, a in ipairs(E:Available()) do
		availSet[a.questID] = true
		local it = {
			kind = "avail", key = "a:" .. a.questID, id = a.questID, title = a.title or (L["Quest"] .. " " .. a.questID),
			epicKey = a.key or "loose", epicName = a.epicName, color = a.color,
			mapID = a.mapID, x = a.x, y = a.y, zone = true, column = "todo", objectives = {}, priority = 3,
		}
		if a.key then addEpic(a.key, a.epicName, a.color) end
		m.avail[#m.avail + 1] = it
		m.byKey[it.key] = it
	end

	-- later steps of active questlines (blocked by the step before them)
	for _, u in ipairs(E:Upcoming(active, availSet)) do
		local it = {
			kind = "upcoming", key = "u:" .. u.questID, id = u.questID,
			title = u.title or (L["Quest"] .. " " .. u.questID), epicKey = u.key, epicName = u.epicName,
			color = u.color, after = u.after or "?", objectives = {}, priority = 4, order = u.order,
		}
		it.blockReasons = B:Reasons(it, ctx)
		it.blocked = true
		m.upcoming[#m.upcoming + 1] = it
		m.byKey[it.key] = it
	end

	-- done: this session, plus finished steps of active epics
	local seenDone = {}
	for _, d in ipairs(SoA.sessionDone) do
		if not seenDone[d.id] then
			seenDone[d.id] = true
			m.done[#m.done + 1] = { kind = "done", key = "d:" .. d.id, id = d.id, title = d.title or (L["Quest"] .. " " .. d.id),
				xp = d.xp, minutes = d.minutes, epicKey = d.epicKey or "loose", epicName = d.epicName, color = d.color,
				objectives = {}, doneAt = d.t, priority = 3 }
		end
	end
	for key in pairs(active) do
		local e = E:ByKey(key)
		for _, s in ipairs(e and e.steps or {}) do
			if s.state == "done" and not seenDone[s.questID] and #m.done < 60 then
				seenDone[s.questID] = true
				m.done[#m.done + 1] = { kind = "done", key = "d:" .. s.questID, id = s.questID,
					title = Log:Title(s.questID) or (L["Quest"] .. " " .. s.questID),
					epicKey = e.key, epicName = e.name, color = e.color, objectives = {}, priority = 3 }
			end
		end
	end

	-- sprint: done quests of this sprint (tickets were added above)
	for key, t in pairs(SP:DoneList()) do
		if type(key) == "number" then
			m.sprintDone[#m.sprintDone + 1] = { kind = "done", key = "d:" .. key, id = key, title = SP:Title(key) or (L["Quest"] .. " " .. key),
				minutes = SP:Committed(key), xp = SP:CommittedXP(key), epicKey = SP:EpicKey(key) or "loose", objectives = {}, doneAt = t, priority = 3 }
		end
	end
	for _, d in ipairs(m.sprintDone) do
		local e = d.epicKey and m.epics[d.epicKey]
		if e then d.epicName, d.color = d.epicName or e.name, d.color or e.color end
	end

	SP:Sync(m)
	SoA.Flow:Track(m)
	return m
end

-- Overlap of a kill objective (quest A) and an item objective (quest B) on the
-- same mobs: done together the effort is max(kills A, expected kills B) x
-- time per kill instead of the sum, split in proportion to each quest's kills.
function M:Shared(m, ctx)
	local Est, SP, S, L = SoA.Estimate, SoA.Sprint, SoA.Style, SoA.L
	local byId = {}
	for _, it in ipairs(m.items) do if it.kind == "quest" then byId[it.id] = it end end
	local kt = Est:KillTime()
	local function obj(it, idx)
		for _, o in ipairs(it.objectives or {}) do if o.index == idx and not o.done then return o end end
	end
	for _, sp in ipairs(Est:SharedPairs()) do
		local A, B = byId[sp.a], byId[sp.b]
		local oa, ob = A and obj(A, sp.ai), B and obj(B, sp.bi)
		if oa and ob and not A.ready and not B.ready and not A.shared and not B.shared then
			local kA = math.max(0, (oa.need or 1) - (oa.have or 0))
			local rate = Est:DropRate(B.id, sp.bi)
			local kB = math.max(0, (ob.need or 1) - (ob.have or 0)) / rate
			if kA > 0 and kB > 0 then
				local inA, inB = SP:Contains(A.key), SP:Contains(B.key)
				local mx = math.max(kA, kB)
				local saveA = (kA - kA / (kA + kB) * mx) * kt / 60
				local saveB = (kB - kB / (kA + kB) * mx) * kt / 60
				local mob = SoA.Activity and SoA.Activity:MobFor(A.id, B.id)
				A.shared = { partnerKey = B.key, partner = B.title, soloMin = A.minutes, role = "kill", mob = mob,
					have = oa.have, need = oa.need, text = oa.text,
					extraMin = math.max(0, kA - kB) * kt / 60 + math.max(0, A.minutes - kA * kt / 60) }
				B.shared = { partnerKey = A.key, partner = A.title, soloMin = B.minutes, role = "item", mob = mob,
					have = ob.have, need = ob.need, text = ob.text,
					extraMin = math.max(0, kB - kA) * kt / 60 + math.max(0, B.minutes - kB * kt / 60) }
				local function apply(it, save, other)
					if save <= 0 then
						it.shared.note = L["Overlaps with %s: saves ~%s when done together"]:format(other.title, S:Minutes(saveA + saveB))
						return
					end
					local e = it.est
					-- the saving comes off the fighting and searching in the breakdown
					local split
					if e.split then
						split = {}
						for k, v in pairs(e.split) do split[k] = v end
						local fs = (split.fight or 0) + (split.search or 0)
						if fs > 0 then
							local f = math.max(0, fs - save * 60) / fs
							split.fight, split.search = (split.fight or 0) * f, (split.search or 0) * f
						end
					end
					it.est = { minutes = math.max(0.5, e.minutes - save), low = math.max(0.3, e.low - save),
						high = math.max(0.5, e.high - save), learned = e.learned, parts = e.parts, split = split }
					it.minutes = it.est.minutes
					it.shared.note = L["Overlaps with %s: saves ~%s when done together"]:format(other.title, S:Minutes(saveA + saveB))
				end
				if inA == inB then
					apply(A, saveA, B)
					apply(B, saveB, A)
				else
					local other, base = inA and B or A, inA and A or B
					other.shared.note = L["Do together with %s: costs ~%s extra instead of %s"]:format(base.title,
						S:Minutes(other.shared.extraMin), S:Minutes(other.shared.soloMin))
				end
				for _, it in ipairs({ A, B }) do
					if it.xp and it.minutes > 0 then it.xpm = it.xp / it.minutes end
				end
				-- a drop attempt in a shared fight counts as progress for the item quest
				if B.column == "todo" then
					local _, enc = Est:DropRate(B.id, sp.bi)
					if enc > 0 then B.column = "doing" end
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Sort modes (List view and compact tracker)
---------------------------------------------------------------------------
M.SORT_LABEL = {
	priority = "Priority", sprint = "Sprint order", status = "Status", epic = "Epic", level = "Level",
	xp = "XP", xpm = "XP/min", estimate = "Estimate", zone = "Zone", distance = "Distance",
	title = "Quest", progress = "Progress", route = "Smart route",
}
local BASE_SORTS = { "priority", "sprint", "status", "epic", "level", "xp", "xpm", "estimate", "zone", "distance" }

-- Available modes; "route" only with a route provider (CasterKit now, Roads later).
function M:SortModes()
	local out = {}
	for _, k in ipairs(BASE_SORTS) do out[#out + 1] = k end
	if SoA.Bridge and SoA.Bridge.attached and SoA.Bridge.HasRoute and SoA.Bridge.HasRoute() then table.insert(out, 1, "route") end
	return out
end

local STATUS_ORDER = { doing = 1, ready = 2, todo = 3, hold = 4, done = 5 }

function M.Progress(it)
	if it.ready then return 1 end
	local sum, n = 0, 0
	for _, o in ipairs(it.objectives or {}) do
		n = n + 1
		if o.done then sum = sum + 1
		elseif o.pct then sum = sum + math.max(0, math.min(100, o.pct)) / 100
		elseif o.need and o.need > 0 then sum = sum + math.min(1, (o.have or 0) / o.need) end
	end
	return n > 0 and sum / n or 0
end

function M.Status(it)
	if it.onHold then return "hold" end
	if it.kind == "done" then return "done" end
	return it.column or "todo"
end

local function distance(it)
	if it._dist == nil then
		it._dist = (it.kind == "quest" and (it.planDistance or SoA.Estimate:Distance(it.id))) or false
	end
	return it._dist or 1e9
end

function M:Sort(list, mode, desc)
	local P = SoA.Priority
	local sprintPos = {}
	if mode == "sprint" then
		local keys = SoA.Sprint:IsActive() and SoA.Sprint:Backend():GetKeys()
		for i, k in ipairs(type(keys) == "table" and keys or {}) do
			local id = type(k) == "string" and tonumber(k:match("^(%d+):") or "")
			if id and not sprintPos[id] then sprintPos[id] = i end
		end
	end
	local function val(it)
		if mode == "sprint" then return sprintPos[it.key] or (it.inSprint and 900 or 1000) end
		if mode == "status" then return STATUS_ORDER[M.Status(it)] or 9 end
		if mode == "epic" then return (it.epicKey == "loose" and "~" or "") .. (it.epicName or "~") end
		if mode == "level" then return it.level or 0 end
		if mode == "xp" then return -(it.xp or 0) end
		if mode == "xpm" then return -(it.xpm or 0) end
		if mode == "estimate" then return it.minutes or 1e6 end
		if mode == "zone" then return it.zone and 0 or 1 end
		if mode == "distance" then return distance(it) end
		if mode == "title" then return it.title or "" end
		if mode == "progress" then return -M.Progress(it) end
		if mode == "route" then return it.rank or 1e6 end
	end
	table.sort(list, function(a, b)
		if mode ~= "priority" then
			local va, vb = val(a), val(b)
			if va ~= vb then
				if desc then return va > vb end
				return va < vb
			end
		elseif desc then
			return P.Compare(b, a)
		end
		return P.Compare(a, b)
	end)
end

function M:OnEnable()
	for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "ZONE_CHANGED_NEW_AREA", "PLAYER_LEVEL_UP" }) do
		SoA:On(ev, function() M:Dirty() SoA:Fire("MODEL_CHANGED") end)
	end
	for _, msg in ipairs({ "EPICS", "ESTIMATES", "MODEL_DIRTY", "SPRINT", "PLAN" }) do
		SoA:Listen(msg, function() M:Dirty() SoA:Fire("MODEL_CHANGED") end)
	end
end
