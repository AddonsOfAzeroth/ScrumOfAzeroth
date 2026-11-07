-- Scrum of Azeroth by DinX: status flow of the cards. Manual moves of quests
-- (afterwards automatic moves only go forward until "Resume automatic"),
-- toasts for automatic moves, "Ready to resume", progress on on-hold quests and
-- the "Put on hold?" hint. Nothing is ever moved, put on hold or resumed by
-- itself: toasts and hints only offer a button.
local _, ns = ...
local SoA = ns.SoA
local num, str = SoA.num, SoA.str

local F = SoA:NewModule("Flow")
local RANK = { todo = 1, doing = 2, ready = 3, done = 4 }
F.RANK = RANK
F.STATUS_LABEL = { todo = "To do", doing = "In progress", ready = "Ready", done = "Done", hold = "On hold" }

-- ScrumOfAzerothCharDB.questStatus = { [questID] = { status, manual, at, lost } }
local function qdb()
	local c = SoA.char
	if not c then return {} end
	if type(c.questStatus) ~= "table" then c.questStatus = {} end
	return c.questStatus
end

function F:Manual(questID)
	local s = qdb()[questID]
	return type(s) == "table" and s.manual and s or nil
end

-- Called while the model builds (no messages): the column of a quest.
function F:Apply(it)
	if it.kind ~= "quest" then return end
	local s = self:Manual(it.id)
	if not s then return end
	local auto = it.column
	if s.lost then
		s.status, s.lost = auto, nil -- a genuine regression moves it back
	elseif (RANK[auto] or 1) > (RANK[s.status] or 1) then
		s.status = auto -- forward only
	end
	it.column = s.status
	it.manualStatus = true
end

function F:SetQuestStatus(questID, status)
	local s = qdb()
	local old = type(s[questID]) == "table" and s[questID].status
	s[questID] = { status = status, manual = true, at = time() }
	F:Forget(questID)
	if SoA.Activity then SoA.Activity:Event(questID, "manual", { from = old, to = status }) end
	SoA:Fire("MODEL_DIRTY")
	if SoA.Hooks and SoA.Hooks.Changed then pcall(SoA.Hooks.Changed) end
end

function F:ResumeAuto(questID)
	qdb()[questID] = nil
	F:Forget(questID)
	if SoA.Activity then SoA.Activity:Event(questID, "auto") end
	SoA:Fire("MODEL_DIRTY")
end

-- Manual move of any card (quests and custom tickets).
function F:MoveTo(it, status)
	if not it then return end
	if it.kind == "quest" then
		self:SetQuestStatus(it.id, status)
	elseif it.kind == "ticket" and SoA.Tickets then
		local t = SoA.Tickets:Get(it.key)
		if t then
			local old = t.status
			t.manual = true
			F:Forget(it.key)
			SoA.Tickets:SetStatus(it.key, status)
			if SoA.Activity then SoA.Activity:Event(it.key, "manual", { from = old, to = status }) end
		end
	end
end

---------------------------------------------------------------------------
-- Changes between two model builds -> toasts and history
---------------------------------------------------------------------------
local last = {}      -- key -> { column, blocked, resume }
local primed = false
local queue = {}

local function flush()
	local L, S = SoA.L, SoA.Style
	local Act = SoA.Activity
	local Toast = SoA.Toast
	local moves = 0
	for _, q in ipairs(queue) do if q.kind == "moved" then moves = moves + 1 end end
	for _, q in ipairs(queue) do
		if q.kind == "moved" then
			if Act then Act:Event(q.key, q.to == "ready" and "ready" or "moved", { from = q.from, to = q.to }) end
			if moves <= 3 then
				Toast:Show(L["Moved to %s: %s"]:format(L[F.STATUS_LABEL[q.to] or q.to], q.title), S.colors.accent)
			end
		elseif q.kind == "blocked" then
			if Act then Act:Event(q.key, q.on and "blocked" or "unblocked", { reason = q.reason }) end
		elseif q.kind == "resume" then
			Toast:Show(L["Ready to resume: %s"]:format(q.title), S.green,
				{ L["Resume"], function() SoA.Hold:Resume(q.key) end }, "resume:" .. tostring(q.key))
		end
	end
	if moves > 3 then Toast:Show(L["%d cards moved automatically."]:format(moves), S.colors.accent) end
	wipe(queue)
