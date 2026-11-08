-- Scrum of Azeroth by DinX: Flow view. A zoomable, pannable node graph of an
-- epic (questline) or an initiative (campaign). Every node can be clicked.
-- Plain (insecure) frames only; nothing is built in combat (rebuilds wait for
-- the end of combat). Branches come from quests shared by two questlines,
-- campaign chapters and follow-ups learned from your own play (per account).
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local EF = SoA:NewModule("EpicFlow")
local QLINE, CAMP, QL = C_QuestLine, C_CampaignInfo, C_QuestLog

local MIN_Z, MAX_Z = 0.4, 2.0
local HEAD_H = 30
local MIN_W, MIN_H = 560, 300
local NODE_W, NODE_H = 150, 50
local GAP_X, GAP_Y = 46, 26
local MARGIN = 40
local MINI_W, MINI_H = 140, 80
local LEARN_WINDOW = 600 -- s after a turn-in in which accepted / new quests count as follow-ups
local MAX_SIDE = 30      -- side nodes per graph
local MAX_TARGETS = 8    -- learned follow-ups kept per quest
local REBUILD_WAIT = 1   -- s: quest events are merged
local DASH, DASH_GAP = 7, 5
local LOCK_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK"
local CHECK_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local DISC_TEX = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DUNGEON_TAGS = { [62] = true, [81] = true, [88] = true, [89] = true } -- Raid, Dungeon, Raid (10), Raid (25)
local DUNGEON_COLOR = { 0.70, 0.45, 1.00 }

local DEFAULTS = { showLearned = true, showDone = true, dir = "lr", nodeSize = 1, width = 900, height = 520 }

EF.stack = {}  -- keys for "Back" (initiative -> epic, epic -> linked epic)
EF.names = {}  -- key -> name seen on a chapter or link (for keys Epics does not know yet)

-- ScrumOfAzerothCharDB.flow = { showLearned, showDone, dir ("lr"/"tb"), nodeSize, width, height, point, last }
local function cfg()
	local c = SoA.char
	if not c then return DEFAULTS end
	if type(c.flow) ~= "table" then c.flow = {} end
	for k, v in pairs(DEFAULTS) do if c.flow[k] == nil then c.flow[k] = v end end
	return c.flow
end
EF.Config = cfg

-- ScrumOfAzerothDB.flow = { edges = { [fromQuestID] = { [toQuestID] = count } }, rejected = { [from] = { [to] = true } } }
local function adb()
	local d = SoA.db
	if not d then return { edges = {}, rejected = {} } end
	if type(d.flow) ~= "table" then d.flow = {} end
	if type(d.flow.edges) ~= "table" then d.flow.edges = {} end
	if type(d.flow.rejected) ~= "table" then d.flow.rejected = {} end
	return d.flow
end
EF.Data = adb

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

---------------------------------------------------------------------------
-- Guarded API helpers
---------------------------------------------------------------------------
local lineCache = {}

