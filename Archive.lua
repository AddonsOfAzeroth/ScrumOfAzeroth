-- Scrum of Azeroth by DinX: the archive. Every quest you turn in and every
-- ticket you finish is kept here, also long after it left the Done column:
-- when, how long it took against the estimate, XP, fights and deaths.
-- Open it from the board's "..." menu or with /soa archive. Search by name.
local _, ns = ...
local SoA = ns.SoA
local num, str = SoA.num, SoA.str

local A = SoA:NewModule("Archive")
A.MAX = 2000
local ROW_H = 18

-- ScrumOfAzerothCharDB.archive = { list = { { key, title, kind, t, xp, est, act, fights, deaths, epic } }, backfilled }
local function adb()
	local c = SoA.char
	if not c then return { list = {} } end
	if type(c.archive) ~= "table" then c.archive = {} end
	if type(c.archive.list) ~= "table" then c.archive.list = {} end
	return c.archive
end

function A:List() return adb().list end

local function has(key, t)
	for _, r in ipairs(adb().list) do
		if r.key == key and math.abs(num(r.t, 0) - t) < 120 then return true end
	end
end

-- keep one record; stats come from the activity tracker (Activity.lua)
function A:Add(rec)
	if rec.key == nil or has(rec.key, rec.t) then return end
	local Act = SoA.Activity
	if Act and Act.Stats then
		local ok, s = pcall(Act.Stats, Act, rec.key)
		if ok and type(s) == "table" then
			rec.act = (s.active or 0) > 0 and math.floor(s.active) or nil
			rec.fights = (s.fights or 0) > 0 and s.fights or nil
			rec.deaths = (s.deaths or 0) > 0 and s.deaths or nil
			rec.est = rec.est or s.firstEstimate
			if not rec.xp and (s.xp or 0) > 0 then rec.xp = math.floor(s.xp) end
		end
	end
	local list = adb().list
	list[#list + 1] = rec
	table.sort(list, function(a, b) return num(a.t, 0) < num(b.t, 0) end)
	while #list > self.MAX do table.remove(list, 1) end
	self:Refresh()
end

-- finished tickets that are not in the archive yet
function A:SyncTickets()
	local T = SoA.Tickets
	if not (T and T.All) then return end
	for _, t in ipairs(T:All()) do
		if t.status == "done" and num(t.doneAt) then
			self:Add({ key = t.key, title = t.title, kind = "ticket", t = t.doneAt,
				est = num(t.minutes), epic = t.label or t.dungeonName })
		end
	end
end

-- first run: the turned-in quests the activity tracker still remembers
function A:Backfill()
	local a = adb()
	if a.backfilled then return end
	a.backfilled = true
	local Act = SoA.Activity
	local events = SoA.char.activity and SoA.char.activity.events
	if not (Act and type(events) == "table") then return end
	for key, list in pairs(events) do
		if type(list) == "table" then
			for _, e in ipairs(list) do
				if e.kind == "turnedin" and num(e.t) then
					self:Add({ key = key, title = Act:Title(key), kind = "quest", t = e.t })
				end
			end
		end
	end
	self:SyncTickets()
end

---------------------------------------------------------------------------
-- Totals of a list of records
---------------------------------------------------------------------------
function A:Totals(list)
	local s = { n = #list, xp = 0, act = 0, est = 0, both = 0, actBoth = 0, deaths = 0 }
	for _, r in ipairs(list) do
		s.xp = s.xp + num(r.xp, 0)
		s.act = s.act + num(r.act, 0)
		s.deaths = s.deaths + num(r.deaths, 0)
		if num(r.est) and num(r.act) and r.act > 0 then
			s.both = s.both + 1
			s.est = s.est + r.est
			s.actBoth = s.actBoth + r.act / 60
		end
	end
	-- > 1: you take longer than estimated
	s.ratio = s.est > 0 and s.both >= 3 and s.actBoth / s.est or nil
	return s
end

function A:Filter(text)
	text = str(text) and text:lower() or ""
	local out = {}
	local list = adb().list
	for i = #list, 1, -1 do
		local r = list[i]
		if text == "" or tostring(r.title or ""):lower():find(text, 1, true) or tostring(r.epic or ""):lower():find(text, 1, true) then
			out[#out + 1] = r
		end
	end
	return out
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local win
local function build()
	local L, S = SoA.L, SoA.Style
	local f = CreateFrame("Frame", "ScrumOfAzerothArchive", UIParent, "BackdropTemplate")
	f:SetSize(560, 480)
	f:SetPoint("CENTER", 0, 40)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	S:Backdrop(f, 0.97)
	f:Hide()
	tinsert(UISpecialFrames, "ScrumOfAzerothArchive")
	local title = S:Font(f, 14)
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(L["Archive"])
	title:SetTextColor(unpack(S.colors.accent))
	local close = S:Button(f, "X", 22, 20, function() f:Hide() end)
	close:SetPoint("TOPRIGHT", -8, -8)

	local search = CreateFrame("EditBox", nil, f, "BackdropTemplate")
	search:SetSize(200, 20)
	search:SetPoint("TOPRIGHT", close, "TOPLEFT", -8, 0)
	S:Backdrop(search, 1)
	search:SetAutoFocus(false)
	search:SetTextInsets(6, 6, 0, 0)
	S:ApplyFont(search, 11)
	search:SetScript("OnTextChanged", function() A:Refresh() end)
	search:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)
	search.hint = S:Font(search, 11)
	search.hint:SetPoint("LEFT", 6, 0)
	search.hint:SetText(L["Search"])
	search.hint:SetTextColor(unpack(S.colors.muted))
	f.search = search

	f.sum = S:Font(f, 11)
	f.sum:SetPoint("TOPLEFT", 12, -38)
	f.sum:SetWidth(536)
	f.sum:SetJustifyH("LEFT")

	-- column titles
	local cols = { { L["When"], 12 }, { L["Quest or task"], 92 }, { L["Est."], 330 }, { L["Took"], 380 }, { "XP", 440 }, { L["Fights"], 496 } }
	for _, c in ipairs(cols) do
		local t = S:Font(f, 10)
		t:SetPoint("TOPLEFT", c[2], -74)
		t:SetText(c[1])
		t:SetTextColor(unpack(S.colors.muted))
	end

	local sc, content = S:ScrollArea(f)
	sc:SetPoint("TOPLEFT", 8, -90)
	sc:SetPoint("BOTTOMRIGHT", -8, 10)
	content:SetWidth(540)
	f.sc, f.content, f.rows = sc, content, {}
	return f
end

local function row(i)
	local S = SoA.Style
	local r = win.rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, win.content)
	r:SetHeight(ROW_H)
	r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	r:SetPoint("RIGHT", win.content, "RIGHT")
	r.hl = r:CreateTexture(nil, "BACKGROUND")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.05)
	r.hl:Hide()
	r.cells = {}
	for c, x in ipairs({ 4, 84, 322, 372, 432, 488 }) do
		local t = S:Font(r, 11)
		t:SetPoint("LEFT", x, 0)
		t:SetWordWrap(false)
		if c == 2 then t:SetWidth(230) t:SetJustifyH("LEFT") end
		r.cells[c] = t
	end
	r:SetScript("OnEnter", function(self)
		self.hl:Show()
		local rec = self.rec
		if not rec then return end
		local L = SoA.L
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(rec.title or "?", 1, 0.82, 0)
		if rec.epic then GameTooltip:AddLine(rec.epic, 0.8, 0.8, 0.8) end
		GameTooltip:AddLine(date("%Y-%m-%d %H:%M", rec.t), 0.6, 0.65, 0.71)
		if rec.deaths then GameTooltip:AddLine(L["Deaths"] .. ": " .. rec.deaths, 1, 0.4, 0.4) end
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function(self) self.hl:Hide() GameTooltip:Hide() end)
	win.rows[i] = r
	return r