end

-- Called at the end of a model build (no messages; the toasts follow a frame later).
function F:Track(m)
	local any = false
	for _, it in ipairs(m.items) do
		if it.kind == "quest" or it.kind == "ticket" then
			local prev = last[it.key]
			local col = it.column
			if prev and primed then
				if prev.column ~= col and not it.onHold then
					queue[#queue + 1] = { kind = "moved", key = it.key, title = it.title, from = prev.column, to = col }
					any = true
				end
				if prev.blocked ~= (it.blocked and true or false) then
					queue[#queue + 1] = { kind = "blocked", key = it.key, on = it.blocked, reason = it.blockReasons and it.blockReasons[1] }
					any = true
				end
				if it.onHold and it.resumeReady and not prev.resume then
					queue[#queue + 1] = { kind = "resume", key = it.key, title = it.title }
					any = true
				end
			end
			last[it.key] = { column = col, blocked = it.blocked and true or false, resume = it.resumeReady and true or false }
		end
	end
	primed = true
	if any then C_Timer.After(0, function() SoA.guard("flow flush", flush) end) end
end

-- A manual move must not toast as an automatic one.
function F:Forget(key) last[key] = nil end

---------------------------------------------------------------------------
-- "Put on hold?" hint: in progress, but away from the zone for 10 min or no
-- progress for the configured time.
---------------------------------------------------------------------------
F.AWAY = 600

function F:HoldHint(it)
	if it.kind ~= "quest" or it.column ~= "doing" or it.onHold or it.ready then return false end
	local Act = SoA.Activity
	if not (Act and Act:Enabled()) then return false end
	local a = Act.Data()
	local now = time()
	local mins = num(SoA.char.toasts and SoA.char.toasts.holdHint, 30)
	local lp = num(a.lastProgress[it.id])
	if not lp then
		a.lastProgress[it.id] = now -- first seen in progress: start the clock
		lp = now
	end
	if mins > 0 and now - lp > mins * 60 then return true, "progress" end
	local z = num(a.lastInZone[it.id])
	if z and now - z > self.AWAY then return true, "away" end
	return false
end

function F:OnEnable()
	-- objective lost: a manual status ahead of it moves back, with a toast
	SoA:Listen("OBJECTIVE_LOST", function(qid, _, _, _, text)
		local s = F:Manual(qid)
		if s then s.lost = true end
		local L = SoA.L
		SoA.Toast:Show(L["Objective lost: %s"]:format(str(text) or SoA.Log:Title(qid) or "?"), SoA.Style.colors.warn)
		SoA:Fire("MODEL_DIRTY")
	end)
	-- progress on a quest you put on hold
	SoA:Listen("OBJECTIVE", function(qid)
		if not (SoA.Hold and SoA.Hold:Get(qid)) then return end
		local L = SoA.L
		local title = SoA.Log:Title(qid) or "?"
		SoA.Toast:Show(L["Progress on an on-hold quest: %s. Resume?"]:format(title), SoA.Style.gold,
			{ L["Resume"], function() SoA.Hold:Resume(qid) end }, "holdprog:" .. qid)
	end)
	local function clear(_, id)
		id = num(id)
		if id then qdb()[id] = nil last[id] = nil end
	end
	SoA:On("QUEST_TURNED_IN", clear)
	SoA:On("QUEST_REMOVED", function(_, id)
		id = num(id)
		if id then C_Timer.After(1, function() if not SoA.Log:InLog(id) then clear(nil, id) end end) end
	end)
end