-- Quests of a questline in order (C_QuestLine.GetQuestLineQuests), or nil.
local function lineQuests(lineID)
	lineID = num(lineID)
	if not (lineID and QLINE and QLINE.GetQuestLineQuests) then return end
	if lineCache[lineID] then return lineCache[lineID] end
	local list = try(QLINE.GetQuestLineQuests, lineID)
	if type(list) ~= "table" then return end
	local ids = {}
	for _, v in ipairs(list) do
		local id = num(v) or (type(v) == "table" and num(v.questID)) or nil
		if id then ids[#ids + 1] = id end
	end
	if #ids > 0 then
		lineCache[lineID] = ids
		return ids
	end
end

local function lineIDOf(key)
	return type(key) == "string" and tonumber(key:match("^ql:(%d+)$") or "") or nil
end

-- Campaign ID of an epic (a "cp:" key, or the first of its quests that has one).
local function campaignFor(e)
	if not e then return end
	local cp = type(e.key) == "string" and tonumber(e.key:match("^cp:(%d+)$") or "")
	if cp then return cp end
	if not (e.campaign and CAMP and CAMP.GetCampaignID) then return end
	local ids = e.ids or e.order or {}
	for i = 1, math.min(#ids, 10) do
		local cid = num(try(CAMP.GetCampaignID, ids[i]))
		if cid and cid > 0 then return cid end
	end
end

local function campaignName(cid, e)
	local info = CAMP and CAMP.GetCampaignInfo and try(CAMP.GetCampaignInfo, cid)
	return (type(info) == "table" and str(info.name)) or (e and e.campaignName) or (SoA.L["Initiative"] .. " " .. cid)
end

local function chapterIDs(cid)
	local out = {}
	local list = CAMP and CAMP.GetChapterIDs and try(CAMP.GetChapterIDs, cid)
	if type(list) == "table" then
		for _, c in ipairs(list) do
			c = num(c)
			if c then out[#out + 1] = c end
		end
	end
	return out
end

local function chapterName(chapterID)
	local ci = CAMP and CAMP.GetCampaignChapterInfo and try(CAMP.GetCampaignChapterInfo, chapterID)
	return type(ci) == "table" and str(ci.name) or nil
end

-- Name of an epic or initiative key.
function EF:KeyName(key)
	if type(key) ~= "string" then return SoA.L["Pick an epic"] end
	local cid = tonumber(key:match("^in:(%d+)$") or "")
	if cid then return campaignName(cid) end
	local e = SoA.Epics:ByKey(key)
	if not e and key:sub(1, 3) == "st:" and SoA.Stories then e = SoA.Stories:ByKey(key) end
	if e and e.name and e.name ~= "?" then return e.name end
	if self.names[key] then return self.names[key] end
	local lid = lineIDOf(key)
	if lid then return SoA.L["Questline %d"]:format(lid) end
	return key
end

-- Level of a quest that is not in the log (nil when unknown).
local function questLevel(id)
	local lv = QL and QL.GetQuestDifficultyLevel and num(try(QL.GetQuestDifficultyLevel, id))
	if lv and lv > 0 then return lv end
end

-- Dungeon / raid tag name of a quest, or nil.
local tagCache = {}
local function dungeonTag(id)
	if tagCache[id] then return tagCache[id] end
	local tagID, tagName
	if QL and QL.GetQuestTagInfo then
		local info = try(QL.GetQuestTagInfo, id)
		if type(info) == "table" then tagID, tagName = num(info.tagID), str(info.tagName) end
	elseif GetQuestTagInfo then
		local a, b = try(GetQuestTagInfo, id)
		tagID, tagName = num(a), str(b)
	end
	local T = Enum and Enum.QuestTag
	local hit = tagID and (DUNGEON_TAGS[tagID] or (T and (tagID == T.Dungeon or tagID == T.Raid))) or false
	if not hit and tagName then
		local low = tagName:lower()
		hit = low:find("dungeon", 1, true) or low:find("raid", 1, true) or tagName == _G.LFG_TYPE_DUNGEON or tagName == _G.LFG_TYPE_RAID
	end
	if hit then
		tagCache[id] = tagName or SoA.L["Dungeon"]
		return tagCache[id]
	end
end

---------------------------------------------------------------------------
-- Learned links: QUEST_TURNED_IN, then quests accepted within 10 minutes or
-- newly available on the map (GetAvailableQuestLines) are follow-up candidates.
---------------------------------------------------------------------------
local lastTurn -- { id, t, avail = set, seen = set, diff = fn }

local function availSet()
	local set = {}
	local list = SoA.Epics and SoA.Epics:Available() or {}
	for _, a in ipairs(list) do if a.questID then set[a.questID] = true end end
	return set
end

local function isRejected(from, to)
	local r = adb().rejected[from]
	return type(r) == "table" and r[to] and true or false
end

function EF:Observe(from, to)
	from, to = num(from), num(to)
	if not (from and to) or from == to or isRejected(from, to) then return end
	local edges = adb().edges
	local t = edges[from]
	if type(t) ~= "table" then t = {} edges[from] = t end
	t[to] = math.min(99, num(t[to], 0) + 1)
	-- keep the strongest few follow-ups per quest
	local n, weakest, wv = 0, nil, math.huge
	for k, v in pairs(t) do
		n = n + 1
		if k ~= to and num(v, 0) < wv then weakest, wv = k, num(v, 0) end
	end
	if n > MAX_TARGETS and weakest then t[weakest] = nil end
	self:Schedule()
end

local function observeOnce(turn, to)
	to = num(to)
	if not to or turn.seen[to] then return end
	turn.seen[to] = true
	EF:Observe(turn.id, to)
end

local function onTurnIn(_, questID)
	questID = num(questID)
	if not questID then return end
	local turn = { id = questID, t = GetTime(), avail = availSet(), seen = {} }
	lastTurn = turn
	function turn.diff()
		if lastTurn ~= turn or GetTime() - turn.t > LEARN_WINDOW then return end
		for id in pairs(availSet()) do
			if not turn.avail[id] then
				turn.avail[id] = true
				observeOnce(turn, id)
			end
		end
	end
	C_Timer.After(3, function() SoA.guard("flow learn", turn.diff) end)
	C_Timer.After(12, function() SoA.guard("flow learn", turn.diff) end)
end

-- QUEST_ACCEPTED: (questID) on newer clients, (logIndex, questID) on older ones.
local function onAccept(_, a, b)
	local questID = num(b) or num(a)
	local turn = lastTurn
	if not (questID and turn) or GetTime() - turn.t > LEARN_WINDOW then return end
	turn.avail[questID] = true
	observeOnce(turn, questID)
end

-- 2 observations, or 1 when the questline has `to` after `from`.
local function lineConfirms(from, to, inLine)
	if inLine and inLine[from] and inLine[to] then return inLine[to] > inLine[from] end
	local e = SoA.Epics:Get(from)
	if not (e and e.ids) then return false end
	local fi, ti
	for i, id in ipairs(e.ids) do
		if id == from then fi = i elseif id == to then ti = i end
	end
	return fi ~= nil and ti ~= nil and ti > fi
end

local function confirmed(from, to, count, inLine)
	count = num(count, 0)
	if count >= 2 then return true end
	return count >= 1 and lineConfirms(from, to, inLine)
end

function EF:RemoveLink(from, to)
	from, to = num(from), num(to)
	if not (from and to) then return end
	local d = adb()
	if type(d.edges[from]) == "table" then
		d.edges[from][to] = nil
		if next(d.edges[from]) == nil then d.edges[from] = nil end
	end
	if type(d.rejected[from]) ~= "table" then d.rejected[from] = {} end
	d.rejected[from][to] = true
	self:Rebuild()
end

function EF:ResetLearned()
	local d = adb()
	wipe(d.edges)
	wipe(d.rejected)
	self:Rebuild()
end

---------------------------------------------------------------------------
-- Graph model: nodes on a grid (col along the main line, row 0 = main line,
-- rows 1+ = side branches), edges between nodes.
---------------------------------------------------------------------------
local function newGraph(kind)
	return { kind = kind, nodes = {}, edges = {}, byKey = {}, occ = {} }
end

local function occupy(g, col, row)
	g.occ[col] = g.occ[col] or {}
	if row then g.occ[col][row] = true return row end
	local r = 1
	while g.occ[col][r] do r = r + 1 end
	g.occ[col][r] = true
	return r
end

local function addNode(g, key, n, col, row)
	if g.byKey[key] then return g.byKey[key] end
	n.key, n.col = key, col
	n.row = occupy(g, col, row)
	g.nodes[#g.nodes + 1] = n
	g.byKey[key] = n
	return n
end

-- opts: dashed, learned = { from, to }, color
local function addEdge(g, a, b, opts)
	if not (a and b) or a == b then return end
	for _, e in ipairs(g.edges) do
		if e.a == a and e.b == b then
			if opts and opts.learned then e.confirmed = opts.learned end
			return e
		end
	end
	local e = { a = a, b = b }
	if opts then e.dashed, e.learned, e.color = opts.dashed, opts.learned, opts.color end
	g.edges[#g.edges + 1] = e
	return e
end

-- Node data of one quest: status, icon reason, item from the model, minutes.
local function questNode(id, prevTitle, ctx, m)
	local L = SoA.L
	local Log = SoA.Log
	local it = m.byKey[id]
	local n = { kind = "quest", questID = id }
	n.title = (it and it.title) or Log:Title(id) or (L["Quest"] .. " " .. id)
	n.dungeon = dungeonTag(id)
	if it and it.kind == "quest" then
		n.item = it
		n.level, n.levelColor = it.showLevel or it.level, it.level
		if it.onHold then
			n.status = "hold"
		elseif it.blocked then
			n.status = "blocked"
			n.reason = it.blockReasons and it.blockReasons[1]
		else
			n.status = "current"
		end
		if it.progress or it.ready then n.progress = SoA.Model.Progress(it) end
		n.minutes = num(it.minutes)
		n.shared = it.shared and true or false
	elseif Log:IsDone(id) then
		n.status = "done"
		if SoA.Activity and SoA.Activity:Enabled() then
			local s = SoA.Activity:Stats(id)
			local secs = s and num(s.active, 0) or 0
			if secs > 0 then n.actual = secs / 60 end
		end
	else
		n.item = m.byKey["u:" .. id] or m.byKey["a:" .. id]
		n.available = m.byKey["a:" .. id] ~= nil
		n.status = "upcoming"
		local lv = questLevel(id)
		n.level, n.levelColor = lv, lv
		if lv and lv >= ctx.level + ctx.margin then
			n.status = "blocked"
			n.reason = L["Level %d needed (you are %d)"]:format(lv - ctx.margin + 1, ctx.level)
		elseif not n.available and prevTitle then
			n.lock = L["After: %s"]:format(prevTitle)
		end
	end
	return n
end

local function context()
	local B = SoA.Blockers
	return { level = num(UnitLevel("player"), 1), margin = (B and B.Config and num(B.Config().margin, 4)) or 4 }
end

-- Fallback: a grid of quests without edges and a message.
function EF:BuildList(ids, message, title)
	local g = newGraph("list")
	g.message, g.title = message, title
	local m, ctx = SoA.Model:Get(), context()
	local perRow = 5
	for i, id in ipairs(ids or {}) do
		if i > 60 then break end
		local n = questNode(id, nil, ctx, m)
		n.lock = nil
		addNode(g, "q:" .. id, n, (i - 1) % perRow, math.floor((i - 1) / perRow))
	end
	return g
end

local function looseQuests()
	local out = {}
	for _, it in ipairs(SoA.Model:Get().items) do
		if it.kind == "quest" and it.epicKey == "loose" then out[#out + 1] = it.id end
	end
	return out
end

-- Epic (questline) graph.
function EF:BuildEpic(key)
	local L, E = SoA.L, SoA.Epics
	local c = cfg()
	local e = E:ByKey(key)
	local lid = lineIDOf(key) or (e and e.lineID)
	local ids = (e and e.ids) or lineQuests(lid)
	local title = self:KeyName(key)
	if not (ids and #ids > 0) then
		return self:BuildList((e and e.order) or looseQuests(), L["Not enough data for a flow"], title)
	end
	local g = newGraph("epic")
	g.title, g.color = title, (e and e.color) or E:ColorFor(lid or 0)
	local m, ctx = SoA.Model:Get(), context()
	local inLine = {}
	for i, id in ipairs(ids) do inLine[id] = i end
	g.inLine = inLine

	-- main line, left to right in questline order
	local col, prev, prevTitle, hidden = 0, nil, nil, 0
	local main = {}
	for i, id in ipairs(ids) do
		local n = questNode(id, prevTitle, ctx, m)
		n.order = i
		if n.status == "done" and not c.showDone then
			hidden = hidden + 1
		else
			addNode(g, "q:" .. id, n, col, 0)
			addEdge(g, prev, n)
			main[#main + 1] = n
			prev = n
			col = col + 1
		end
		prevTitle = n.title
	end
	local firstCol, lastCol = 0, col - 1
	if hidden > 0 then
		local d = addNode(g, "done", { kind = "done", count = hidden, status = "done", title = L["%d done"]:format(hidden) }, -1, 0)
		addEdge(g, d, main[1])
		firstCol = -1
		if not main[1] then lastCol = -1 end
	end
	local function first() return g.byKey.done or main[1] end
	local function last() return main[#main] or g.byKey.done end

	-- (b) campaign chapters: previous / next chapter at the edges
	local cid = e and campaignFor(e)
	if cid then
		local chapters = chapterIDs(cid)
		local idx
		for i, ch in ipairs(chapters) do if ch == lid then idx = i end end
		if idx then
			for _, d in ipairs({ { idx - 1, firstCol - 1, true }, { idx + 1, lastCol + 1, false } }) do
				local ch = chapters[d[1]]
				if ch then
					local k = "ql:" .. ch
					local name = chapterName(ch) or self:KeyName(k)
					self.names[k] = name
					local n = addNode(g, "e:" .. k, { kind = "epic", epicKey = k, title = name, color = E:ColorFor(ch),
						sub = d[3] and L["Previous chapter"] or L["Next chapter"], incoming = d[3] }, d[2], 0)
					if d[3] then addEdge(g, n, first(), { color = n.color }) else addEdge(g, last(), n, { color = n.color }) end
				end
			end
		else
			local k = "in:" .. cid
			local n = addNode(g, "e:" .. k, { kind = "epic", epicKey = k, title = campaignName(cid, e), color = SoA.Style.colors.proc,
				sub = L["Initiative"], incoming = true }, firstCol - 1, 0)
			addEdge(g, n, first())
		end
	end

	-- (a) quests that are in another questline too: a link node to that epic
	for k, me in pairs(m.epics) do
		if k ~= key and type(k) == "string" and k:sub(1, 3) == "ql:" then
			local oe = E:ByKey(k)
			local oids = (oe and oe.ids) or lineQuests(lineIDOf(k))
			if oids then
				for j, qid in ipairs(oids) do
					local qn = g.byKey["q:" .. qid]
					if qn and not g.byKey["e:" .. k] then
						local continues = j < #oids
						local n = addNode(g, "e:" .. k, { kind = "epic", epicKey = k, title = (oe and oe.name) or me.name or self:KeyName(k),
							color = (oe and oe.color) or me.color, sub = L["Other epic"], incoming = not continues },
							qn.col + (continues and 1 or -1))
						if continues then addEdge(g, qn, n, { color = n.color }) else addEdge(g, n, qn, { color = n.color }) end
					end
				end
			end
		end
	end

	-- (c) learned links (dashed)
	if c.showLearned then
		local edges, side = adb().edges, 0
		local function visible(id)
			return c.showDone or not SoA.Log:IsDone(id)
		end
		local function sideNode(id, anchor, outgoing)
			local n = g.byKey["q:" .. id]
			if n then return n end
			if side >= MAX_SIDE or inLine[id] or not visible(id) then return end
			side = side + 1
			n = questNode(id, outgoing and anchor.title or nil, ctx, m)
			n.side = true
			local oe = E:Get(id)
			if oe and oe.key ~= key then n.epicName, n.epicColor = oe.name, oe.color end
			return addNode(g, "q:" .. id, n, anchor.col + (outgoing and 1 or -1))
		end
		local snapshot = {}
		for _, n in ipairs(g.nodes) do if n.kind == "quest" then snapshot[#snapshot + 1] = n end end
		for _, n in ipairs(snapshot) do
			local t = edges[n.questID]
			if type(t) == "table" then
				for to, cnt in pairs(t) do
					to = num(to)
					if to and not isRejected(n.questID, to) and confirmed(n.questID, to, cnt, inLine) then
						local tn = sideNode(to, n, true)
						if tn then
							local ed = addEdge(g, n, tn, { dashed = true, learned = { n.questID, to } })
							if ed and ed.learned then tn.learnedCount = num(cnt, 0) end
						end
					end
				end
			end
		end
		for from, t in pairs(edges) do
			from = num(from)
			if from and type(t) == "table" and not inLine[from] then
				for to, cnt in pairs(t) do
					to = num(to)
					local tn = to and inLine[to] and g.byKey["q:" .. to]
					if tn and not isRejected(from, to) and confirmed(from, to, cnt, inLine) then
						local fn = sideNode(from, tn, false)
						if fn then
							addEdge(g, fn, tn, { dashed = true, learned = { from, to } })
							fn.learnedCount = num(cnt, 0)
						end
					end
				end
			end
		end
	end
	return g
end

-- Initiative (campaign) graph: its chapters / epics as blocks.
function EF:BuildInitiative(cid)
	local L, E = SoA.L, SoA.Epics
	local m = SoA.Model:Get()
	local g = newGraph("initiative")
	g.title, g.color = campaignName(cid), SoA.Style.colors.proc
	local list = {}
	for _, ch in ipairs(chapterIDs(cid)) do list[#list + 1] = { chapterID = ch } end
	if #list == 0 then
		-- no chapter API: the known epics of this campaign
		for k in pairs(m.epics) do
			local e = type(k) == "string" and k:sub(1, 3) == "ql:" and E:ByKey(k)
			if e and campaignFor(e) == cid then list[#list + 1] = { epicKey = k, name = e.name } end
		end
		table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
	end
	if #list == 0 then
		local cp = E:ByKey("cp:" .. cid)
		return self:BuildList(cp and cp.order or looseQuests(), L["Not enough data for a flow"], g.title)
	end
	local cur = CAMP and CAMP.GetCurrentChapterID and num(try(CAMP.GetCurrentChapterID, cid))
	local curIdx
	for i, ch in ipairs(list) do if ch.chapterID and ch.chapterID == cur then curIdx = i end end
	local prev
	for i, ch in ipairs(list) do
		local n = { kind = "chapter", chapterID = ch.chapterID }
		if ch.chapterID then
			n.title = chapterName(ch.chapterID) or L["Chapter %d"]:format(i)
			if lineQuests(ch.chapterID) then n.epicKey = "ql:" .. ch.chapterID end
			if not n.epicKey then
				-- a known epic with this chapter's name
				for k in pairs(m.epics) do
					local e = type(k) == "string" and k:sub(1, 3) == "ql:" and E:ByKey(k)
					if e and e.name == n.title then n.epicKey = k end
				end
			end
		else
			n.epicKey, n.title = ch.epicKey, ch.name
		end
		if n.epicKey then
			self.names[n.epicKey] = n.title
			local e = E:ByKey(n.epicKey)
			local ids = (e and e.ids) or lineQuests(lineIDOf(n.epicKey))
			if ids then
				local done = 0
				for _, id in ipairs(ids) do if SoA.Log:IsDone(id) then done = done + 1 end end
				n.done, n.total = done, #ids
			end
			n.color = (e and e.color) or E:ColorFor(lineIDOf(n.epicKey) or i)
		end
		if curIdx then
			n.status = (i < curIdx and "done") or (i == curIdx and "current") or "upcoming"
		elseif n.total and n.total > 0 then
			n.status = (n.done == n.total and "done") or (n.done > 0 and "current") or "upcoming"
		else
			n.status = "upcoming"
		end
		if n.total and n.total > 0 and n.status ~= "done" then n.progress = n.done / n.total end
		addNode(g, "c:" .. i, n, i - 1, 0)
		addEdge(g, prev, n)
		prev = n
	end
	return g
end

function EF:Build(key)
	local L = SoA.L
	if type(key) ~= "string" then
		return self:BuildList(looseQuests(), L["Pick an epic or initiative above."], L["Pick an epic"])
	end
	local cid = tonumber(key:match("^in:(%d+)$") or "")
	if cid then return self:BuildInitiative(cid) end
	if key:sub(1, 3) == "st:" then
		local st = SoA.Stories and SoA.Stories:ByKey(key)
		local ids = {}
		for _, s in ipairs(st and st.steps or {}) do if s.questID then ids[#ids + 1] = s.questID end end
		return self:BuildList(ids, L["Zone stories have no fixed order."], self:KeyName(key))
	end
	return self:BuildEpic(key)
end

---------------------------------------------------------------------------
-- Layout: grid -> canvas pixels (y down)
---------------------------------------------------------------------------
local function ports(a, b, lr, gx, gy)
	local ax, ay, aw, ah = a.x, a.y, a.w, a.h
	local bx, by, bw, bh = b.x, b.y, b.w, b.h
	if a.row == b.row and math.abs(b.col - a.col) > 1 then
		-- skips nodes on the same row: detour beside them
		if lr then
			local y = math.max(ay + ah, by + bh) + gy * 0.45
			return { ax + aw / 2, ay + ah, ax + aw / 2, y, bx + bw / 2, y, bx + bw / 2, by + bh }
		end
		local x = math.max(ax + aw, bx + bw) + gx * 0.3
		return { ax + aw, ay + ah / 2, x, ay + ah / 2, x, by + bh / 2, bx + bw, by + bh / 2 }
	end
	if b.col > a.col then
		if lr then return { ax + aw, ay + ah / 2, bx, by + bh / 2 } end
		return { ax + aw / 2, ay + ah, bx + bw / 2, by }
	elseif b.col < a.col then
		if lr then return { ax, ay + ah / 2, bx + bw, by + bh / 2 } end
		return { ax + aw / 2, ay, bx + bw / 2, by + bh }
	end
	if lr then
		if b.row > a.row then return { ax + aw / 2, ay + ah, bx + bw / 2, by } end
		return { ax + aw / 2, ay, bx + bw / 2, by + bh }
	end
	if b.row > a.row then return { ax + aw, ay + ah / 2, bx, by + bh / 2 } end
	return { ax, ay + ah / 2, bx + bw, by + bh / 2 }
end

function EF:Place(g)
	local c = cfg()
	local sz = clamp(num(c.nodeSize, 1), 0.6, 1.6)
	local w, h = NODE_W * sz, NODE_H * sz
	local gx, gy = GAP_X * sz, GAP_Y * sz
	local lr = c.dir ~= "tb" or g.kind == "list"
	local minCol, minRow, maxX, maxY = math.huge, math.huge, 0, 0
	for _, n in ipairs(g.nodes) do
		minCol, minRow = math.min(minCol, n.col), math.min(minRow, n.row)
	end
	local top = MARGIN + (g.message and 30 or 0)
	for _, n in ipairs(g.nodes) do
		local cc, rr = n.col - minCol, n.row - minRow
		n.w, n.h = w, h
		if lr then
			n.x, n.y = MARGIN + cc * (w + gx), top + rr * (h + gy)
		else
			n.x, n.y = MARGIN + rr * (w + gx), top + cc * (h + gy * 1.4)
		end
		maxX, maxY = math.max(maxX, n.x + w), math.max(maxY, n.y + h)
	end
	for _, e in ipairs(g.edges) do e.pts = ports(e.a, e.b, lr, gx, gy) end
	g.w, g.h = maxX + MARGIN, maxY + MARGIN + gy
	g.sz = sz
end

---------------------------------------------------------------------------
-- Pools: node frames and lines
---------------------------------------------------------------------------
local STATUS_LABEL = { done = "Done", current = "In progress", upcoming = "Upcoming", blocked = "Blocked", hold = "On hold" }

local function statusColor(st)
	local S = SoA.Style
	if st == "done" then return S.green end
	if st == "current" then return S.colors.accent end
	if st == "blocked" then return S.colors.warn end
	if st == "hold" then return { 0.45, 0.45, 0.45 } end
	return { 0.50, 0.52, 0.56 }
end

local function newNodeFrame(parent)
	local S = SoA.Style
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	S:Backdrop(b, 1)
	b:SetBackdropColor(unpack(S.card))
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b.stripe = b:CreateTexture(nil, "ARTWORK")
	b.stripe:SetPoint("TOPLEFT", 1, -1)
	b.stripe:SetPoint("BOTTOMLEFT", 1, 1)
	b.stripe:SetWidth(3)
	b.stripe:SetColorTexture(1, 1, 1, 1)
	b.icon = b:CreateTexture(nil, "OVERLAY")
	b.hole = b:CreateTexture(nil, "OVERLAY", nil, 2) -- inner disc: makes a ring
	b.hole:SetPoint("CENTER", b.icon, "CENTER")
	b.title = S:Font(b, 11)
	b.title:SetJustifyH("LEFT")
	b.title:SetWordWrap(false)
	b.sub = S:Font(b, 9)
	b.sub:SetJustifyH("LEFT")
	b.sub:SetWordWrap(false)
	b.level = S:Font(b, 10)
	b.level:SetJustifyH("LEFT")
	b.mins = S:Font(b, 10)
	b.mins:SetJustifyH("RIGHT")
	b.mins:SetTextColor(unpack(S.colors.muted))
	b.bar = S:StatusBar(b, S.colors.accent)
	b.bar:SetMinMaxValues(0, 1)
	b.bar:SetPoint("BOTTOMLEFT", 4, 2)
	b.bar:SetPoint("BOTTOMRIGHT", -2, 2)
	b.bar:SetHeight(2)
	b.chain = S:ChainIcon(b)
	b.chain:EnableMouse(false)
	b:SetScript("OnClick", function(self, button) SoA.guard("flow click", EF.NodeClick, EF, self, button) end)
	b:SetScript("OnEnter", function(self) SoA.guard("flow tip", EF.NodeTip, EF, self) end)
	b:SetScript("OnLeave", function(self)
		local n = self.node
		self:SetBackdropBorderColor(unpack(statusColor(n and n.status)))
		if n and n.kind == "epic" and n.color then self:SetBackdropBorderColor(unpack(n.color)) end
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)
	return b
end

local function setIcon(b, n, size)
	local S = SoA.Style
	local ic, hole = b.icon, b.hole
	ic:SetSize(size, size)
	ic:SetTexCoord(0, 1, 0, 1)
	ic:SetVertexColor(1, 1, 1, 1)
	hole:Hide()
	ic:Show()
	if n.kind == "epic" then
		ic:Hide()
	elseif n.status == "done" then
		ic:SetTexture(CHECK_TEX)
	elseif n.status == "blocked" or n.lock then
		ic:SetTexture(LOCK_TEX)
		local c = n.status == "blocked" and S.colors.warn or S.colors.muted
		ic:SetVertexColor(c[1], c[2], c[3], 1)
	elseif n.status == "current" then
		ic:SetTexture(DISC_TEX)
		ic:SetSize(size * 0.7, size * 0.7)
		ic:SetVertexColor(S.colors.accent[1], S.colors.accent[2], S.colors.accent[3], 1)
	else -- upcoming / on hold: a ring
		ic:SetTexture(DISC_TEX)
		ic:SetSize(size * 0.7, size * 0.7)
		local c = statusColor(n.status)
		ic:SetVertexColor(c[1], c[2], c[3], 1)
		hole:SetTexture(DISC_TEX)
		hole:SetSize(size * 0.42, size * 0.42)
		hole:SetVertexColor(S.card[1], S.card[2], S.card[3], 1)
		hole:Show()
	end
end

function EF:FillNode(b, n, sz)
	local L, S = SoA.L, SoA.Style
	b.node = n
	b:SetSize(n.w, n.h)
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", n.x, -n.y)
	local pad = 5 * sz
	local isize = math.floor(12 * sz + 0.5)
	b.icon:ClearAllPoints()
	b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", pad + 2, -pad)
	setIcon(b, n, isize)
	S:SetFont(b.title, math.floor(11 * sz + 0.5))
	S:SetFont(b.sub, math.max(7, math.floor(9 * sz + 0.5)))
	S:SetFont(b.level, math.max(7, math.floor(10 * sz + 0.5)))
	S:SetFont(b.mins, math.max(7, math.floor(10 * sz + 0.5)))
	b.title:ClearAllPoints()
	if n.kind == "epic" then
		b.title:SetPoint("TOPLEFT", b, "TOPLEFT", pad + 2, -pad)
	else
		b.title:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 4, 0)
	end
	b.title:SetPoint("RIGHT", b, "RIGHT", -(pad + (n.shared and 14 or 0)), 0)
	b.sub:ClearAllPoints()
	b.sub:SetPoint("TOPLEFT", b, "TOPLEFT", pad + 2, -(pad + isize + 3 * sz))
	b.sub:SetPoint("RIGHT", b, "RIGHT", -pad, 0)
	b.level:ClearAllPoints()
	b.level:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", pad + 2, pad)
	b.mins:ClearAllPoints()
	b.mins:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -pad, pad)
	b.chain:ClearAllPoints()
	b.chain:SetPoint("TOPRIGHT", b, "TOPRIGHT", -3, -4)
	b.chain:SetShown(n.shared and true or false)

	local border = statusColor(n.status)
	local stripe = border
	local title, sub, level, mins = n.title or "?", "", "", ""
	if n.kind == "quest" then
		if n.dungeon then stripe = DUNGEON_COLOR end
		if n.epicColor then stripe = n.epicColor end
		sub = n.reason or n.lock or (n.dungeon and n.dungeon) or (n.epicName and ("» " .. n.epicName))
			or (n.available and L["Available"]) or (n.status == "hold" and L["On hold"]) or ""
		if n.level then
			local r, g, bb = SoA.Log:LevelColor(n.levelColor or n.level)
			level = ("|cff%02x%02x%02x[%d]|r"):format(r * 255, g * 255, bb * 255, n.level)
		end
		if n.status == "done" and n.actual then
			mins = "|cff4ce64c" .. S:Minutes(n.actual) .. "|r"
		elseif n.minutes and n.status ~= "done" then
			mins = "~" .. S:Minutes(n.minutes)
		end
		if n.progress and n.status ~= "done" then
			mins = ("%d%%  "):format(n.progress * 100 + 0.5) .. mins
		end
	elseif n.kind == "epic" then
		border = n.color or S.colors.proc
		stripe = border
		title = (n.incoming and "« " or "") .. title .. (n.incoming and "" or " »")
		sub = n.sub or ""
		mins = "|cff" .. S:Hex(S.colors.muted) .. L["Open flow"] .. "|r"
	elseif n.kind == "chapter" then
		stripe = n.color or border
		sub = n.total and L["%d of %d steps done"]:format(n.done or 0, n.total) or L["No questline data"]
		mins = n.epicKey and ("|cff" .. S:Hex(S.colors.muted) .. L["Zoom in"] .. "|r") or ""
	elseif n.kind == "done" then
		sub = L["Click to show"]
	end
	b.title:SetText(title)
	b.title:SetTextColor(unpack(n.status == "upcoming" and S.colors.muted or S.colors.text))
	b.sub:SetText(sub)
	b.sub:SetTextColor(unpack((n.status == "blocked" and S.colors.warn) or (n.dungeon and DUNGEON_COLOR) or S.colors.muted))
	b.level:SetText(level)
	b.mins:SetText(mins)
	b:SetBackdropBorderColor(border[1], border[2], border[3], 1)
	b.stripe:SetVertexColor(stripe[1], stripe[2], stripe[3], 1)
	if n.kind == "epic" then
		b:SetBackdropColor(0.05, 0.06, 0.09, 0.95)
	else
		b:SetBackdropColor(unpack(S.card))
	end
	if n.progress and n.status ~= "done" then
		b.bar:SetValue(n.progress)
		b.bar:Show()
	else
		b.bar:Hide()
	end
	b:SetAlpha(n.status == "hold" and 0.55 or 1)
	b:Show()
end

function EF:Line()
	self.lineUsed = self.lineUsed + 1
	local l = self.lines[self.lineUsed]
	if not l then
		l = self.canvas:CreateLine(nil, "ARTWORK")
		self.lines[self.lineUsed] = l
	end
	l:Show()
	return l
end

local function lineThickness(base, z)
	return base * clamp(z, 0.75, 1.5) / z -- on screen: base x zoom, kept between 0.75x and 1.5x
end

function EF:Seg(x1, y1, x2, y2, c, base)
	local l = self:Line()
	l:SetColorTexture(c[1], c[2], c[3], c[4] or 0.85)
	l:SetStartPoint("TOPLEFT", self.canvas, x1, -y1)
	l:SetEndPoint("TOPLEFT", self.canvas, x2, -y2)
	l.base = base
	l:SetThickness(lineThickness(base, self.view.z))
end

function EF:DrawEdge(e, sz)
	local S = SoA.Style
	local p = e.pts
	if not p or #p < 4 then return end
	local c
	if e.color then c = { e.color[1], e.color[2], e.color[3], 0.8 }
	elseif e.dashed then c = { S.colors.accent[1], S.colors.accent[2], S.colors.accent[3], 0.85 }
	elseif e.a.status == "done" and e.b.status == "done" then c = { S.green[1], S.green[2], S.green[3], 0.6 }
	else c = { 0.60, 0.65, 0.71, 0.75 } end
	local base = 2
	for i = 1, #p - 2, 2 do
		local x1, y1, x2, y2 = p[i], p[i + 1], p[i + 2], p[i + 3]
		if e.dashed then
			local dx, dy = x2 - x1, y2 - y1
			local len = math.sqrt(dx * dx + dy * dy)
			if len > 0 then
				local step = (DASH + DASH_GAP) * sz
				local count = math.min(60, math.max(1, math.floor(len / step + 0.5)))
				local ux, uy = dx / len, dy / len
				local dl = math.min(DASH * sz, len / count)
				for k = 0, count - 1 do
					local s = k * len / count
					self:Seg(x1 + ux * s, y1 + uy * s, x1 + ux * (s + dl), y1 + uy * (s + dl), c, base)
				end
			end
		else
			self:Seg(x1, y1, x2, y2, c, base)
		end
	end
	-- arrow head at the end
	local n = #p
	local x1, y1, x2, y2 = p[n - 3], p[n - 2], p[n - 1], p[n]
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len > 0 then
		local ux, uy = dx / len, dy / len
		local a = 7 * sz
		for _, s in ipairs({ 0.45, -0.45 }) do
			local cs, sn = math.cos(s), math.sin(s)
			local rx, ry = ux * cs - uy * sn, ux * sn + uy * cs
			self:Seg(x2, y2, x2 - rx * a, y2 - ry * a, c, base)
		end
	end
end

---------------------------------------------------------------------------
-- Rebuild and draw (never in combat)
---------------------------------------------------------------------------
function EF:Rebuild()
	local f = self.frame
	if not (f and f:IsShown()) then return end
	if InCombatLockdown() then
		self.pending = true
		f.combat:Show()
		return
	end
	self.pending = false
	f.combat:Hide()
	if SoA.Board and SoA.Board.HideMenu then SoA.Board.HideMenu() end
	local ok, g = pcall(self.Build, self, self.key)
	if not ok or type(g) ~= "table" then
		if SoA.debug then SoA:Print("flow: " .. tostring(g)) end
		g = newGraph("list")
		g.message = SoA.L["Not enough data for a flow"]
	end
	self.graph = g
	self:Place(g)
	self:Draw()
	self:UpdateHeader()
	local c = cfg()
	local sig = tostring(c.dir) .. ":" .. tostring(c.nodeSize) .. ":" .. tostring(c.showDone)
	if sig ~= self.sig then self.sig, self.viewKey = sig, nil end
	if (self.viewport:GetWidth() or 0) < 10 then
		self.viewKey = nil
		C_Timer.After(0, function() if EF.graph == g then EF.viewKey = EF.key EF:Fit() end end)
		return
	end
	if self.viewKey ~= self.key then
		self.viewKey = self.key
		self:Fit()
		local fn = self.focus and g.byKey["q:" .. self.focus]
		if not fn then
			for _, n in ipairs(g.nodes) do if n.status == "current" and n.row == 0 then fn = n break end end
		end
		if fn and self.view.z < 0.8 then self:CenterOn(fn, 1) end
		self.focus = nil
	else
		self:ApplyView()
	end
end

function EF:Draw()
	local g = self.graph
	local sz = g.sz or 1
	self.canvas:SetSize(math.max(1, g.w or 1), math.max(1, g.h or 1))
	self.nodeUsed, self.lineUsed = 0, 0
	for _, n in ipairs(g.nodes) do
		self.nodeUsed = self.nodeUsed + 1
		local b = self.nodes[self.nodeUsed]
		if not b then
			b = newNodeFrame(self.canvas)
			self.nodes[self.nodeUsed] = b
		end
		self:FillNode(b, n, sz)
	end
	for i = self.nodeUsed + 1, #self.nodes do self.nodes[i]:Hide() self.nodes[i].node = nil end
	for _, e in ipairs(g.edges) do self:DrawEdge(e, sz) end
	for i = self.lineUsed + 1, #self.lines do self.lines[i]:Hide() end
	local msg = self.frame.message
	msg:SetText(g.message or "")
	msg:SetShown(g.message ~= nil)
	self:DrawMini()
end

---------------------------------------------------------------------------
-- View: zoom (canvas scale) and pan (canvas offset in viewport pixels)
---------------------------------------------------------------------------
local function cursorIn(frame)
	local x, y = GetCursorPosition()
	local s = frame:GetEffectiveScale()
	local l, t = frame:GetLeft(), frame:GetTop()
	if not (x and y and l and t and s and s > 0) then return 0, 0 end
	return x / s - l, t - y / s
end

function EF:ApplyView(panOnly)
	local v, vp, g = self.view, self.viewport, self.graph
	if not (vp and g) then return end
	local vw, vh = vp:GetWidth() or 1, vp:GetHeight() or 1
	local gw, gh = (g.w or 1) * v.z, (g.h or 1) * v.z
	v.ox = clamp(v.ox, math.min(40 - gw, (vw - gw) / 2), math.max(vw - 40, (vw - gw) / 2))
	v.oy = clamp(v.oy, math.min(40 - gh, (vh - gh) / 2), math.max(vh - 40, (vh - gh) / 2))
	local c = self.canvas
	if not panOnly then
		c:SetScale(v.z)
		for i = 1, self.lineUsed do
			local l = self.lines[i]
			l:SetThickness(lineThickness(l.base or 2, v.z))
		end
		self.frame.zoomText:SetText(("%d%%"):format(v.z * 100 + 0.5))
	end
	c:ClearAllPoints()
	c:SetPoint("TOPLEFT", vp, "TOPLEFT", v.ox / v.z, -v.oy / v.z)
	self:MiniView()
end

function EF:ZoomAt(z2, cx, cy)
	local v = self.view
	z2 = clamp(z2, MIN_Z, MAX_Z)
	local gx, gy = (cx - v.ox) / v.z, (cy - v.oy) / v.z
	v.z = z2
	v.ox, v.oy = cx - gx * z2, cy - gy * z2
	self:ApplyView()
end

function EF:ZoomStep(factor)
	local vp = self.viewport
	self:ZoomAt(self.view.z * factor, (vp:GetWidth() or 0) / 2, (vp:GetHeight() or 0) / 2)
end

function EF:Fit()
	local g, vp, v = self.graph, self.viewport, self.view
	if not (g and vp) or #g.nodes == 0 then return end
	local vw, vh = vp:GetWidth() or 1, vp:GetHeight() or 1
	local gw, gh = math.max(1, g.w or 1), math.max(1, g.h or 1)
	v.z = clamp(math.min(vw / gw, vh / gh), MIN_Z, MAX_Z)
	v.ox, v.oy = (vw - gw * v.z) / 2, (vh - gh * v.z) / 2
	self:ApplyView()
end

function EF:CenterOn(n, z)
	local vp, v = self.viewport, self.view
	if z then v.z = clamp(z, MIN_Z, MAX_Z) end
	v.ox = (vp:GetWidth() or 0) / 2 - (n.x + n.w / 2) * v.z
	v.oy = (vp:GetHeight() or 0) / 2 - (n.y + n.h / 2) * v.z
	self:ApplyView()
end

---------------------------------------------------------------------------
-- Minimap (bottom left): whole graph and the visible rectangle
---------------------------------------------------------------------------
function EF:MiniScale()
	local g = self.graph
	local gw, gh = math.max(1, g and g.w or 1), math.max(1, g and g.h or 1)
	local s = math.min((MINI_W - 8) / gw, (MINI_H - 8) / gh)
	return s, (MINI_W - gw * s) / 2, (MINI_H - gh * s) / 2
end

function EF:DrawMini()
	local mini, g = self.frame.mini, self.graph
	mini:SetShown(#g.nodes > 0)
	local s, ox, oy = self:MiniScale()
	local used = 0
	for _, n in ipairs(g.nodes) do
		used = used + 1
		local t = mini.rects[used]
		if not t then
			t = mini:CreateTexture(nil, "ARTWORK")
			mini.rects[used] = t
		end
		local c = n.kind == "epic" and (n.color or SoA.Style.colors.proc) or statusColor(n.status)
		t:SetColorTexture(c[1], c[2], c[3], 0.9)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", mini, "TOPLEFT", ox + n.x * s, -(oy + n.y * s))
		t:SetSize(math.max(1, n.w * s), math.max(1, n.h * s))
		t:Show()
	end
	for i = used + 1, #mini.rects do mini.rects[i]:Hide() end
	self:MiniView()
end

function EF:MiniView()
	local f, g, v, vp = self.frame, self.graph, self.view, self.viewport
	if not (f and g and f.mini:IsShown()) then return end
	local s, ox, oy = self:MiniScale()
	local x0, y0 = -v.ox / v.z, -v.oy / v.z
	local x1, y1 = x0 + (vp:GetWidth() or 0) / v.z, y0 + (vp:GetHeight() or 0) / v.z
	local l = clamp(ox + x0 * s, 0, MINI_W - 2)
	local r = clamp(ox + x1 * s, l + 2, MINI_W)
	local t = clamp(oy + y0 * s, 0, MINI_H - 2)
	local b = clamp(oy + y1 * s, t + 2, MINI_H)
	local rect = f.mini.view
	rect:ClearAllPoints()
	rect:SetPoint("TOPLEFT", f.mini, "TOPLEFT", l, -t)
	rect:SetSize(r - l, b - t)
end

function EF:MiniJump()
	local s, ox, oy = self:MiniScale()
	local mx, my = cursorIn(self.frame.mini)
	local gx, gy = (mx - ox) / s, (my - oy) / s
	local v, vp = self.view, self.viewport
	v.ox = (vp:GetWidth() or 0) / 2 - gx * v.z
	v.oy = (vp:GetHeight() or 0) / 2 - gy * v.z
	self:ApplyView(true)
end

---------------------------------------------------------------------------
-- Interaction
---------------------------------------------------------------------------
local function menu(anchor, entries)
	if SoA.Board and SoA.Board.ShowMenu then SoA.Board.ShowMenu(anchor, entries) end
end

-- Opens another flow; `push` keeps the current one for "Back".
function EF:Go(key, push)
	if push and self.key then self.stack[#self.stack + 1] = self.key end
	self:Open(key, nil, true)
end

function EF:Back()
	local key = table.remove(self.stack)
	if key then self:Open(key, nil, true) end
end

function EF:OpenDetail(n)
	local D = SoA.Detail
	if not D then return end
	local target = n.item or n.questID
	local board = SoA.Board and SoA.Board.frame
	if board and board:IsShown() then
		D:Open(target)
	else
		D:Open(target, { window = true, anchor = self.frame })
	end
end

function EF:NodeClick(b, button)
	local n = b.node
	if not n then return end
	if button == "RightButton" then return self:NodeMenu(b, n) end
	if n.kind == "quest" then
		if IsShiftKeyDown() then
			SoA.Actions.AddStop(n.questID, n.title)
			return
		end
		self:OpenDetail(n)
	elseif n.kind == "epic" then
		self:Go(n.epicKey, true)
	elseif n.kind == "chapter" then
		if n.epicKey then self:Go(n.epicKey, true) end
	elseif n.kind == "done" then
		cfg().showDone = true
		self:Rebuild()
	end
end

function EF:NodeMenu(b, n)
	local L, S = SoA.L, SoA.Style
	local entries = { { text = n.title or "?", header = true } }
	if n.kind == "quest" then
		entries[#entries + 1] = { text = "   " .. L["Details"], color = S.colors.accent, fn = function() EF:OpenDetail(n) end }
		entries[#entries + 1] = { text = "   " .. L["Add GPS stop"], fn = function() SoA.Actions.AddStop(n.questID, n.title) end }
		if n.item and n.item.kind == "quest" then
			entries[#entries + 1] = { text = "   " .. L["Track"], fn = function() SoA.Actions.Select(n.questID, n.title) end }
			entries[#entries + 1] = { text = "   " .. L["Card menu..."], fn = function()
				if SoA.Board and SoA.Board.ItemMenu then SoA.Board.ItemMenu(b, n.item) end
			end }
		end
		for _, e in ipairs(self.graph.edges) do
			if e.learned and (e.a == n or e.b == n) then
				local other = e.a == n and e.b or e.a
				entries[#entries + 1] = { text = "   " .. L["Remove this link"] .. ": " .. (other.title or "?"), color = S.colors.warn,
					fn = function() EF:RemoveLink(e.learned[1], e.learned[2]) end }
			end
		end
	elseif n.kind == "epic" or n.kind == "chapter" then
		if n.epicKey then
			entries[#entries + 1] = { text = "   " .. L["Open flow"], color = S.colors.accent, fn = function() EF:Go(n.epicKey, true) end }
			if n.epicKey:sub(1, 3) ~= "in:" and SoA.Detail then
				entries[#entries + 1] = { text = "   " .. L["Epic details"], fn = function() SoA.Detail:OpenEpic(n.epicKey, { window = true, anchor = EF.frame }) end }
			end
		end
	else
		return
	end
	menu(b, entries)
end

function EF:NodeTip(b)
	local n = b.node
	if not n then return end
	local L, S = SoA.L, SoA.Style
	b:SetBackdropBorderColor(unpack(S.colors.accent))
	local tt = GameTooltip
	tt:SetOwner(b, "ANCHOR_RIGHT")
	if n.kind == "epic" or n.kind == "chapter" then
		local e = n.epicKey and n.epicKey:sub(1, 3) ~= "in:" and SoA.Epics:ByKey(n.epicKey)
		if not (e and SoA.Epics:Tooltip(tt, e)) then
			tt:SetText(n.title or "?", 1, 1, 1)
			if n.sub then tt:AddLine(n.sub, 0.6, 0.65, 0.71) end
			if n.kind == "chapter" and not n.epicKey then tt:AddLine(L["No questline data"], 0.6, 0.65, 0.71) end
		end
		if n.epicKey then tt:AddLine(n.kind == "chapter" and L["Click: zoom into this epic"] or L["Click: open this flow"], 0.41, 0.8, 0.94) end
		tt:Show()
		return
	end
	if n.kind == "done" then
		tt:SetText(n.title or "", 0.3, 0.9, 0.3)
		tt:AddLine(L["Completed quests are hidden. Click to show them."], 1, 1, 1, true)
		tt:Show()
		return
	end
	local it = n.item
	tt:SetText(n.title or "?", 1, 1, 1, 1, true)
	if n.epicName then tt:AddLine(n.epicName, 0.6, 0.65, 0.71) end
	local sc = statusColor(n.status)
	local stText = L[STATUS_LABEL[n.status] or "Upcoming"]
	if it and it.kind == "quest" and it.ready then stText = L["Ready to turn in"] end
	if n.available then stText = L["Available"] end
	tt:AddDoubleLine(L["Status"], stText, 0.6, 0.65, 0.71, sc[1], sc[2], sc[3])
	if n.level then tt:AddDoubleLine(L["Level"], tostring(n.level), 0.6, 0.65, 0.71, 1, 1, 1) end
	if n.dungeon then tt:AddDoubleLine(L["Type"], n.dungeon, 0.6, 0.65, 0.71, DUNGEON_COLOR[1], DUNGEON_COLOR[2], DUNGEON_COLOR[3]) end
	if it and it.est and SoA.Estimate then
		tt:AddDoubleLine(L["Estimate"], SoA.Estimate:Format(it.est), 0.6, 0.65, 0.71, 1, 1, 1)
	end
	if n.actual then tt:AddDoubleLine(L["Actual"], S:Minutes(n.actual), 0.6, 0.65, 0.71, 0.3, 0.9, 0.3) end
	local xp = (it and num(it.xp)) or SoA.Log:RewardXP(n.questID)
	if xp and xp > 0 then tt:AddDoubleLine(L["XP"], S:Digits(xp), 0.6, 0.65, 0.71, 1, 0.82, 0) end
	if it and it.priority and SoA.Priority then
		local pc = SoA.Priority:Color(it.priority)
		tt:AddDoubleLine(L["Priority"], SoA.Priority:Name(it.priority), 0.6, 0.65, 0.71, pc[1], pc[2], pc[3])
	end
	if n.progress and n.status ~= "done" then
		tt:AddDoubleLine(L["Progress"], ("%d%%"):format(n.progress * 100 + 0.5), 0.6, 0.65, 0.71, 1, 1, 1)
	end
	local reasons = (it and it.kind == "quest" and it.blockReasons) or {}
	for _, r in ipairs(reasons) do tt:AddLine(L["Blocked"] .. ": " .. r, 0.95, 0.3, 0.3, true) end
	if #reasons == 0 and n.reason then tt:AddLine(L["Blocked"] .. ": " .. n.reason, 0.95, 0.3, 0.3, true) end
	if n.lock then tt:AddLine(n.lock, 0.6, 0.65, 0.71, true) end
	if it and it.onHold then tt:AddLine(L["On hold"] .. ": " .. (it.holdText or ""), 1, 0.82, 0, true) end
	if it and it.shared and it.shared.note then tt:AddLine(it.shared.note, 0.41, 0.8, 0.94, true) end
	if n.learnedCount then tt:AddLine(L["Learned link (%d times seen)"]:format(n.learnedCount), 0.41, 0.8, 0.94) end
	tt:AddLine(L["Click: details. Shift-click: GPS stop. Right-click: menu."], 0.6, 0.65, 0.71, true)
	tt:Show()
end

-- Right-click on empty space: the nearest learned (dashed) link -> "Remove this link".
local function segDist(px, py, x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local l2 = dx * dx + dy * dy
	local t = l2 > 0 and clamp(((px - x1) * dx + (py - y1) * dy) / l2, 0, 1) or 0
	local qx, qy = x1 + t * dx - px, y1 + t * dy - py
	return math.sqrt(qx * qx + qy * qy)
end

function EF:EdgeMenu()
	local g, v, vp = self.graph, self.view, self.viewport
	if not g then return end
	local cx, cy = cursorIn(vp)
	local gx, gy = (cx - v.ox) / v.z, (cy - v.oy) / v.z
	local best, bd = nil, 8 / v.z
	for _, e in ipairs(g.edges) do
		if e.learned and e.pts then
			local p = e.pts
			for i = 1, #p - 2, 2 do
				local d = segDist(gx, gy, p[i], p[i + 1], p[i + 2], p[i + 3])
				if d < bd then best, bd = e, d end
			end
		end
	end
	if not best then return end
	local L, S = SoA.L, SoA.Style
	local a = self.frame.cursorAnchor
	a:ClearAllPoints()
	a:SetPoint("TOPLEFT", vp, "TOPLEFT", cx, -cy)
	menu(a, {
		{ text = L["Learned link"], header = true },
		{ text = "   " .. (best.a.title or "?") .. " > " .. (best.b.title or "?") },
		{ text = "   " .. L["Remove this link"], color = S.colors.warn, fn = function() EF:RemoveLink(best.learned[1], best.learned[2]) end },
	})
end

---------------------------------------------------------------------------
-- Header: picker, options
---------------------------------------------------------------------------
function EF:PickerMenu(anchor)
	local L, E = SoA.L, SoA.Epics
	local m = SoA.Model:Get()
	local epics, inits, seen = {}, {}, {}
	for k, me in pairs(m.epics) do
		if type(k) == "string" and (k:sub(1, 3) == "ql:" or k:sub(1, 3) == "cp:") then
			local e = E:ByKey(k)
			if k:sub(1, 3) == "ql:" then epics[#epics + 1] = { key = k, name = (e and e.name) or me.name or k, color = (e and e.color) or me.color } end
			local cid = e and campaignFor(e)
			if cid and not seen[cid] then
				seen[cid] = true
				inits[#inits + 1] = { key = "in:" .. cid, name = campaignName(cid, e) }
			end
		end
	end
	local function byName(a, b) return (a.name or "") < (b.name or "") end
	table.sort(epics, byName)
	table.sort(inits, byName)
	local entries = { { text = L["Epics"], header = true } }
	for i, e in ipairs(epics) do
		if i > 24 then break end
		entries[#entries + 1] = { text = (e.key == self.key and "> " or "   ") .. e.name, color = e.color, fn = function() EF:Open(e.key) end }
	end
	if #epics == 0 then entries[#entries + 1] = { text = "   " .. L["No epics in your log"], color = SoA.Style.colors.muted } end
	if #inits > 0 then
		entries[#entries + 1] = { text = L["Initiatives"], header = true }
		for i, e in ipairs(inits) do
			if i > 8 then break end
			entries[#entries + 1] = { text = (e.key == self.key and "> " or "   ") .. e.name, color = SoA.Style.colors.proc, fn = function() EF:Open(e.key) end }
		end
	end
	menu(anchor, entries)
end

local function setOpt(k, v)
	cfg()[k] = v
	EF.viewKey = nil
	SoA:Fire("SETTINGS") -- Config refreshes; the flow rebuilds (throttled)
	EF:Rebuild()
end

function EF:OptionsMenu(anchor)
	local L, S = SoA.L, SoA.Style
	local c = cfg()
	local function mark(on) return on and "> " or "   " end
	local entries = {
		{ text = L["Flow view"], header = true },
		{ text = mark(c.showLearned) .. L["Show learned links"], fn = function() setOpt("showLearned", not c.showLearned) end },
		{ text = mark(c.showDone) .. L["Show completed quests"], fn = function() setOpt("showDone", not c.showDone) end },
		{ text = L["Direction"], header = true },
		{ text = mark(c.dir ~= "tb") .. L["Left to right"], fn = function() setOpt("dir", "lr") end },
		{ text = mark(c.dir == "tb") .. L["Top to bottom"], fn = function() setOpt("dir", "tb") end },
		{ text = L["Node size"], header = true },
	}
	for _, s in ipairs({ { 0.8, "Small" }, { 1, "Medium" }, { 1.25, "Large" } }) do
		entries[#entries + 1] = { text = mark(num(c.nodeSize, 1) == s[1]) .. L[s[2]], fn = function() setOpt("nodeSize", s[1]) end }
	end
	entries[#entries + 1] = { text = L["Learned links"], header = true }
	entries[#entries + 1] = { text = "   " .. L["Forget learned links"], color = S.colors.warn, fn = function() EF:ResetLearned() end }
	menu(anchor, entries)
end

function EF:UpdateHeader()
	local f = self.frame
	local name = (self.graph and self.graph.title) or self:KeyName(self.key)
	f.picker.text:SetText(name .. "  v")
	f.back:SetShown(#self.stack > 0)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local function savePoint(f)
	local p, _, rp, x, y = f:GetPoint()
	if p then cfg().point = { p, rp, math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) } end
end

function EF:Create()
	local L, S = SoA.L, SoA.Style
	local c = cfg()
	local f = CreateFrame("Frame", "ScrumOfAzerothEpicFlow", UIParent, "BackdropTemplate")
	local maxW, maxH = UIParent:GetWidth() or 1600, UIParent:GetHeight() or 900
	f:SetSize(clamp(num(c.width, 900), MIN_W, maxW), clamp(num(c.height, 520), MIN_H, maxH))
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetResizable(true)
	f:SetClampedToScreen(true)
	if f.SetResizeBounds then f:SetResizeBounds(MIN_W, MIN_H, maxW, maxH)
	elseif f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) f:SetMaxResize(maxW, maxH) end
	S:Backdrop(f, 0.97)
	f:Hide()
	tinsert(UISpecialFrames, "ScrumOfAzerothEpicFlow")
	local pt = c.point
	if type(pt) == "table" and pt[1] then
		f:SetPoint(pt[1], UIParent, pt[2], num(pt[3], 0), num(pt[4], 0))
	else
		f:SetPoint("CENTER", 0, 20)
	end
	self.frame = f
	self.view = { z = 1, ox = 0, oy = 0 }
	self.nodes, self.lines, self.nodeUsed, self.lineUsed = {}, {}, 0, 0

	-- header
	local head = CreateFrame("Frame", nil, f)
	head:SetPoint("TOPLEFT", 1, -1)
	head:SetPoint("TOPRIGHT", -1, -1)
	head:SetHeight(HEAD_H)
	head:EnableMouse(true)
	head:RegisterForDrag("LeftButton")
	head:SetScript("OnDragStart", function() f:StartMoving() end)
	head:SetScript("OnDragStop", function() f:StopMovingOrSizing() savePoint(f) end)
	local hb = head:CreateTexture(nil, "BACKGROUND")
	hb:SetAllPoints()
	hb:SetColorTexture(0.08, 0.10, 0.14, 1)
	local title = S:Font(head, 14)
	title:SetPoint("LEFT", 10, 0)
	title:SetText(L["Flow"])
	title:SetTextColor(unpack(S.colors.accent))
	f.back = S:Button(head, L["Back"], 54, 20, function() EF:Back() end)
	f.back:SetPoint("LEFT", title, "RIGHT", 12, 0)
	f.back:Hide()
	f.picker = S:Button(head, "", 230, 20, function(btn) EF:PickerMenu(btn) end)
	f.picker:SetPoint("LEFT", title, "RIGHT", 72, 0)
	f.picker.text:SetWidth(220)
	f.picker.text:SetWordWrap(false)
	f.picker.tip = L["Pick an epic (questline) or initiative (campaign)."]

	local close = S:Button(head, "X", 24, 20, function() f:Hide() end)
	close:SetPoint("RIGHT", -6, 0)
	local opts = S:Button(head, L["Options"], 64, 20, function(btn) EF:OptionsMenu(btn) end)
	opts:SetPoint("RIGHT", close, "LEFT", -6, 0)
	local fit = S:Button(head, L["Fit"], 40, 20, function() EF:Fit() end)
	fit:SetPoint("RIGHT", opts, "LEFT", -6, 0)
	fit.tip = L["Scale and centre the whole flow."]
	local plus = S:Button(head, "+", 22, 20, function() EF:ZoomStep(1.2) end)
	plus:SetPoint("RIGHT", fit, "LEFT", -6, 0)
	local pct = S:Button(head, "100%", 48, 20, function()
		local vp = EF.viewport
		EF:ZoomAt(1, (vp:GetWidth() or 0) / 2, (vp:GetHeight() or 0) / 2)
	end)
	pct:SetPoint("RIGHT", plus, "LEFT", -2, 0)
	pct.tip = L["Back to 100%"]
	f.zoomText = pct.text
	local minus = S:Button(head, "-", 22, 20, function() EF:ZoomStep(1 / 1.2) end)
	minus:SetPoint("RIGHT", pct, "LEFT", -2, 0)

	-- viewport (clips the canvas)
	local vp = CreateFrame("Frame", nil, f)
	vp:SetPoint("TOPLEFT", 6, -(HEAD_H + 4))
	vp:SetPoint("BOTTOMRIGHT", -6, 6)
	if vp.SetClipsChildren then vp:SetClipsChildren(true) end
	vp:EnableMouse(true)
	vp:EnableMouseWheel(true)
	local vbg = vp:CreateTexture(nil, "BACKGROUND")
	vbg:SetAllPoints()
	vbg:SetColorTexture(0.02, 0.03, 0.05, 0.6)
	self.viewport = vp
	self.canvas = CreateFrame("Frame", nil, vp)
	self.canvas:SetSize(10, 10)
	self.canvas:SetPoint("TOPLEFT")
	vp:SetScript("OnMouseWheel", function(_, delta)
		local cx, cy = cursorIn(vp)
		EF:ZoomAt(EF.view.z * (delta > 0 and 1.15 or 1 / 1.15), cx, cy)
	end)
	vp:SetScript("OnMouseDown", function(_, button)
		if button ~= "LeftButton" then return end
		if SoA.Board and SoA.Board.HideMenu then SoA.Board.HideMenu() end
		local cx, cy = cursorIn(vp)
		EF.drag = { cx = cx, cy = cy, ox = EF.view.ox, oy = EF.view.oy }
		vp:SetScript("OnUpdate", function()
			local d = EF.drag
			if not d then vp:SetScript("OnUpdate", nil) return end
			local x, y = cursorIn(vp)
			EF.view.ox, EF.view.oy = d.ox + x - d.cx, d.oy + y - d.cy
			EF:ApplyView(true)
		end)
	end)
	vp:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			EF.drag = nil
			vp:SetScript("OnUpdate", nil)
		elseif button == "RightButton" then
			SoA.guard("flow edge menu", EF.EdgeMenu, EF)
		end
	end)

	-- overlay: message, combat note, minimap, anchor for menus at the cursor
	local over = CreateFrame("Frame", nil, vp)
	over:SetAllPoints()
	over:SetFrameLevel(vp:GetFrameLevel() + 30)
	f.message = S:Font(over, 13)
	f.message:SetPoint("TOP", 0, -12)
	f.message:SetTextColor(unpack(S.gold))
	f.combat = S:Font(over, 11)
	f.combat:SetPoint("TOPRIGHT", -8, -8)
	f.combat:SetText(L["In combat: the flow updates afterwards."])
	f.combat:SetTextColor(unpack(S.colors.warn))
	f.combat:Hide()
	f.cursorAnchor = CreateFrame("Frame", nil, over)
	f.cursorAnchor:SetSize(1, 1)

	local mini = CreateFrame("Frame", nil, over, "BackdropTemplate")
	mini:SetSize(MINI_W, MINI_H)
	mini:SetPoint("BOTTOMLEFT", 6, 6)
	S:Backdrop(mini, 0.85)
	mini:EnableMouse(true)
	mini.rects = {}
	mini.view = CreateFrame("Frame", nil, mini, "BackdropTemplate")
	mini.view:SetBackdrop({ bgFile = S.flat, edgeFile = S.flat, edgeSize = 1 })
	mini.view:SetBackdropColor(1, 1, 1, 0.08)
	mini.view:SetBackdropBorderColor(S.colors.accent[1], S.colors.accent[2], S.colors.accent[3], 0.9)
	mini.view:SetFrameLevel(mini:GetFrameLevel() + 2)
	mini.view:EnableMouse(false)
	mini:SetScript("OnMouseDown", function(m, button)
		if button ~= "LeftButton" then return end
		EF:MiniJump()
		m:SetScript("OnUpdate", function() EF:MiniJump() end)
	end)
	mini:SetScript("OnMouseUp", function(m) m:SetScript("OnUpdate", nil) end)
	f.mini = mini

	-- resize grip
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(12, 12)
	grip:SetPoint("BOTTOMRIGHT", -1, 1)
	grip:SetFrameLevel(over:GetFrameLevel() + 5)
	for i = 0, 2 do
		local t = grip:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(S.colors.muted[1], S.colors.muted[2], S.colors.muted[3], 0.8)
		t:SetSize(2 + i * 4, 1)
		t:SetPoint("BOTTOMRIGHT", -1, 2 + i * 3)
	end
	grip:SetScript("OnMouseDown", function()
		f.sizing = true
		f:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function()
		if not f.sizing then return end
		f.sizing = false
		f:StopMovingOrSizing()
		cfg().width = math.floor(f:GetWidth() + 0.5)
		cfg().height = math.floor(f:GetHeight() + 0.5)
		savePoint(f)
		EF:ApplyView()
	end)
	f:SetScript("OnSizeChanged", function()
		if EF.graph then SoA:Throttle("epicflow-size", 0.05, function() EF:ApplyView(true) end) end
	end)
	f:SetScript("OnShow", function() EF:Rebuild() end)
	f:SetScript("OnHide", function()
		EF.drag = nil
		vp:SetScript("OnUpdate", nil)
		mini:SetScript("OnUpdate", nil)
		if f.sizing then f.sizing = false f:StopMovingOrSizing() end
		if SoA.Board and SoA.Board.HideMenu then SoA.Board.HideMenu() end
	end)
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------
-- Flow key of an epic key: "ql:" stays, a campaign epic ("cp:") becomes its initiative.
function EF:NormKey(key)
	if type(key) ~= "string" then return end
	local cp = key:match("^cp:(%d+)$")
	if cp then return "in:" .. cp end
	if key:match("^ql:%d+$") or key:match("^in:%d+$") or key:match("^st:%d+$") then return key end
end

-- The epic of the followed quest, else of the most important quest in the log.
function EF:DefaultKey()
	local sel = SoA.Actions.Selected and SoA.Actions.Selected()
	local e = sel and SoA.Epics:Get(sel)
	if e then return self:NormKey(e.key) end
	local list = {}
	for _, it in ipairs(SoA.Model:Get().items) do
		if it.kind == "quest" and self:NormKey(it.epicKey) then list[#list + 1] = it end
	end
	SoA.Model:Sort(list, "priority")
	return list[1] and self:NormKey(list[1].epicKey)
end

-- key: epic key ("ql:", "cp:", "in:"), nil = last / default. focusQuestID: centre on it.
function EF:Open(key, focusQuestID, keepStack)
	if not SoA.char then return end
	if not self.frame then
		if InCombatLockdown() then
			SoA:Print(SoA.L["The flow view opens after combat."])
			SoA:OutOfCombat("epicflow-open", function() EF:Open(key, focusQuestID, keepStack) end)
			return
		end
		self:Create()
	end
	key = self:NormKey(key) or self.key or self:NormKey(cfg().last) or self:DefaultKey()
	if not keepStack then wipe(self.stack) end
	self.key, self.focus = key, num(focusQuestID)
	cfg().last = key
	self.viewKey = nil
	if self.frame:IsShown() then self:Rebuild() else self.frame:Show() end -- OnShow rebuilds
end

-- "Show flow" for a model item (card menu, detail panel).
function EF:OpenFor(it)
	if type(it) ~= "table" then return end
	if it.kind == "combo" and it.members then it = it.members[1] end
	local key = self:NormKey(it.epicKey)
	local id = num(it.id)
	if not key and id then
		local e = SoA.Epics:Get(id)
		key = e and self:NormKey(e.key)
	end
	self:Open(key, id)
end

function EF:CanShow(it)
	if type(it) ~= "table" then return false end
	if it.kind == "combo" and it.members then it = it.members[1] end
	return self:NormKey(it.epicKey) ~= nil
end

function EF:Toggle()
	if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

function SoA:ToggleFlow() EF:Toggle() end

function EF:Schedule()
	if not (self.frame and self.frame:IsShown()) then return end
	if InCombatLockdown() then
		self.pending = true
		self.frame.combat:Show()
		return
	end
	SoA:Throttle("epicflow-rebuild", REBUILD_WAIT, function() EF:Rebuild() end)
end

function EF:OnInit()
	cfg()
	adb()
end

function EF:OnEnable()
	SoA:On("QUEST_TURNED_IN", onTurnIn)
	SoA:On("QUEST_ACCEPTED", onAccept)
	SoA:On("QUEST_LINES_UPDATE", function()
		local turn = lastTurn
		if turn and turn.diff then C_Timer.After(0.5, function() SoA.guard("flow learn", turn.diff) end) end
	end)
	for _, msg in ipairs({ "EPICS", "SETTINGS", "PRIORITY" }) do
		SoA:Listen(msg, function() EF:Schedule() end)
	end
	SoA:On("PLAYER_REGEN_DISABLED", function()
		if EF.frame and EF.frame:IsShown() and SoA.Board and SoA.Board.HideMenu then SoA.Board.HideMenu() end
	end)
	SoA:On("PLAYER_REGEN_ENABLED", function()
		if EF.pending and EF.frame and EF.frame:IsShown() then
			C_Timer.After(0.2, function() SoA.guard("flow rebuild", EF.Rebuild, EF) end)
		end
	end)
end
