-- Scrum of Azeroth by DinX: priorities (Jira style, automatic or set by hand)
-- and blockers (automatic conditions or a reason picked by hand).
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local P = SoA:NewModule("Priority")

-- 1 = Highest .. 5 = Lowest
P.LEVELS = {
	{ key = "Highest", color = { 0.85, 0.20, 0.20 } },
	{ key = "High", color = { 1.00, 0.42, 0.30 } },
	{ key = "Medium", color = { 1.00, 0.62, 0.15 } },
	{ key = "Low", color = { 0.30, 0.60, 1.00 } },
	{ key = "Lowest", color = { 0.45, 0.75, 1.00 } },
}

local WEIGHTS = {
	balanced = { x = 1.0, c = 1.0, u = 1.0 },
	xp = { x = 1.25, c = 0.25, u = 0.5 },
	story = { x = 0.6, c = 2.0, u = 0.75 },
}

local function cfg() return SoA.char and SoA.char.priority or { manual = {} } end

function P:Manual(key)
	local m = cfg().manual
	return type(m) == "table" and num(m[key]) or nil
end

function P:SetManual(key, level)
	local c = cfg()
	if type(c.manual) ~= "table" then c.manual = {} end
	c.manual[key] = num(level)
	SoA:Fire("MODEL_DIRTY")
	SoA:Fire("PRIORITY")
end

function P:Name(level) return SoA.L[(self.LEVELS[level] or self.LEVELS[3]).key] end
function P:Color(level) return (self.LEVELS[level] or self.LEVELS[3]).color end