end

function A:Refresh()
	if not (win and win:IsShown()) then return end
	local L, S = SoA.L, SoA.Style
	local text = win.search:GetText() or ""
	win.search.hint:SetShown(text == "")
	local list = self:Filter(text)
	local s = self:Totals(list)
	local parts = {
		L["%d done"]:format(s.n),
		S:Short(s.xp) .. " XP",
		S:Minutes(s.act / 60) .. " " .. L["measured"],
	}
	if s.ratio then
		parts[#parts + 1] = s.ratio > 1.1 and L["you take %d%% longer than estimated"]:format((s.ratio - 1) * 100 + 0.5)
			or s.ratio < 0.9 and L["you are %d%% faster than estimated"]:format((1 - s.ratio) * 100 + 0.5)
			or L["estimates are right"]
	end
	if s.deaths > 0 then parts[#parts + 1] = L["%d deaths"]:format(s.deaths) end
	win.sum:SetText(table.concat(parts, "   |cff666666·|r   "))
	for i, rec in ipairs(list) do
		local r = row(i)
		r.rec = rec
		r.cells[1]:SetText(date("%d/%m %H:%M", rec.t))
		r.cells[2]:SetText((rec.kind == "ticket" and "|cff69ccf0#|r " or "") .. tostring(rec.title or "?"))
		r.cells[3]:SetText(num(rec.est) and S:Minutes(rec.est) or "")
		local took = num(rec.act) and rec.act / 60
		r.cells[4]:SetText(took and S:Minutes(took) or "")
		if took and num(rec.est) and took > rec.est * 1.25 then r.cells[4]:SetTextColor(1, 0.6, 0.3)
		else r.cells[4]:SetTextColor(0.85, 0.87, 0.9) end
		r.cells[5]:SetText(num(rec.xp) and S:Short(rec.xp) or "")
		r.cells[6]:SetText(rec.fights and tostring(rec.fights) or "")
		r:Show()
	end
	for i = #list + 1, #win.rows do win.rows[i]:Hide() end
	win.content:SetHeight(math.max(10, #list * ROW_H))
	win.sc:Refresh()
end

function A:Show()
	win = win or build()
	win:Show()
	self:Refresh()
end

function A:Toggle()
	if win and win:IsShown() then win:Hide() else self:Show() end
end

function A:OnEnable()
	adb()
	-- turned in: after Sprint.lua noted it in SoA.sessionDone
	SoA:On("QUEST_TURNED_IN", function(_, id, xp)
		id = num(id)
		if not id then return end
		C_Timer.After(1, function()
			local d
			for _, s in ipairs(SoA.sessionDone) do if s.id == id then d = s break end end
			A:Add({ key = id, title = (d and d.title) or SoA.Log:Title(id), kind = "quest", t = (d and d.t) or time(),
				xp = (d and num(d.xp)) or num(xp), est = d and num(d.minutes), epic = d and d.epicName })
		end)
	end)
	SoA:Listen("TICKET_STATUS", function() A:SyncTickets() end)
	C_Timer.After(20, function() SoA.guard("archive", function() A:Backfill() A:SyncTickets() end) end)
	C_Timer.NewTicker(120, function() SoA.guard("archive", function() A:SyncTickets() end) end)
end