-- Tiny coloured bar for the CasterKit tracker title (texture escape, no font glyphs).
function P:Marker(level)
	local c = self:Color(level)
	return ("|T%s:9:3:0:0:8:8:0:8:0:8:%d:%d:%d|t "):format("Interface\\Buttons\\WHITE8x8",
		math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

-- Automatic priority of a model item; ctx = { median, solo, weighting }.
-- Returns level and a breakdown ("XP/min 142 · chain +1 · level ok").
function P:Auto(it, ctx)
	local L = SoA.L
	local parts = {}
	if it.kind == "ticket" then return 3, L["custom ticket"] end
	local w = WEIGHTS[ctx.weighting] or WEIGHTS.balanced
	local xs = 2
	if it.xpm and ctx.median and ctx.median > 0 then
		local r = math.max(0.01, it.xpm / ctx.median)
		xs = math.max(0, math.min(4, math.log(r) / math.log(2) + 2))
		parts[#parts + 1] = L["XP/min %d"]:format(it.xpm + 0.5)
	elseif it.xp then
		parts[#parts + 1] = L["XP %d"]:format(it.xp)
	end
	local score = xs * w.x
	if it.unlocks then
		score = score + w.c
		parts[#parts + 1] = L["chain +1"]
	end
	if it.campaign then score = score + w.c * 0.5 end
	local diff = it.difficulty
	if diff == "orange" and ctx.solo then
		score = score - 0.75
		parts[#parts + 1] = L["orange -1"]
	elseif diff == "red" and ctx.solo then
		score = score - 1.5
		parts[#parts + 1] = L["red -2"]
	elseif diff ~= "grey" then
		parts[#parts + 1] = L["level ok"]
	end
	if ctx.solo and (it.elite or (it.group or 0) > 1) then
		score = score - 1
		parts[#parts + 1] = L["group quest solo -1"]
	end
	if it.upgrade then
		score = score + w.u
		parts[#parts + 1] = L["upgrade +1"]
	end
	if it.blocked then
		score = score - 1.5
		parts[#parts + 1] = L["blocked -2"]
	end
	local level
	if score >= 3.5 then level = 1 elseif score >= 2.5 then level = 2 elseif score >= 1.5 then level = 3
	elseif score >= 0.75 then level = 4 else level = 5 end
	if diff == "grey" and not it.ready then
		level = 5
		parts[#parts + 1] = L["grey: Lowest"]
	elseif it.ready and not it.blocked then
		level = math.min(level, 2)
		parts[#parts + 1] = L["ready: quick XP"]
	end
	return level, table.concat(parts, " · ")
end

-- Sort: priority, then XP per minute, then title.
function P.Compare(a, b)
	if a.priority ~= b.priority then return a.priority < b.priority end
	local ax, bx = a.xpm or -1, b.xpm or -1
	if ax ~= bx then return ax > bx end
	if (a.rank or 999) ~= (b.rank or 999) then return (a.rank or 999) < (b.rank or 999) end
	return (a.title or "") < (b.title or "")
end

---------------------------------------------------------------------------
-- Blockers
---------------------------------------------------------------------------
local B = SoA:NewModule("Blockers")
B.REASONS = { "Needs a group", "Level too high", "Waiting for an item", "Needs a profession", "Other" }

local function bcfg()
	local c = SoA.char
	if not c then return { manual = {}, margin = 4 } end
	if type(c.blockers) ~= "table" then c.blockers = {} end
	if type(c.blockers.manual) ~= "table" then c.blockers.manual = {} end
	c.blockers.margin = num(c.blockers.margin, 4)
	return c.blockers
end
B.Config = bcfg

function B:Manual(key)
	local m = bcfg().manual[key]
	return type(m) == "table" and m or nil
end

function B:SetManual(key, reason, text)
	if reason then
		bcfg().manual[key] = { reason = reason, text = str(text) }
	else
		bcfg().manual[key] = nil
	end
	SoA:Fire("MODEL_DIRTY")
end

-- Reasons why an item is blocked right now (they clear by themselves when
-- the condition changes: level up, joined a group, prerequisite done).
function B:Reasons(it, ctx)
	local L = SoA.L
	local out = {}
	if it.kind == "quest" or it.kind == "upcoming" then
		local margin = bcfg().margin
		if it.level and ctx.level and it.level >= ctx.level + margin then
			out[#out + 1] = L["Level %d needed (you are %d)"]:format(it.level - margin + 1, ctx.level)
		end
		if ctx.solo and (it.elite or (it.group or 0) > 1) then out[#out + 1] = L["Group quest while solo"] end
		if it.failed then out[#out + 1] = L["Failed"] end
		if it.kind == "upcoming" and it.after then out[#out + 1] = L["After: %s"]:format(it.after) end
	end
	local m = self:Manual(it.key)
	if m then
		local r = L[m.reason or "Other"]
		out[#out + 1] = m.text and (r .. ": " .. m.text) or r
	end
	return out
end

function B:OnEnable()
	bcfg()
	-- conditions that can unblock: refresh the model
	for _, ev in ipairs({ "PLAYER_LEVEL_UP", "GROUP_ROSTER_UPDATE" }) do
		SoA:On(ev, function() SoA:Fire("MODEL_DIRTY") end)
	end
end

---------------------------------------------------------------------------
-- On hold (manual only). Resume conditions never move anything by
-- themselves: the card only says "Ready to resume".
---------------------------------------------------------------------------
local Hd = SoA:NewModule("Hold")
Hd.REASONS = { "Later with a group", "Too hard for now", "Waiting for item/profession", "Other" }

local function hdb()
	local c = SoA.char
	if not c then return {} end
	if type(c.hold) ~= "table" then c.hold = {} end
	return c.hold
end

function Hd:Get(key)
	local h = hdb()[key]
	return type(h) == "table" and h or nil
end

function Hd:Put(key, reason, text, prevStatus, title)
	hdb()[key] = { reason = reason, text = str(text), at = time(), prev = prevStatus }
	local SP = SoA.Sprint
	if SP and SP:IsActive() and (SP:Contains(key) or SP.Data().est[key]) then
		SP.Data().held = SP.Data().held or {}
		SP.Data().held[key] = title or true
	end
	SoA:Fire("MODEL_DIRTY")
	if SoA.Hooks and SoA.Hooks.Changed then pcall(SoA.Hooks.Changed) end
end

function Hd:SetCondition(key, cond)
	local h = self:Get(key)
	if h then h.cond = cond SoA:Fire("MODEL_DIRTY") end
end

-- Resume: tickets get their previous status back; quests follow their objectives.
function Hd:Resume(key)
	local h = self:Get(key)
	hdb()[key] = nil
	if h and h.prev and SoA.Tickets and SoA.Tickets:Get(key) then
		SoA.Tickets:Get(key).status = h.prev
	end
	SoA:Fire("MODEL_DIRTY")
	if SoA.Hooks and SoA.Hooks.Changed then pcall(SoA.Hooks.Changed) end
end

function Hd:CondMet(h, ctx)
	local c = h and h.cond
	if type(c) ~= "table" then return false end
	if c.level and ctx.level and ctx.level >= c.level then return true end
	if c.group and not ctx.solo then return true end
	if c.map and c.map == SoA:PlayerMap() then return true end
	return false
end

function Hd:Text(h)
	local L = SoA.L
	if not h then return "" end
	local r = L[h.reason or "Other"]
	if h.text then r = r .. ": " .. h.text end
	local c = h.cond
	if type(c) == "table" then
		if c.level then r = r .. " · " .. L["resume at level %d"]:format(c.level)
		elseif c.group then r = r .. " · " .. L["resume in a group"]
		elseif c.map then r = r .. " · " .. L["resume back in this zone"] end
	end
	return r
end
