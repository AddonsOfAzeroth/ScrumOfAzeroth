-- Scrum of Azeroth by DinX: the quest board (Kanban / Scrum).
-- Plain (insecure) frames only, so it is safe to open and redraw in combat.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local B = SoA:NewModule("Board")
local A = SoA.Actions
B.cardByKey = {} -- key -> card frame (current render), for partner highlight and focus
B.expanded = {}  -- combo cards that are opened (session only)
local passes     -- filter test (defined below)

local W, H = 1000, 580
local HEAD_H, INFO_H, STRIP_H, FOOT_H = 30, 18, 46, 18
local PAD, GAP = 8, 6
local BACKLOG_W = 180
local CARD_PAD = 6
local MAX_LINES = 5
local CHECK_ON = "|TInterface\\Buttons\\UI-CheckBox-Check:12:12|t "
local CHECK_OFF = "|TInterface\\Buttons\\UI-CheckBox-Up:12:12|t "

local COLS = {
	{ key = "todo", label = "To do" },
	{ key = "doing", label = "In progress" },
	{ key = "ready", label = "Ready" },
	{ key = "done", label = "Done" },
	{ key = "hold", label = "On hold" },
}

local function cfg() return SoA.char.board end

---------------------------------------------------------------------------
-- Priority icon: Jira-like chevrons drawn from rotated bars (own textures)
---------------------------------------------------------------------------
local function prioIcon(parent)
	local f = CreateFrame("Button", nil, parent)
	f:SetSize(12, 12)
	f.bars = {}
	for i = 1, 4 do
		local t = f:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(1, 1, 1, 1)
		f.bars[i] = t
	end
	f.pin = f:CreateTexture(nil, "OVERLAY")
	f.pin:SetColorTexture(1, 0.82, 0, 1)
	f.pin:SetSize(3, 3)
	f.pin:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
	return f
end

-- level 1..5: double up, up, equals, down, double down
local function setPrio(f, level, pinned)
	local c = SoA.Priority:Color(level)
	for _, t in ipairs(f.bars) do t:Hide() t:SetVertexColor(c[1], c[2], c[3]) end
	local function chevron(i, dy, up)
		local a, b = f.bars[i], f.bars[i + 1]
		for k, t in ipairs({ a, b }) do
			t:SetSize(6, 2)
			t:ClearAllPoints()
			t:SetPoint("CENTER", f, "CENTER", (k == 1 and -2 or 2), dy)
			local ang = math.rad(45) * ((k == 1) == up and 1 or -1)
			if not pcall(t.SetRotation, t, ang) then t:SetSize(5, 2) end
			t:Show()
		end
	end
	if level == 1 then chevron(1, 2, true) chevron(3, -2, true)
	elseif level == 2 then chevron(1, 0, true)
	elseif level == 4 then chevron(1, 0, false)
	elseif level == 5 then chevron(1, 2, false) chevron(3, -2, false)
	else
		for i = 1, 2 do
			local t = f.bars[i]
			t:SetSize(8, 2)
			pcall(t.SetRotation, t, 0)
			t:ClearAllPoints()
			t:SetPoint("CENTER", f, "CENTER", 0, i == 1 and 2 or -2)
			t:Show()
		end
	end
	f.pin:SetShown(pinned and true or false)
end

---------------------------------------------------------------------------
-- Context menu (priority, blockers, filter)
---------------------------------------------------------------------------
-- Two levels: the main menu and one submenu that opens on hover. Lighter than
-- the panels with an accent border, so it stands out from the board behind it.
-- Entry fields: text, fn(note), color, header, checked, sub = { entries }, note.
local MENU_BG = { 0.14, 0.16, 0.21, 1 }
local ROW_H, MIN_W = 18, 150
local menus = {}

local function hideMenu()
	for i = #menus, 1, -1 do menus[i]:Hide() end
end

local function getMenu(level)
	local m = menus[level]
	if m then return m end
	local S = SoA.Style
	local name = "ScrumOfAzerothMenu" .. level
	m = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
	m:SetFrameStrata("FULLSCREEN_DIALOG")
	m:SetFrameLevel(10 + level * 10)
	m:SetClampedToScreen(true)
	m:EnableMouse(true)
	m:SetBackdrop({ bgFile = S.flat, edgeFile = S.flat, edgeSize = 1 })
	m:SetBackdropColor(unpack(MENU_BG))
	m:SetBackdropBorderColor(unpack(S.colors.accent))
	m.rows, m.seps = {}, {}
	m.note = CreateFrame("EditBox", nil, m, "BackdropTemplate")
	S:Backdrop(m.note, 1)
	m.note:SetFont(S.font, 11, "")
	m.note:SetTextInsets(4, 4, 0, 0)
	m.note:SetAutoFocus(false)
	m.note:SetMaxLetters(60)
	m.note:SetScript("OnEscapePressed", function(e) e:ClearFocus() hideMenu() end)
	m.note:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)
	m.noteLabel = S:Font(m, 10)
	m.noteLabel:SetTextColor(unpack(S.colors.muted))
	m:SetScript("OnHide", function(f)
		f.note:ClearFocus()
		if menus[level + 1] then menus[level + 1]:Hide() end
	end)
	tinsert(UISpecialFrames, name)
	menus[level] = m
	return m
end

local showMenuLevel

local function openSub(row, entry, level)
	local sub = getMenu(level + 1)
	if sub:IsShown() and sub.owner == row then return end
	showMenuLevel(level + 1, row, entry.sub, entry.note)
	sub.owner = row
end

function showMenuLevel(level, anchor, entries, withNote)
	local S = SoA.Style
	local L = SoA.L
	local m = getMenu(level)
	if menus[level + 1] then menus[level + 1]:Hide() end
	local w = MIN_W
	local y = -4
	local nsep = 0
	for i, e in ipairs(entries) do
		local r = m.rows[i]
		if not r then
			r = CreateFrame("Button", nil, m)
			r:SetHeight(ROW_H)
			r.text = S:Font(r, 11)
			r.text:SetPoint("LEFT", 16, 0)
			r.text:SetJustifyH("LEFT")
			r.mark = S:Font(r, 11)
			r.mark:SetPoint("LEFT", 5, 0)
			r.arrow = S:Font(r, 11)
			r.arrow:SetPoint("RIGHT", -6, 0)
			r.arrow:SetText(">")
			local hl = r:CreateTexture(nil, "HIGHLIGHT")
			hl:SetAllPoints()
			hl:SetColorTexture(S.colors.accent[1], S.colors.accent[2], S.colors.accent[3], 0.22)
			m.rows[i] = r
		end
		if e.header and i > 1 then
			nsep = nsep + 1
			local line = m.seps[nsep]
			if not line then
				line = m:CreateTexture(nil, "ARTWORK")
				line:SetHeight(1)
				m.seps[nsep] = line
			end
			line:SetColorTexture(1, 1, 1, 0.12)
			line:ClearAllPoints()
			line:SetPoint("TOPLEFT", 6, y - 2)
			line:SetPoint("TOPRIGHT", -6, y - 2)
			line:Show()
			y = y - 5
		end
		r.text:SetText(e.text)
		local c = e.header and S.gold or e.color or S.colors.text
		r.text:SetTextColor(c[1], c[2], c[3])
		r.mark:SetText(e.checked and "•" or "")
		r.mark:SetTextColor(unpack(S.colors.accent))
		r.arrow:SetShown(e.sub and true or false)
		r:SetEnabled(not e.header)
		r:SetScript("OnEnter", function(row)
			if e.sub then openSub(row, e, level)
			elseif menus[level + 1] then menus[level + 1]:Hide() end
		end)
		r:SetScript("OnClick", function(row)
			if e.sub then openSub(row, e, level) return end
			local note = m.note:IsShown() and m.note:GetText() or nil
			hideMenu()
			if e.fn then SoA.guard("menu", e.fn, note) end
		end)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", 1, y)
		r:SetPoint("TOPRIGHT", -1, y)
		r:Show()
		w = math.max(w, (r.text:GetStringWidth() or 0) + (e.sub and 40 or 28))
		y = y - ROW_H
	end
	for i = #entries + 1, #m.rows do m.rows[i]:Hide() end
	for i = nsep + 1, #m.seps do m.seps[i]:Hide() end
	if withNote then
		m.noteLabel:SetText(L["Note (optional)"])
		m.noteLabel:ClearAllPoints()
		m.noteLabel:SetPoint("TOPLEFT", 8, y - 4)
		m.noteLabel:Show()
		m.note:ClearAllPoints()
		m.note:SetPoint("TOPLEFT", 6, y - 16)
		m.note:SetPoint("TOPRIGHT", -6, y - 16)
		m.note:SetHeight(18)
		m.note:SetText(withNote ~= true and withNote or "")
		m.note:Show()
		y = y - 40
	else
		m.note:Hide()
		m.noteLabel:Hide()
	end
	w = math.min(math.ceil(w), 320)
	m:SetSize(w, -y + 4)
	m:ClearAllPoints()
	if level == 1 then
		m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	else
		-- open to the right of the row, or to the left when there is no room
		local right = (anchor:GetRight() or 0) * anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
		if right + w > UIParent:GetRight() then
			m:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -2, 4)
		else
			m:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 4)
		end
	end
	m:Show()
end

local function showMenu(anchor, entries, withNote)
	hideMenu()
	showMenuLevel(1, anchor, entries, withNote)
end

B.ShowMenu = showMenu
B.HideMenu = hideMenu
B.PrioIcon = prioIcon
B.SetPrio = setPrio

local MOVE_TO = { { "todo", "To do" }, { "doing", "In progress" }, { "ready", "Ready" } }

-- "Move to..." entries (manual status move of a quest or ticket)
local function moveEntries(entries, it)
	local L = SoA.L
	if not (it.kind == "quest" or it.kind == "ticket") then return end
	for _, s in ipairs(MOVE_TO) do
		entries[#entries + 1] = { text = L[s[2]], checked = it.column == s[1], fn = function() SoA.Flow:MoveTo(it, s[1]) B:NotifyCK() end }
	end
	if it.kind == "ticket" then
		entries[#entries + 1] = { text = L["Done"], checked = it.column == "done", fn = function() SoA.Flow:MoveTo(it, "done") end }
	end
	if (it.kind == "quest" and it.manualStatus) or (it.kind == "ticket" and it.ticket and it.ticket.manual) then
		entries[#entries + 1] = { text = L["Resume automatic"], color = SoA.Style.colors.accent, fn = function()
			if it.kind == "quest" then SoA.Flow:ResumeAuto(it.id) else SoA.Tickets:ResumeAuto(it.key) end
		end }
	end
end

function B.MoveMenu(anchor, it)
	local entries = {}
	moveEntries(entries, it)
	if #entries > 0 then showMenu(anchor, entries) end
end

local function holdEntries(entries, it)
	local L, Hd = SoA.L, SoA.Hold
	local h = Hd:Get(it.key)
	if h then
		entries[#entries + 1] = { text = L["Resume"], color = SoA.Style.green, fn = function() Hd:Resume(it.key) end }
		local lvl = (it.level and it.level > (num(UnitLevel("player"), 1)) and it.level) or (num(UnitLevel("player"), 1) + 1)
		entries[#entries + 1] = { text = L["Resume when: level %d"]:format(lvl), fn = function() Hd:SetCondition(it.key, { level = lvl }) end }
		entries[#entries + 1] = { text = L["Resume when: in a group"], fn = function() Hd:SetCondition(it.key, { group = true }) end }
		entries[#entries + 1] = { text = L["Resume when: back in this zone"], fn = function() Hd:SetCondition(it.key, { map = SoA:PlayerMap() }) end }
	else
		for _, r in ipairs(Hd.REASONS) do
			entries[#entries + 1] = { text = L[r],
				fn = function(note) Hd:Put(it.key, r, note, it.ticket and it.ticket.status, it.title) end }
		end
	end
	return h
end

function B.HoldMenu(anchor, it)
	local entries = {}
	local h = holdEntries(entries, it)
	showMenu(anchor, entries, not h)
end

local function itemMenu(anchor, it)
	local L, P, Bl = SoA.L, SoA.Priority, SoA.Blockers
	if it.kind == "combo" then it = it.members[1] end
	local entries = {}
	entries[#entries + 1] = { text = L["Details"], color = SoA.Style.colors.accent, fn = function() SoA.Detail:Open(it) end }
	if SoA.Flow:CanStart(it) then
		entries[#entries + 1] = { text = L["Start"], color = SoA.Style.green, fn = function() SoA.Flow:Start(it) end }
	end
	if it.epicKey and it.epicKey ~= "loose" and not it.epicKey:find("^lb:") then
		entries[#entries + 1] = { text = L["Epic details"], color = it.color, fn = function() SoA.Detail:OpenEpic(it.epicKey) end }
	end
	if SoA.EpicFlow and SoA.EpicFlow:CanShow(it) then
		entries[#entries + 1] = { text = L["Show flow"], color = it.color, fn = function() SoA.EpicFlow:OpenFor(it) end }
	end
	if it.kind == "quest" then
		entries[#entries + 1] = { text = L["Open in quest log"], fn = function() A.Open(it.id, it.index) end }
	elseif it.kind == "ticket" then
		entries[#entries + 1] = { text = L["Edit ticket"], fn = function() SoA.Tickets:OpenDialog(it.key) end }
	end
	if it.kind ~= "quest" and it.kind ~= "ticket" then
		showMenu(anchor, entries)
		return
	end
	local move = {}
	moveEntries(move, it)
	entries[#entries + 1] = { text = L["Move to..."], sub = move }
	local prio = {}
	for lvl = 1, 5 do
		prio[#prio + 1] = { text = P:Name(lvl), color = P:Color(lvl), checked = it.priority == lvl,
			fn = function() P:SetManual(it.key, lvl) B:NotifyCK() end }
	end
	prio[#prio + 1] = { text = L["Reset to automatic"], fn = function() P:SetManual(it.key, nil) B:NotifyCK() end }
	entries[#entries + 1] = { text = L["Priority"], sub = prio }
	local block = {}
	for _, r in ipairs(Bl.REASONS) do
		block[#block + 1] = { text = L[r], fn = function(note) Bl:SetManual(it.key, r, note) end }
	end
	local m = Bl:Manual(it.key)
	if m then
		block[#block + 1] = { text = L["Unblock"], color = SoA.Style.green, fn = function() Bl:SetManual(it.key, nil) end }
	end
	entries[#entries + 1] = { text = L["Blocker"], sub = block, note = (m and m.text) or true }
	local hold = {}
	local h = holdEntries(hold, it)
	entries[#entries + 1] = { text = h and L["On hold"] or L["Put on hold"], sub = hold, note = not h }
	showMenu(anchor, entries)
end
B.ItemMenu = itemMenu

---------------------------------------------------------------------------
-- Click actions
---------------------------------------------------------------------------
-- Shared by cards, list rows and the compact tracker:
-- click: select / point + details · shift-click: GPS stop · right-click: card menu.
function B.ClickItem(it, button, anchor, fromTracker)
	if not it then return end
	hideMenu()
	if it.kind == "combo" then
		if button == "RightButton" then itemMenu(anchor, it) return end
		B.expanded[it.key] = not B.expanded[it.key]
		B:Schedule(true)
		return
	end
	if button == "RightButton" then itemMenu(anchor, it) return end
	local shift = IsShiftKeyDown()
	if it.kind == "quest" then
		if shift then A.AddStop(it.id, it.title) return end
		A.Select(it.id, it.title)
	elseif it.kind == "avail" then
		if it.mapID and it.x and it.y then
			if shift then A.AddPointStop(it.mapID, it.x, it.y, it.title) return end
			A.PointTo(it.mapID, it.x, it.y, it.title)
		end
	elseif it.kind == "ticket" then
		if it.map then
			if shift then A.AddPointStop(it.map.m, it.map.x, it.map.y, it.title) return end
			A.PointTo(it.map.m, it.map.x, it.map.y, it.title)
		end
	end
	if fromTracker and (it.kind == "quest" or it.kind == "ticket") then
		SoA.Detail:OpenFromTracker(it.kind == "quest" and it.id or it.key, anchor)
	else
		SoA.Detail:Open(it)
	end
	B:Schedule()
end

local function onCardClick(self, button)
	SoA.guard("card click", B.ClickItem, self.item, button, self)
end

local function cardTooltip(self)
	SoA.guard("card tip", function()
		local it = self.item
		if not (it and GameTooltip) then return end
		local L, S = SoA.L, SoA.Style
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(it.title or "?", 1, 1, 1, 1, true)
		if it.epicName then
			local c = it.color or S.colors.muted
			GameTooltip:AddLine(it.epicName .. (it.epic and it.epic.tag and ("  (" .. it.epic.tag .. ")") or ""), c[1], c[2], c[3])
		end
		if it.priority and it.kind ~= "done" then
			local c = SoA.Priority:Color(it.priority)
			GameTooltip:AddDoubleLine(L["Priority"], SoA.Priority:Name(it.priority) .. (it.pinned and (" (" .. L["manual"] .. ")") or ""),
				0.6, 0.65, 0.71, c[1], c[2], c[3])
			if it.why and it.why ~= "" then GameTooltip:AddLine(it.why, 0.6, 0.65, 0.71, true) end
		end
		if it.est then
			GameTooltip:AddDoubleLine(L["Estimate"], SoA.Estimate:Format(it.est) .. (it.est.learned and (" · " .. L["learned"]) or (" · " .. L["estimate"])),
				0.6, 0.65, 0.71, 1, 1, 1)
			GameTooltip:AddLine(table.concat(it.est.parts or {}, " · "), 0.6, 0.65, 0.71, true)
		end
		if it.xp then GameTooltip:AddDoubleLine(L["XP"], S:Digits(it.xp) .. (it.xpm and ("  (" .. L["XP/min %d"]:format(it.xpm + 0.5) .. ")") or ""), 0.6, 0.65, 0.71, 1, 0.82, 0) end
		if it.blockReasons and #it.blockReasons > 0 then
			for _, r in ipairs(it.blockReasons) do GameTooltip:AddLine(L["Blocked"] .. ": " .. r, 1, 0.3, 0.3, true) end
		end
		if it.kind == "upcoming" and it.after then GameTooltip:AddLine(L["Blocked by: %s"]:format(it.after), 1, 0.5, 0.5, true) end
		if it.blocks then GameTooltip:AddLine(L["Blocks: %s"]:format(it.blocks), 0.6, 0.65, 0.71, true) end
		if it.upgrade then SoA.Upgrade:Tooltip(GameTooltip, it.upgrade) end
		if it.turnIn then GameTooltip:AddLine(L["Turn in: %s"]:format(it.turnIn), 0.3, 0.9, 0.3, true) end
		if it.onHold then GameTooltip:AddLine(L["On hold"] .. ": " .. (it.holdText or ""), 1, 0.82, 0, true) end
		if it.shared and it.shared.note then GameTooltip:AddLine(it.shared.note, 0.41, 0.8, 0.94, true) end
		if it.story and it.story ~= it.epic then GameTooltip:AddLine(L["Zone story"] .. ": " .. (it.story.name or "?"), it.story.color[1], it.story.color[2], it.story.color[3]) end
		if it.holdHint then GameTooltip:AddLine(L["No progress for a while: put it on hold?"], 1, 0.82, 0, true) end
		GameTooltip:AddLine(" ")
		if it.kind == "combo" then
			GameTooltip:AddLine(L["Click: show or hide the two quests · Right-click: menu"], 0.6, 0.65, 0.71, true)
		elseif it.kind == "quest" then
			GameTooltip:AddLine(L["Click: select quest and show details · Shift-click: add as GPS stop · Right-click: menu"], 0.6, 0.65, 0.71, true)
		elseif it.kind == "avail" then
			GameTooltip:AddLine(L["Click: point to the quest giver · Shift-click: add as GPS stop"], 0.6, 0.65, 0.71, true)
		elseif it.kind == "ticket" then
			GameTooltip:AddLine(L["Click: details · Right-click: menu · Click a step to tick it"], 0.6, 0.65, 0.71, true)
		end
		GameTooltip:Show()
	end)
end

local function cardLeave(self)
	if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	C_Timer.After(0.05, function()
		if self.hover and not self:IsMouseOver() then self.hover:Hide() end
	end)
end

local function cardEnter(self)
	if self.hover and self.hoverOn then self.hover:Show() end
	cardTooltip(self)
end

---------------------------------------------------------------------------
-- Columns and cards
---------------------------------------------------------------------------
local function newColumn(parent, label)
	local S = SoA.Style
	local col = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	S:Backdrop(col, 0.45)
	col.head = S:Font(col, 12)
	col.head:SetPoint("TOPLEFT", 8, -6)
	col.head:SetTextColor(unpack(S.gold))
	col.head:SetText(label)
	col.count = S:Font(col, 11)
	col.count:SetPoint("TOPRIGHT", -8, -6)
	col.count:SetTextColor(unpack(S.colors.muted))
	local sc = CreateFrame("ScrollFrame", nil, col)
	sc:SetPoint("TOPLEFT", 4, -24)
	sc:SetPoint("BOTTOMRIGHT", -4, 4)
	local content = CreateFrame("Frame", nil, sc)
	content:SetSize(10, 10)
	sc:SetScrollChild(content)
	sc:EnableMouseWheel(true)
	sc:SetScript("OnMouseWheel", function(f, delta)
		local max = f:GetVerticalScrollRange() or 0
		f:SetVerticalScroll(math.max(0, math.min(max, (f:GetVerticalScroll() or 0) - delta * 40)))
	end)
	col.scroll, col.content = sc, content
	col.cards, col.labels = {}, {}
	return col
end

local function newLabel(col)
	local S = SoA.Style
	local l = CreateFrame("Button", nil, col.content)
	l:RegisterForClicks("LeftButtonUp")
	l.text = S:Font(l, 11)
	l.text:SetPoint("LEFT", 2, 0)
	l.text:SetJustifyH("LEFT")
	l:SetScript("OnClick", function(btn)
		if btn.foldKey then
			local f = cfg().fold
			f[btn.foldKey] = not f[btn.foldKey]
			B:Schedule()
		end
	end)
	return l
end

local function newCard(col)
	local S, L = SoA.Style, SoA.L
	local c = CreateFrame("Button", nil, col.content, "BackdropTemplate")
	S:Backdrop(c, 1)
	c:SetBackdropColor(unpack(S.card))
	c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	c:SetScript("OnClick", onCardClick)
	c:SetScript("OnEnter", cardEnter)
	c:SetScript("OnLeave", cardLeave)
	local hl = c:CreateTexture(nil, "HIGHLIGHT")
	hl:SetPoint("TOPLEFT", 1, -1)
	hl:SetPoint("BOTTOMRIGHT", -1, 1)
	hl:SetColorTexture(1, 1, 1, 0.05)
	c.stripe = c:CreateTexture(nil, "ARTWORK")
	c.stripe:SetPoint("TOPLEFT", 1, -1)
	c.stripe:SetPoint("BOTTOMLEFT", 1, 1)
	c.stripe:SetWidth(3)
	c.stripe:SetColorTexture(1, 1, 1, 1)
	c.epic = S:Font(c, 9)
	c.epic:SetPoint("TOPLEFT", CARD_PAD + 3, -CARD_PAD)
	c.epic:SetJustifyH("LEFT")
	c.epic:SetWordWrap(false)
	c.xp = S:Font(c, 9)
	c.xp:SetPoint("TOPRIGHT", -CARD_PAD, -CARD_PAD)
	c.xp:SetTextColor(unpack(S.gold))
	c.epic:SetPoint("RIGHT", c.xp, "LEFT", -4, 0)
	c.prio = prioIcon(c)
	c.prio:SetPoint("TOPLEFT", CARD_PAD + 3, -CARD_PAD - 14)
	c.prio:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	c.prio:SetScript("OnClick", function(btn) if c.item then itemMenu(btn, c.item) end end)
	c.prio:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L["Click: set priority or a blocker"], 1, 1, 1)
		GameTooltip:Show()
	end)
	c.prio:SetScript("OnLeave", function(btn) if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end end)
	c.title = S:Font(c, 12)
	c.title:SetPoint("TOPLEFT", CARD_PAD + 19, -CARD_PAD - 13)
	c.title:SetJustifyH("LEFT")
	c.title:SetWordWrap(true)
	if c.title.SetMaxLines then c.title:SetMaxLines(2) end
	c.meta = S:Font(c, 9)
	c.meta:SetJustifyH("LEFT")
	c.meta:SetWordWrap(false)
	c.meta:SetTextColor(unpack(S.colors.muted))
	c.lines = {}
	-- bottom buttons: "+ Add to sprint" (always) or hover ones
	c.action = S:Button(c, "", 110, 16)
	S:ApplyFont(c.action.text, 10)
	c.hover = CreateFrame("Frame", nil, c)
	c.hover:SetSize(160, 16)
	c.hover:SetPoint("BOTTOMRIGHT", -4, 4)
	c.hover:SetFrameLevel(c:GetFrameLevel() + 5)
	c.hover.b1 = S:Button(c.hover, "", 100, 16)
	S:ApplyFont(c.hover.b1.text, 10)
	c.hover.b1:SetPoint("RIGHT", 0, 0)
	c.hover.b2 = S:Button(c.hover, "", 60, 16)
	S:ApplyFont(c.hover.b2.text, 10)
	c.hover.b2:SetPoint("RIGHT", c.hover.b1, "LEFT", -3, 0)
	c.hover:SetScript("OnLeave", function() cardLeave(c) end)
	c.hover.b1:HookScript("OnLeave", function() cardLeave(c) end)
	c.hover.b2:HookScript("OnLeave", function() cardLeave(c) end)
	c.action:HookScript("OnLeave", function() cardLeave(c) end)
	c.hover:Hide()
	-- shared mobs: chain icon; hovering it highlights the partner card
	c.chain = S:ChainIcon(c)
	c.chain:SetPoint("RIGHT", c.xp, "LEFT", -4, 0)
	c.chain:SetScript("OnEnter", function(btn)
		local it = c.item
		local pk = it and it.shared and it.shared.partnerKey
		local p = pk and B.cardByKey[pk]
		if p and p:IsShown() then
			p:SetBackdropBorderColor(1, 0.82, 0, 1)
			B.highlighted = p
		end
		GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L["Shares mobs with %s"]:format(it and it.shared and it.shared.partner or "?"), 0.41, 0.8, 0.94, true)
		GameTooltip:Show()
	end)
	c.chain:SetScript("OnLeave", function(btn)
		if B.highlighted then
			local p = B.highlighted
			B.highlighted = nil
			if p.baseBorder then p:SetBackdropBorderColor(unpack(p.baseBorder)) end
		end
		if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
	end)
	-- the quest's usable item (display only)
	c.itemIcon = c:CreateTexture(nil, "OVERLAY")
	c.itemIcon:SetSize(14, 14)
	c.itemIcon:SetPoint("TOPRIGHT", -CARD_PAD, -CARD_PAD - 12)
	c.itemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	-- "Put on hold?" hint (opens the hold menu; never puts anything on hold by itself)
	c.holdBtn = S:Button(c, L["Put on hold?"], 90, 16)
	S:ApplyFont(c.holdBtn.text, 10)
	c.holdBtn.text:SetTextColor(1, 0.82, 0)
	c.holdBtn:SetScript("OnClick", function(btn) if c.item then B.HoldMenu(btn, c.item) end end)
	c.holdBtn:HookScript("OnLeave", function() cardLeave(c) end)
	c.holdBtn:Hide()
	return c
end

local function lineRow(c, i)
	local r = c.lines[i]
	if r then return r end
	local S = SoA.Style
	r = CreateFrame("Button", nil, c)
	r:SetHeight(13)
	r.text = S:Font(r, 10)
	r.text:SetPoint("LEFT", 0, 0)
	r.text:SetPoint("RIGHT", 0, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	r:SetScript("OnClick", function(btn)
		if btn.ticketKey and btn.check then
			SoA.Tickets:Toggle(btn.ticketKey, btn.check)
		else
			onCardClick(c, "LeftButton")
		end
	end)
	r:SetScript("OnEnter", function() cardEnter(c) end)
	r:SetScript("OnLeave", function() cardLeave(c) end)
	c.lines[i] = r
	return r
end

-- Fill one card; returns its height.
local function fillCard(c, it, width, opts)
	local S, L = SoA.Style, SoA.L
	c.item = it
	c:SetWidth(width)
	local col = it.color or S.colors.muted
	c.stripe:SetVertexColor(col[1], col[2], col[3])
	c.epic:SetText(it.epicName or (it.kind == "ticket" and L["Ticket"]) or L["Loose tasks"])
	c.epic:SetTextColor(col[1], col[2], col[3])
	local xpText = it.xp and (S:Short(it.xp) .. " XP") or ""
	c.xp:SetText(xpText)
	local showPrio = it.kind == "quest" or it.kind == "ticket"
	c.prio:SetShown(showPrio)
	if showPrio then setPrio(c.prio, it.priority or 3, it.pinned) end
	c.chain:SetShown(it.shared ~= nil or it.kind == "combo")
	c.itemIcon:SetShown(it.itemTex ~= nil)
	if it.itemTex then c.itemIcon:SetTexture(it.itemTex) end
	local title = it.title or "?"
	if it.kind == "quest" and it.showLevel then title = "[" .. it.showLevel .. "] " .. title end
	c.title:SetWidth(width - CARD_PAD * 2 - 19 - (it.itemTex and 16 or 0))
	c.title:SetText(title)
	local dim = it.kind == "done" or it.kind == "upcoming" or (it.onHold and not it.resumeReady)
	if dim then c.title:SetTextColor(0.6, 0.6, 0.6) else c.title:SetTextColor(1, 1, 1) end
	local y = CARD_PAD + 13 + math.max(12, c.title:GetStringHeight() or 12) + 3

	-- meta line: estimate, badges
	local meta = {}
	if it.est and it.kind ~= "done" then meta[#meta + 1] = SoA.Estimate:Format(it.est) end
	if it.blocked and it.kind ~= "upcoming" then meta[#meta + 1] = "|cffff4d4d" .. L["Blocked"] .. "|r" end
	if it.upgrade then meta[#meta + 1] = "|cff4ce64c" .. L["Upgrade"] .. "|r" end
	if it.kind == "upcoming" then meta[#meta + 1] = L["after: %s"]:format(it.after or "?") end
	if it.ready and it.turnIn then meta[#meta + 1] = "|cff4ce64c" .. L["Turn in: %s"]:format(it.turnIn) .. "|r" end
	if it.kind == "done" and it.minutes then meta[#meta + 1] = S:Minutes(it.minutes) end
	if opts.proposed then meta[#meta + 1] = "|cff69ccf0" .. L["Proposed"] .. "|r" end
	if it.onHold then
		meta[#meta + 1] = it.resumeReady and ("|cff4ce64c> " .. L["Ready to resume"] .. "|r") or ("|cffffd100" .. L["On hold"] .. "|r")
	end
	if it.shared then meta[#meta + 1] = "|cff69ccf0" .. L["shared with %s"]:format(it.shared.partner or "?") .. "|r" end
	if it.tagName then meta[#meta + 1] = it.tagName end
	c.meta:ClearAllPoints()
	c.meta:SetPoint("TOPLEFT", CARD_PAD + 3, -y)
	c.meta:SetWidth(width - CARD_PAD * 2 - 3)
	c.meta:SetText(table.concat(meta, "  "))
	if #meta > 0 then y = y + 12 end

	-- objectives as a checklist
	local n = 0
	for _, o in ipairs(it.objectives or {}) do
		if o.text and o.text ~= "" then
			n = n + 1
			if n > MAX_LINES then
				local r = lineRow(c, n)
				r.text:SetText("|cff999999" .. L["+%d more"]:format(#it.objectives - MAX_LINES) .. "|r")
				r.ticketKey, r.check = nil, nil
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", CARD_PAD + 3, -y)
				r:SetWidth(width - CARD_PAD * 2 - 3)
				r:Show()
				y = y + 13
				break
			end
			local r = lineRow(c, n)
			r.text:SetText((o.done and CHECK_ON or CHECK_OFF) .. o.text)
			if o.done then r.text:SetTextColor(0.45, 0.85, 0.45) else r.text:SetTextColor(0.85, 0.87, 0.9) end
			r.ticketKey = it.kind == "ticket" and it.key or nil
			r.check = o.check
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", CARD_PAD + 3, -y)
			r:SetWidth(width - CARD_PAD * 2 - 3)
			r:Show()
			y = y + 13
		end
	end
	for i = n + 1, #c.lines do c.lines[i]:Hide() end

	-- buttons
	c.action:Hide()
	c.hoverOn = false
	c.hover:Hide()
	c.holdBtn:Hide()
	if opts.add then
		c.action.text:SetText(L["+ Add to sprint"])
		c.action:SetScript("OnClick", function() SoA.Sprint:Add(it.key) B:NotifyCK() end)
		c.action:ClearAllPoints()
		c.action:SetPoint("TOPLEFT", CARD_PAD + 3, -(y + 2))
		c.action:Show()
	end
	if it.holdHint and not it.onHold then
		c.holdBtn:ClearAllPoints()
		if opts.add then
			c.holdBtn:SetPoint("LEFT", c.action, "RIGHT", 4, 0)
		else
			c.holdBtn:SetPoint("TOPLEFT", CARD_PAD + 3, -(y + 2))
		end
		c.holdBtn:Show()
	end
	if opts.add or (it.holdHint and not it.onHold) then y = y + 20 end
	local b1, b2 = c.hover.b1, c.hover.b2
	b2:Hide()
	if opts.remove then
		c.hoverOn = true
		b1.text:SetText(L["Back to backlog"])
		b1:SetWidth(100)
		b1:SetScript("OnClick", function() SoA.Sprint:Remove(it.key) B:NotifyCK() end)
	end
	if it.kind == "ticket" then
		c.hoverOn = true
		if not opts.remove then
			b1.text:SetText(L["Move >"])
			b1:SetWidth(60)
			b1:SetScript("OnClick", function() SoA.Tickets:Move(it.key, 1) end)
		end
		b2.text:SetText(opts.remove and L["Move >"] or L["< Move"])
		b2:SetScript("OnClick", function() SoA.Tickets:Move(it.key, opts.remove and 1 or -1) end)
		b2:Show()
	end
	if c.hoverOn then y = y + 4 end

	-- selection and dimming
	local sel = it.kind == "quest" and A.Selected and A.Selected() == it.id
	local shown = SoA.Detail and SoA.Detail:IsShowing(it.kind == "quest" and it.id or it.key)
	if shown then
		c.baseBorder = { 1, 0.82, 0, 1 }
	elseif sel or opts.proposed then
		c.baseBorder = { S.colors.accent[1], S.colors.accent[2], S.colors.accent[3], 1 }
	elseif it.blocked and it.kind ~= "upcoming" then
		c.baseBorder = { 0.6, 0.15, 0.15, 1 }
	else
		c.baseBorder = { 0, 0, 0, 1 }
	end
	c:SetBackdropBorderColor(unpack(c.baseBorder))
	c:SetAlpha(dim and 0.55 or 1)
	local h = y + CARD_PAD
	c:SetHeight(h)
	return h
end

-- Lays out a list of { label = ..., foldKey = ... } and item rows in a column.
local function layout(col, rows, opts)
	local width = math.max(60, (col:GetWidth() or 200) - 12)
	local y, ci, li = 0, 0, 0
	for _, row in ipairs(rows) do
		if row.label then
			li = li + 1
			local l = col.labels[li] or newLabel(col)
			col.labels[li] = l
			l.foldKey = row.foldKey
			l.text:SetText(row.label)
			local c = row.color or SoA.Style.colors.muted
			l.text:SetTextColor(c[1], c[2], c[3])
			l:ClearAllPoints()
			l:SetPoint("TOPLEFT", col.content, "TOPLEFT", 0, -y)
			l:SetSize(width, 16)
			l:Show()
			y = y + 18
		else
			ci = ci + 1
			local c = col.cards[ci] or newCard(col)
			col.cards[ci] = c
			c:ClearAllPoints()
			c:SetPoint("TOPLEFT", col.content, "TOPLEFT", 0, -y)
			local h = fillCard(c, row.item, width, row.opts or opts or {})
			c:Show()
			c.col, c.top, c.bottom = col, y, y + h
			B.cardByKey[row.item.key] = c
			if row.item.kind == "quest" then B.cardByKey[row.item.id] = c end
			y = y + h + 4
		end
	end
	for i = ci + 1, #col.cards do col.cards[i]:Hide() col.cards[i].item = nil end
	for i = li + 1, #col.labels do col.labels[i]:Hide() end
	col.content:SetSize(width, math.max(1, y))
	local max = math.max(0, y - ((col.scroll:GetHeight() or 0)))
	if (col.scroll:GetVerticalScroll() or 0) > max then col.scroll:SetVerticalScroll(max) end
	if col.scroll.UpdateScrollChildRect then col.scroll:UpdateScrollChildRect() end
end

-- Shared quests in the same column as one combo card ("<mob>: A kills 5/8 · B items 3/6, ~6 min").
local function comboRows(list, makeOpts)
	local L, S = SoA.L, SoA.Style
	local rows, used = {}, {}
	local inList = {}
	for _, it in ipairs(list) do inList[it.key] = it end
	for _, it in ipairs(list) do
		if not used[it.key] then
			local partner = it.shared and inList[it.shared.partnerKey]
			if cfg().groupShared and partner and not used[partner.key] then
				used[it.key], used[partner.key] = true, true
				local kill = it.shared.role == "kill" and it or partner
				local item = kill == it and partner or it
				local function part(x, word)
					local sh = x.shared
					return ("%s %s %d/%d"):format(x.title or "?", word, sh.have or 0, sh.need or 0)
				end
				local mob = it.shared.mob
				if not mob and kill.shared.text then mob = (kill.shared.text:gsub("^%d+/%d+%s*", "")) end
				mob = mob or "?"
				local mins = (kill.minutes or 0) + (item.minutes or 0)
				local key = "c:" .. tostring(kill.key) .. ":" .. tostring(item.key)
				local combo = {
					kind = "combo", key = key, members = { kill, item },
					title = ("%s: %s · %s, ~%s"):format(mob, part(kill, L["kills"]), part(item, L["items"]), S:Minutes(mins)),
					epicName = kill.epicName, color = kill.color, epicKey = kill.epicKey,
					xp = (kill.xp or 0) + (item.xp or 0), minutes = mins, priority = math.min(kill.priority or 3, item.priority or 3),
					objectives = {}, inSprint = kill.inSprint or item.inSprint,
				}
				rows[#rows + 1] = { item = combo, opts = {} }
				if B.expanded[key] then
					rows[#rows + 1] = { item = kill, opts = makeOpts(kill) }
					rows[#rows + 1] = { item = item, opts = makeOpts(item) }
				end
			else
				used[it.key] = true
				rows[#rows + 1] = { item = it, opts = makeOpts(it) }
			end
		end
	end
	return rows
end

---------------------------------------------------------------------------
-- Burndown: dashed ideal line and the actual line (own textures)
---------------------------------------------------------------------------
local function drawBurndown(chart, st)
	local S = SoA.Style
	chart.tex = chart.tex or {}
	local used = 0
	local function tex()
		used = used + 1
		local t = chart.tex[used]
		if not t then
			t = chart:CreateTexture(nil, "OVERLAY")
			t:SetColorTexture(1, 1, 1, 1)
			chart.tex[used] = t
		end
		t:Show()
		return t
	end
	local w, h = chart:GetWidth() - 4, chart:GetHeight() - 4
	local samples = st and st.samples or {}
	local t0 = num(st and st.started, time())
	local committed = math.max(1, num(st and st.committed, 0))
	local maxV = committed
	for _, s in ipairs(samples) do maxV = math.max(maxV, num(s.m, 0)) end
	local tEnd = math.max(time(), t0 + committed * 60)
	local span = math.max(60, tEnd - t0)
	local function X(t) return 2 + (t - t0) / span * w end
	local function Y(v) return 2 + v / maxV * h end
	-- ideal: committed minutes burnt at one minute per minute
	local x1, y1, x2, y2 = X(t0), Y(committed), X(t0 + committed * 60), Y(0)
	local steps = math.floor(math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) / 4)
	local mu = S.colors.muted
	for i = 0, steps do
		local f = i / math.max(1, steps)
		local t = tex()
		t:SetSize(2, 1)
		t:SetVertexColor(mu[1], mu[2], mu[3], 0.8)
		t:ClearAllPoints()
		t:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", x1 + (x2 - x1) * f, y1 + (y2 - y1) * f)
	end
	-- actual: steps through the samples up to now
	local a = S.colors.accent
	local prevX, prevY
	local pts = {}
	for _, s in ipairs(samples) do pts[#pts + 1] = { X(num(s.t, t0)), Y(num(s.m, 0)) } end
	if #pts > 0 then pts[#pts + 1] = { X(time()), pts[#pts][2] } end
	for _, p in ipairs(pts) do
		if prevX then
			local hz = tex()
			hz:SetVertexColor(a[1], a[2], a[3], 1)
			hz:ClearAllPoints()
			hz:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", prevX, prevY)
			hz:SetSize(math.max(1, p[1] - prevX), 1.5)
			if math.abs(p[2] - prevY) >= 1 then
				local vt = tex()
				vt:SetVertexColor(a[1], a[2], a[3], 1)
				vt:ClearAllPoints()
				vt:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", p[1], math.min(p[2], prevY))
				vt:SetSize(1.5, math.abs(p[2] - prevY))
			end
		end
		prevX, prevY = p[1], p[2]
	end
	for i = used + 1, #chart.tex do chart.tex[i]:Hide() end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
function B:Create()
	local L, S = SoA.L, SoA.Style
	local f = CreateFrame("Frame", "ScrumOfAzerothBoard", UIParent, "BackdropTemplate")
	f:SetSize(W, H)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	S:Backdrop(f, 0.96)
	f:Hide()
	tinsert(UISpecialFrames, "ScrumOfAzerothBoard")
	local pt = SoA.char.point
	if type(pt) == "table" and pt[1] then
		f:SetPoint(pt[1], UIParent, pt[2], num(pt[3], 0), num(pt[4], 0))
	else
		f:SetPoint("CENTER", 0, 30)
	end
	f:SetScript("OnShow", function() B:Schedule(true) end)
	f:SetScript("OnHide", function()
		hideMenu()
		local D = SoA.Detail
		if D and D.frame and D.frame:IsShown() and D.frame.docked then D.frame:Hide() end
	end)
	self.frame = f

	-- header: title, Kanban/Scrum, filter, buttons, close
	local head = CreateFrame("Frame", nil, f)
	head:SetPoint("TOPLEFT", 1, -1)
	head:SetPoint("TOPRIGHT", -1, -1)
	head:SetHeight(HEAD_H)
	head:EnableMouse(true)
	head:RegisterForDrag("LeftButton")
	head:SetScript("OnDragStart", function() f:StartMoving() end)
	head:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		local p, _, rp, x, y = f:GetPoint()
		SoA.char.point = { p, rp, math.floor(x + 0.5), math.floor(y + 0.5) }
	end)
	local hb = head:CreateTexture(nil, "BACKGROUND")
	hb:SetAllPoints()
	hb:SetColorTexture(0.08, 0.10, 0.14, 1)
	local title = S:Font(head, 14)
	title:SetPoint("LEFT", 10, 0)
	title:SetText(L["Quest board"])
	title:SetTextColor(unpack(S.gold))

	self.kanbanBtn = S:Button(head, L["Kanban"], 70, 20, function() cfg().mode = "kanban" B:Schedule(true) end)
	self.kanbanBtn:SetPoint("LEFT", title, "RIGHT", 16, 0)
	self.scrumBtn = S:Button(head, L["Scrum"], 70, 20, function() cfg().mode = "scrum" B:Schedule(true) end)
	self.scrumBtn:SetPoint("LEFT", self.kanbanBtn, "RIGHT", 2, 0)
	self.listBtn = S:Button(head, L["List"], 60, 20, function() cfg().mode = "list" B:Schedule(true) end)
	self.listBtn:SetPoint("LEFT", self.scrumBtn, "RIGHT", 2, 0)

	self.filterBtn = S:Button(head, "", 170, 20, function(btn) B:FilterMenu(btn) end)
	self.filterBtn:SetPoint("LEFT", self.listBtn, "RIGHT", 16, 0)

	local close = S:Button(head, "X", 24, 20, function() f:Hide() end)
	close:SetPoint("RIGHT", -6, 0)
	local review = S:Button(head, L["Review"], 70, 20, function() SoA.Review:Toggle() end)
	review:SetPoint("RIGHT", close, "LEFT", -6, 0)
	review.tip = L["Sprint review, velocity and lifetime statistics."]
	local ticket = S:Button(head, L["+ Ticket"], 70, 20, function() SoA.Tickets:OpenDialog() end)
	ticket:SetPoint("RIGHT", review, "LEFT", -6, 0)
	ticket.tip = L["A task that is not a quest, e.g. train spells or farm cloth."]
	local settings = S:Button(head, L["Settings"], 70, 20, function() SoA:ToggleConfig() end)
	settings:SetPoint("RIGHT", ticket, "LEFT", -6, 0)
	local flowBtn = S:Button(head, L["Flow"], 60, 20, function() SoA:ToggleFlow() end)
	flowBtn:SetPoint("RIGHT", settings, "LEFT", -6, 0)
	flowBtn.tip = L["Flow view: a zoomable map of an epic or initiative."]

	-- info line: level forecast
	self.info = S:Font(f, 11)
	self.info:SetPoint("TOPLEFT", PAD + 2, -(HEAD_H + 4))
	self.info:SetPoint("TOPRIGHT", -PAD, -(HEAD_H + 4))
	self.info:SetJustifyH("LEFT")
	self.info:SetTextColor(unpack(S.colors.muted))

	-- Scrum strip
	local strip = CreateFrame("Frame", nil, f, "BackdropTemplate")
	strip:SetPoint("TOPLEFT", PAD, -(HEAD_H + INFO_H + 4))
	strip:SetPoint("TOPRIGHT", -PAD, -(HEAD_H + INFO_H + 4))
	strip:SetHeight(STRIP_H)
	S:Backdrop(strip, 0.5)
	self.strip = strip
	local gl = S:Font(strip, 11)
	gl:SetPoint("TOPLEFT", 8, -6)
	gl:SetText(L["Sprint goal"])
	gl:SetTextColor(unpack(S.colors.muted))
	local goal = CreateFrame("EditBox", nil, strip, "BackdropTemplate")
	goal:SetSize(260, 20)
	goal:SetPoint("TOPLEFT", 8, -20)
	S:Backdrop(goal, 1)
	goal:SetFont(S.font, 12, "")
	goal:SetTextInsets(6, 6, 0, 0)
	goal:SetAutoFocus(false)
	goal:SetMaxLetters(80)
	local function saveGoal(e) SoA.Sprint:SetGoal(e:GetText()) e:ClearFocus() end
	goal:SetScript("OnEnterPressed", saveGoal)
	goal:SetScript("OnEditFocusLost", function(e) SoA.Sprint:SetGoal(e:GetText()) end)
	goal:SetScript("OnEscapePressed", function(e) e:SetText(SoA.Sprint.Data().goal or "") e:ClearFocus() end)
	self.goal = goal

	-- both lines stop before the burndown chart / sprint buttons and end in "..." when too long
	self.stripText = S:Font(strip, 11)
	self.stripText:SetPoint("TOPLEFT", 284, -8)
	self.stripText:SetPoint("TOPRIGHT", -104, -8)
	self.stripText:SetJustifyH("LEFT")
	self.stripText:SetWordWrap(false)
	self.capText = S:Font(strip, 11)
	self.capText:SetPoint("TOPLEFT", 284, -26)
	self.capText:SetPoint("TOPRIGHT", -372, -26)
	self.capText:SetJustifyH("LEFT")
	self.capText:SetWordWrap(false)

	self.chart = CreateFrame("Frame", nil, strip, "BackdropTemplate")
	self.chart:SetSize(90, 34)
	self.chart:SetPoint("RIGHT", -6, 0)
	S:Backdrop(self.chart, 0.8)
	self.chart:EnableMouse(true)
	self.chart:SetScript("OnEnter", function(c)
		GameTooltip:SetOwner(c, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText(L["Burndown"], 1, 0.82, 0)
		GameTooltip:AddLine(L["Remaining estimated minutes since the sprint started. Dashed: the ideal line."], 1, 1, 1, true)
		GameTooltip:Show()
	end)
	self.chart:SetScript("OnLeave", function(c) if GameTooltip:IsOwned(c) then GameTooltip:Hide() end end)

	self.newBtn = S:Button(strip, L["Start new sprint"], 120, 20, function()
		SoA.Sprint:NewSprint()
		SoA:Print(L["New sprint started."])
	end)
	self.newBtn:SetPoint("RIGHT", self.chart, "LEFT", -8, -10)
	self.planBtn = S:Button(strip, L["Plan sprint"], 100, 20, function() B:Propose() end)
	self.planBtn:SetPoint("RIGHT", self.newBtn, "LEFT", -6, 0)
	self.planBtn.tip = L["Proposes the top backlog items that fit the capacity. Nothing is added until you accept."]
	self.acceptBtn = S:Button(strip, L["Accept"], 70, 20, function() B:AcceptProposal() end)
	self.acceptBtn:SetPoint("RIGHT", self.newBtn, "LEFT", -6, 0)
	self.cancelBtn = S:Button(strip, L["Cancel"], 60, 20, function() B.proposal = nil B:Schedule(true) end)
	self.cancelBtn:SetPoint("RIGHT", self.acceptBtn, "LEFT", -4, 0)

	-- hint when Scrum has no sprint
	local hint = CreateFrame("Frame", nil, f)
	hint:SetSize(520, 120)
	hint:SetPoint("CENTER", 0, 0)
	hint.text = S:Font(hint, 13)
	hint.text:SetPoint("TOP", 0, 0)
	hint.text:SetWidth(520)
	hint.btn = S:Button(hint, "", 180, 24)
	hint.btn:SetPoint("TOP", hint.text, "BOTTOM", 0, -14)
	self.hint = hint

	-- columns
	self.backlog = newColumn(f, L["Backlog"])
	self.cols = {}
	for i, c in ipairs(COLS) do self.cols[i] = newColumn(f, L[c.label]) end

	-- footer
	self.foot = S:Font(f, 10)
	self.foot:SetPoint("BOTTOMLEFT", PAD + 2, 6)
	self.foot:SetTextColor(unpack(S.colors.muted))
	self.foot:SetText(L["Click: select quest and show details · Shift-click: add as GPS stop · Right-click: menu"])

	self:CreateList()
end

---------------------------------------------------------------------------
-- List view (Jira-like table)
---------------------------------------------------------------------------
local LIST_COLS = {
	{ key = "priority", label = "", x = 0, w = 16 },
	{ key = "title", label = "Quest", x = 20, w = 330 },
	{ key = "epic", label = "Epic", x = 356, w = 170 },
	{ key = "status", label = "Status", x = 530, w = 90 },
	{ key = "estimate", label = "Estimate", x = 624, w = 110 },
	{ key = "xp", label = "XP", x = 738, w = 70 },
	{ key = "progress", label = "Progress", x = 812, w = 150 },
}
local GROUPS = { { "epic", "Epic" }, { "zone", "Zone" }, { "status", "Status" }, { "none", "None" } }
local STATUS_COLOR = {
	todo = { 0.60, 0.65, 0.71 }, doing = { 0.41, 0.80, 0.94 }, ready = { 0.30, 0.90, 0.30 },
	done = { 0.45, 0.85, 0.45 }, hold = { 1.00, 0.82, 0.25 },
}
B.STATUS_COLOR = STATUS_COLOR

local function lcfg() return SoA.char.list end

function B:CreateList()
	local L, S = SoA.L, SoA.Style
	local f = self.frame
	local v = CreateFrame("Frame", nil, f)
	v:SetPoint("TOPLEFT", PAD, -(HEAD_H + INFO_H + 4))
	v:SetPoint("BOTTOMRIGHT", -PAD, FOOT_H + 6)
	v:Hide()
	self.listView = v
	v.groupBtn = S:Button(v, "", 130, 20, function(btn)
		local entries = { { text = L["Group by"], header = true } }
		for _, g in ipairs(GROUPS) do
			entries[#entries + 1] = { text = (lcfg().group == g[1] and "> " or "   ") .. L[g[2]], fn = function() lcfg().group = g[1] B:Schedule(true) end }
		end
		showMenu(btn, entries)
	end)
	v.groupBtn:SetPoint("TOPLEFT", 0, 0)
	v.sortBtn = S:Button(v, "", 150, 20, function(btn)
		local entries = { { text = L["Sort by"], header = true } }
		for _, k in ipairs(SoA.Model:SortModes()) do
			entries[#entries + 1] = { text = (lcfg().sort == k and "> " or "   ") .. L[SoA.Model.SORT_LABEL[k]], fn = function() lcfg().sort = k lcfg().desc = false B:Schedule(true) end }
		end
		showMenu(btn, entries)
	end)
	v.sortBtn:SetPoint("LEFT", v.groupBtn, "RIGHT", 6, 0)
	v.stratBtn = S:Button(v, "", 150, 20, function()
		local Br = SoA.Bridge
		local list = Br.RouteStrategies and Br.RouteStrategies()
		if type(list) ~= "table" or #list == 0 then return end
		local cur, idx = Br.GetRouteStrategy(), 1
		for i, k in ipairs(list) do if k == cur then idx = i end end
		Br.SetRouteStrategy(list[idx % #list + 1])
		C_Timer.After(0.5, function() SoA.Model:Dirty() B:Schedule(true) end)
	end)
	v.stratBtn:SetPoint("LEFT", v.sortBtn, "RIGHT", 6, 0)
	v.stratBtn.tip = L["Route strategy of the route planner. Click: next."]
	-- column headers
	local head = CreateFrame("Frame", nil, v)
	head:SetPoint("TOPLEFT", 0, -26)
	head:SetPoint("TOPRIGHT", 0, -26)
	head:SetHeight(18)
	local hb = head:CreateTexture(nil, "BACKGROUND")
	hb:SetAllPoints()
	hb:SetColorTexture(0.08, 0.10, 0.14, 1)
	v.heads = {}
	for _, col in ipairs(LIST_COLS) do
		local b = CreateFrame("Button", nil, head)
		b:SetPoint("LEFT", col.x + 4, 0)
		b:SetSize(col.w, 18)
		b.text = S:Font(b, 11)
		b.text:SetPoint("LEFT", 0, 0)
		b.text:SetTextColor(unpack(S.gold))
		b:SetScript("OnClick", function()
			local c = lcfg()
			if c.sort == col.key then c.desc = not c.desc else c.sort, c.desc = col.key, false end
			B:Schedule(true)
		end)
		b.col = col
		v.heads[#v.heads + 1] = b
	end
	local sc, content = S:ScrollArea(v)
	sc:SetPoint("TOPLEFT", 0, -46)
	sc:SetPoint("BOTTOMRIGHT", 0, 0)
	v.scroll, v.content = sc, content
	v.rows, v.groups = {}, {}
end

local function listRow(v, i)
	local r = v.rows[i]
	if r then return r end
	local S = SoA.Style
	r = CreateFrame("Button", nil, v.content)
	r:SetHeight(18)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.05)
	r.sel = r:CreateTexture(nil, "BACKGROUND")
	r.sel:SetAllPoints()
	r.sel:SetColorTexture(1, 0.82, 0, 0.10)
	r.prio = prioIcon(r)
	r.prio:SetPoint("LEFT", LIST_COLS[1].x + 6, 0)
	r.prio:EnableMouse(false)
	r.icon = r:CreateTexture(nil, "OVERLAY")
	r.icon:SetSize(14, 14)
	r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	r.title = S:Font(r, 11)
	r.title:SetPoint("LEFT", LIST_COLS[2].x + 4, 0)
	r.title:SetJustifyH("LEFT")
	r.title:SetWordWrap(false)
	r.chain = S:ChainIcon(r)
	r.chain:EnableMouse(false)
	r.epic = S:Font(r, 10)
	r.epic:SetPoint("LEFT", LIST_COLS[3].x + 4, 0)
	r.epic:SetWidth(LIST_COLS[3].w - 4)
	r.epic:SetJustifyH("LEFT")
	r.epic:SetWordWrap(false)
	r.status = S:Font(r, 10)
	r.status:SetPoint("LEFT", LIST_COLS[4].x + 4, 0)
	r.status:SetWidth(LIST_COLS[4].w - 4)
	r.status:SetJustifyH("LEFT")
	r.est = S:Font(r, 10)
	r.est:SetPoint("LEFT", LIST_COLS[5].x + 4, 0)
	r.est:SetWidth(LIST_COLS[5].w - 4)
	r.est:SetJustifyH("LEFT")
	r.xp = S:Font(r, 10)
	r.xp:SetPoint("LEFT", LIST_COLS[6].x + 4, 0)
	r.xp:SetTextColor(unpack(S.gold))
	r.bar = S:StatusBar(r, S.colors.accent)
	r.bar:SetPoint("LEFT", LIST_COLS[7].x + 4, 0)
	r.bar:SetSize(LIST_COLS[7].w - 50, 8)
	r.bar:SetMinMaxValues(0, 1)
	r.pct = S:Font(r, 10)
	r.pct:SetPoint("LEFT", r.bar, "RIGHT", 4, 0)
	r:SetScript("OnClick", function(self, button) SoA.guard("list click", B.ClickItem, self.data, button, self) end)
	r:SetScript("OnEnter", function(self) cardTooltip(self) end)
	r:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
	v.rows[i] = r
	return r
end

local function groupRow(v, i)
	local g = v.groups[i]
	if g then return g end
	local S = SoA.Style
	g = CreateFrame("Button", nil, v.content)
	g:SetHeight(20)
	local bg = g:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.04)
	g.text = S:Font(g, 12)
	g.text:SetPoint("LEFT", 4, 0)
	g.info = S:Font(g, 10)
	g.info:SetPoint("LEFT", LIST_COLS[5].x + 4, 0)
	g.info:SetTextColor(unpack(S.colors.muted))
	g.bar = S:StatusBar(g, S.colors.accent)
	g.bar:SetPoint("LEFT", LIST_COLS[7].x + 4, 0)
	g.bar:SetSize(LIST_COLS[7].w - 50, 6)
	g.bar:SetMinMaxValues(0, 1)
	g.pct = S:Font(g, 10)
	g.pct:SetPoint("LEFT", g.bar, "RIGHT", 4, 0)
	g:SetScript("OnClick", function(self)
		local fold = lcfg().fold
		fold[self.key] = not fold[self.key] or nil
		B:Schedule(true)
	end)
	v.groups[i] = g
	return g
end

local zoneNames = {}
local function zoneOf(it)
	if it.kind ~= "quest" then return SoA.L["Tickets"] end
	local m = GetQuestUiMapID and num((try(GetQuestUiMapID, it.id, true)))
	if not m or m <= 0 then return "?" end
	if not zoneNames[m] then
		local info = C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m)
		zoneNames[m] = type(info) == "table" and str(info.name) or "?"
	end
	return zoneNames[m]
end

function B:RenderList(m)
	local L, S, M = SoA.L, SoA.Style, SoA.Model
	local v = self.listView
	local c = lcfg()
	local modes = M:SortModes()
	local valid = c.sort == "title" or c.sort == "progress"
	for _, k in ipairs(modes) do if k == c.sort then valid = true end end
	if not valid then c.sort = "priority" end
	local gname = "None"
	for _, g in ipairs(GROUPS) do if g[1] == c.group then gname = g[2] end end
	v.groupBtn.text:SetText(L["Group: %s"]:format(L[gname]))
	v.sortBtn.text:SetText(L["Sort: %s"]:format(L[M.SORT_LABEL[c.sort] or c.sort]) .. (c.desc and " v" or ""))
	local strat = c.sort == "route" and SoA.Bridge.GetRouteStrategy and SoA.Bridge.GetRouteStrategy()
	v.stratBtn:SetShown(strat and true or false)
	if strat then v.stratBtn.text:SetText(L["Route: %s"]:format(L[SoA.Bridge.STRATEGY_LABEL[strat] or strat])) end
	for _, h in ipairs(v.heads) do
		local col = h.col
		local label = col.label ~= "" and L[col.label] or ""
		if c.sort == col.key then label = label .. (c.desc and " v" or " ^") end
		h.text:SetText(label)
	end
	-- items and groups
	local filter, showLoose = cfg().filter, cfg().showLoose
	local groups, order = {}, {}
	local function group(key, name, color, rank)
		local g = groups[key]
		if not g then
			g = { key = key, name = name, color = color, rank = rank or 50, items = {} }
			groups[key] = g
			order[#order + 1] = g
		end
		return g
	end
	for _, it in ipairs(m.items) do
		if passes(it, filter, showLoose) then
			local g
			if it.onHold then g = group("hold", L["On hold"], S.gold, 98)
			elseif it.epicKey == "loose" and it.kind == "quest" then g = group("loose", L["Loose tasks"], S.colors.muted, 97)
			elseif c.group == "epic" then g = group("e:" .. tostring(it.epicKey), it.epicName or L["Loose tasks"], it.color)
			elseif c.group == "zone" then local z = zoneOf(it) g = group("z:" .. z, z, S.colors.accent, it.zone and 1 or 50)
			elseif c.group == "status" then
				local st = M.Status(it)
				g = group("s:" .. st, L[SoA.Flow.STATUS_LABEL[st] or st], STATUS_COLOR[st], ({ doing = 1, ready = 2, todo = 3 })[st])
			else g = group("all", L["All"], S.colors.accent, 1) end
			g.items[#g.items + 1] = it
		end
	end
	for _, g in ipairs(order) do
		M:Sort(g.items, c.sort, c.desc)
		g.best = g.items[1] and g.items[1].priority or 9
	end
	table.sort(order, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if a.best ~= b.best then return a.best < b.best end
		return (a.name or "") < (b.name or "")
	end)
	-- layout
	local width = math.max(200, (v:GetWidth() or 900) - 8)
	local y, ri, gi = 0, 0, 0
	v.rowTop = {}
	for _, g in ipairs(order) do
		gi = gi + 1
		local gr = groupRow(v, gi)
		gr.key = g.key
		local folded = c.fold[g.key]
		local mins, prog = 0, 0
		for _, it in ipairs(g.items) do mins = mins + (it.minutes or 0) prog = prog + M.Progress(it) end
		local col = g.color or S.colors.muted
		gr.text:SetText((folded and "+ " or "- ") .. (g.name or "?") .. "  |cff999999(" .. #g.items .. ")|r")
		gr.text:SetTextColor(col[1], col[2], col[3])
		gr.info:SetText(S:Minutes(mins))
		local frac = #g.items > 0 and prog / #g.items or 0
		gr.bar:SetValue(frac)
		gr.bar:SetStatusBarColor(col[1], col[2], col[3])
		gr.pct:SetText(("%d%%"):format(frac * 100 + 0.5))
		gr:ClearAllPoints()
		gr:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
		gr:SetWidth(width)
		gr:Show()
		y = y + 22
		if not folded then
			for _, it in ipairs(g.items) do
				ri = ri + 1
				local r = listRow(v, ri)
				r.data, r.item = it, it
				r.icon:Hide()
				r.prio:SetShown(it.kind == "quest" or it.kind == "ticket")
				setPrio(r.prio, it.priority or 3, it.pinned)
				local title = it.title or "?"
				if it.kind == "quest" and it.showLevel then title = "[" .. it.showLevel .. "] " .. title end
				r.title:SetText(title)
				if it.kind == "quest" and it.level then r.title:SetTextColor(SoA.Log:LevelColor(it.level)) else r.title:SetTextColor(1, 1, 1) end
				local tw = LIST_COLS[2].w - 8 - (it.itemTex and 16 or 0) - (it.shared and 18 or 0)
				r.title:SetWidth(tw)
				local tx = LIST_COLS[2].x + 4 + math.min(tw, (r.title:GetStringWidth() or 0)) + 4
				r.chain:SetShown(it.shared ~= nil)
				if it.shared then r.chain:ClearAllPoints() r.chain:SetPoint("LEFT", tx, 0) tx = tx + 18 end
				if it.itemTex then r.icon:SetTexture(it.itemTex) r.icon:ClearAllPoints() r.icon:SetPoint("LEFT", tx, 0) r.icon:Show() end
				local ec = it.color or S.colors.muted
				r.epic:SetText(it.epicName or (it.kind == "ticket" and L["Ticket"]) or L["Loose tasks"])
				r.epic:SetTextColor(ec[1], ec[2], ec[3])
				local st = M.Status(it)
				local stText = L[SoA.Flow.STATUS_LABEL[st] or st]
				if it.blocked then stText = stText .. " |cffff4d4d!|r" end
				r.status:SetText(stText)
				local sc = STATUS_COLOR[st] or S.colors.text
				r.status:SetTextColor(sc[1], sc[2], sc[3])
				r.est:SetText(it.est and SoA.Estimate:Format(it.est) or "")
				r.xp:SetText(it.xp and S:Short(it.xp) or "")
				local p = M.Progress(it)
				r.bar:SetValue(p)
				r.bar:SetStatusBarColor(sc[1], sc[2], sc[3])
				r.pct:SetText(("%d%%"):format(p * 100 + 0.5))
				r.sel:SetShown(SoA.Detail:IsShowing(it.kind == "quest" and it.id or it.key) and true or false)
				r:SetAlpha((it.onHold and not it.resumeReady) and 0.6 or 1)
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
				r:SetWidth(width)
				r:Show()
				v.rowTop[it.key] = y
				if it.kind == "quest" then v.rowTop[it.id] = y end
				y = y + 19
			end
		end
	end
	for i = ri + 1, #v.rows do v.rows[i]:Hide() v.rows[i].data, v.rows[i].item = nil, nil end
	for i = gi + 1, #v.groups do v.groups[i]:Hide() end
	v.content:SetSize(width, math.max(1, y))
	v.scroll:Refresh()
end

-- Scroll the card (or list row) of a ticket into view; the detail border marks it.
function B:Focus(key)
	if not (self.frame and self.frame:IsShown()) then return end
	self:Schedule(true)
	if cfg().mode == "list" then
		local v = self.listView
		local top = v and v.rowTop and v.rowTop[key]
		if top then v.scroll:ShowRange(top, top + 19) end
		return
	end
	local c = self.cardByKey[key]
	if not (c and c.col) then return end
	local sc = c.col.scroll
	local h = sc:GetHeight() or 0
	local cur = sc:GetVerticalScroll() or 0
	if c.top < cur then sc:SetVerticalScroll(c.top)
	elseif c.bottom > cur + h then
		local max = sc:GetVerticalScrollRange() or 0
		sc:SetVerticalScroll(math.min(max, c.bottom - h))
	end
end

function B:FilterMenu(anchor)
	local L = SoA.L
	local m = SoA.Model:Get()
	local entries = {
		{ text = L["All"], fn = function() cfg().filter = "all" B:Schedule(true) end },
		{ text = L["Current zone"], fn = function() cfg().filter = "zone" B:Schedule(true) end },
	}
	if cfg().showLoose then
		entries[#entries + 1] = { text = L["Loose tasks"], fn = function() cfg().filter = "loose" B:Schedule(true) end }
	end
	local list = {}
	for key, e in pairs(m.epics) do list[#list + 1] = e end
	table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
	for _, e in ipairs(list) do
		entries[#entries + 1] = { text = e.name, color = e.color, fn = function() cfg().filter = e.key B:Schedule(true) end }
		if #entries > 24 then break end
	end
	showMenu(anchor, entries)
end

function B:FilterName(m)
	local L = SoA.L
	local f = cfg().filter
	if f == "zone" then return L["Current zone"] end
	if f == "loose" then return L["Loose tasks"] end
	local e = m.epics[f]
	if e then return e.name end
	cfg().filter = "all"
	return L["All"]
end

function passes(it, filter, showLoose)
	if filter == "zone" then return it.zone == true end
	if filter == "loose" then return it.epicKey == "loose" end
	if filter ~= "all" then return it.epicKey == filter or it.storyKey == filter end
	if not showLoose and it.epicKey == "loose" and it.kind ~= "ticket" then return false end
	return true
end

function B:Propose()
	self.proposal = SoA.Sprint:Plan(SoA.Model:Get())
	if #self.proposal.proposed == 0 then
		SoA:Print(SoA.L["Nothing fits the capacity (or the backlog is empty)."])
		self.proposal = nil
	end
	self:Schedule(true)
end

function B:AcceptProposal()
	local p = self.proposal
	self.proposal = nil
	if not p then return end
	local keys = {}
	for _, it in ipairs(p.proposed) do keys[#keys + 1] = it.key end
	SoA.Sprint:AddMany(keys)
	self:NotifyCK()
	self:Schedule(true)
end

-- Tell CasterKit's tracker that priorities or the sprint changed (bridge hook).
function B:NotifyCK()
	if SoA.Hooks and SoA.Hooks.Changed then pcall(SoA.Hooks.Changed) end
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------
function B:Render()
	local f = self.frame
	if not (f and f:IsShown()) then return end
	local L, S, SP = SoA.L, SoA.Style, SoA.Sprint
	local c = cfg()
	local m = SoA.Model:Get()
	wipe(B.cardByKey)
	local scrum = c.mode == "scrum"
	local listMode = c.mode == "list"
	S:SetActive(self.kanbanBtn, c.mode == "kanban")
	S:SetActive(self.scrumBtn, scrum)
	S:SetActive(self.listBtn, listMode)
	if self.listView then self.listView:SetShown(listMode) end
	if listMode then
		self.filterBtn.text:SetText(L["Filter: %s"]:format(self:FilterName(m)))
		self.strip:Hide()
		self.hint:Hide()
		self.backlog:Hide()
		for _, col in ipairs(self.cols) do col:Hide() end
		local info = {}
		local ft = SoA.Review:ForecastText()
		if ft then info[#info + 1] = ft end
		self.info:SetText(table.concat(info, "   ·   "))
		SoA.guard("board list", self.RenderList, self, m)
		return
	end
	self.filterBtn.text:SetText(L["Filter: %s"]:format(self:FilterName(m)))
	local filter, showLoose = c.filter, c.showLoose

	-- forecast line
	local info = {}
	local ft = SoA.Review:ForecastText()
	if ft then info[#info + 1] = ft end
	local st = SP:Status(m)
	if st and st.xpRemaining > 0 then
		local lvl, pct = SoA.Review:LevelAfter(st.xpRemaining)
		if lvl then info[#info + 1] = L["This sprint brings you to level %d (+%d%%)"]:format(lvl, pct) end
	end
	self.info:SetText(table.concat(info, "   ·   "))

	local active = SP:IsActive()
	local top = HEAD_H + INFO_H + 4
	local showStrip = scrum and active and c.sprint
	self.strip:SetShown(showStrip and true or false)
	if showStrip then
		top = top + STRIP_H + GAP
		if not self.goal:HasFocus() then self.goal:SetText(st.goal or "") end
		self.stripText:SetText(L["Committed %s / Delivered %s"]:format(S:Minutes(st.committed), S:Minutes(st.delivered))
			.. "   |cffffd100" .. L["%s / %s XP"]:format(S:Short(st.xpDelivered), S:Short(st.xpCommitted)) .. "|r"
			.. "   |cff999999" .. L["%d/%d done"]:format(st.doneItems, st.items) .. "|r")
		local capText
		if st.capKind == "xp" then
			capText = L["Capacity: %s / %s XP"]:format(S:Short(st.capUsed), S:Short(st.capTotal))
		else
			capText = L["Capacity: %d / %d min"]:format(st.capUsed + 0.5, st.capTotal)
		end
		local over = st.capUsed > st.capTotal
		local p = self.proposal
		if p then
			local mins = 0
			for _, it in ipairs(p.proposed) do mins = mins + (it.minutes or 0) end
			capText = capText .. "   |cff69ccf0" .. L["Proposed: %d items, %s"]:format(#p.proposed, S:Minutes(mins)) .. "|r"
			if p.ratio then capText = capText .. "  |cff999999" .. L["(scaled to %d%%: your usual delivery)"]:format(p.factor * 100 + 0.5) .. "|r" end
			if #p.skipped > 0 then capText = capText .. "  |cffff4d4d" .. L["%d blocked skipped"]:format(#p.skipped) .. "|r" end
		end
		self.capText:SetText(capText)
		self.capText:SetTextColor(over and 1 or 0.91, over and 0.4 or 0.93, over and 0.4 or 0.95)
		self.planBtn:SetShown(not p)
		self.acceptBtn:SetShown(p ~= nil)
		self.cancelBtn:SetShown(p ~= nil)
		drawBurndown(self.chart, st)
	end

	-- Scrum without a sprint: hint and one button
	local needHint = scrum and not active
	self.hint:SetShown(needHint)
	if needHint then
		local ck = SoA.Hooks and SoA.Hooks.LockRoute
		if ck then
			self.hint.text:SetText(L["Scrum uses CasterKit's locked route as the sprint. The route is not locked right now."])
			self.hint.btn.text:SetText(L["Lock the route"])
			self.hint.btn:SetScript("OnClick", function() pcall(ck) B:Schedule(true) end)
		else
			self.hint.text:SetText(L["No sprint yet. A new sprint takes the quests in your log; move items between the sprint and the backlog afterwards."])
			self.hint.btn.text:SetText(L["Start new sprint"])
			self.hint.btn:SetScript("OnClick", function() SP:NewSprint() B:Schedule(true) end)
		end
	end

	-- columns geometry
	local showDone, showHold = c.showDone, c.showHold
	local nCols = 3 + (showDone and 1 or 0) + (showHold and 1 or 0)
	local left = PAD
	local bodyTop = -top - 2
	local bodyBottom = FOOT_H + 6
	local bl = self.backlog
	bl:SetShown(scrum and active)
	local avail = W - PAD * 2
	if scrum and active then
		bl:ClearAllPoints()
		bl:SetPoint("TOPLEFT", f, "TOPLEFT", left, bodyTop)
		bl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", left, bodyBottom)
		bl:SetWidth(BACKLOG_W)
		left = left + BACKLOG_W + GAP
		avail = avail - BACKLOG_W - GAP
	end
	local colW = math.floor((avail - GAP * (nCols - 1)) / nCols)
	for i, col in ipairs(self.cols) do
		local show = (i <= 3 or (i == 4 and showDone) or (i == 5 and showHold)) and not needHint
		col:SetShown(show)
		if show then
			col:ClearAllPoints()
			col:SetPoint("TOPLEFT", f, "TOPLEFT", left, bodyTop)
			col:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", left, bodyBottom)
			col:SetWidth(colW)
			left = left + colW + GAP
		end
	end
	if needHint then bl:Hide() return end

	-- sort and distribute
	local buckets = { todo = {}, doing = {}, ready = {}, done = {}, hold = {} }
	local proposedSet = {}
	if self.proposal then for _, it in ipairs(self.proposal.proposed) do proposedSet[it.key] = true end end
	for _, it in ipairs(m.items) do
		if passes(it, filter, showLoose) then
			local col = it.onHold and "hold" or it.column
			if scrum then
				if it.inSprint then table.insert(buckets[col] or buckets.todo, it) end
			else
				table.insert(buckets[col] or buckets.todo, it)
			end
		end
	end
	if not scrum then
		for _, it in ipairs(m.avail) do if passes(it, filter, showLoose) then table.insert(buckets.todo, it) end end
	end
	local doneList = {}
	for _, it in ipairs(scrum and m.sprintDone or m.done) do doneList[#doneList + 1] = it end
	if not scrum then for _, it in ipairs(m.ticketsDone or {}) do doneList[#doneList + 1] = it end end
	for _, it in ipairs(doneList) do
		if passes(it, filter, showLoose) then table.insert(buckets.done, it) end
	end
	local cmp = SoA.Priority.Compare
	for k, list in pairs(buckets) do
		if k == "done" then
			table.sort(list, function(a, b) return num(a.doneAt, 0) > num(b.doneAt, 0) end)
		else
			table.sort(list, function(a, b)
				if (a.kind == "avail") ~= (b.kind == "avail") then return b.kind == "avail" end
				return cmp(a, b)
			end)
		end
	end
	for i, col in ipairs(self.cols) do
		local key = COLS[i].key
		if col:IsShown() then
			local rows, mins = {}, 0
			for _, it in ipairs(buckets[key]) do mins = mins + (it.minutes or 0) end
			if key == "done" then
				for _, it in ipairs(buckets[key]) do rows[#rows + 1] = { item = it, opts = {} } end
			else
				rows = comboRows(buckets[key], function(it) return { remove = scrum and it.inSprint } end)
			end
			-- without an On hold column: on-hold cards at the bottom of To do
			if key == "todo" and not showHold and #buckets.hold > 0 then
				rows[#rows + 1] = { label = L["On hold"] .. "  (" .. #buckets.hold .. ")", color = S.gold }
				for _, it in ipairs(buckets.hold) do rows[#rows + 1] = { item = it, opts = { remove = scrum and it.inSprint } } end
			end
			col.count:SetText(#rows .. ((key ~= "done" and mins > 0) and ("  ·  " .. S:Minutes(mins)) or ""))
			layout(col, rows)
		end
	end

	-- backlog: three folded groups
	if scrum and active then
		local fold = c.fold
		local rows = {}
		local logItems = {}
		local holdItems = {}
		for _, it in ipairs(m.items) do
			if not it.inSprint and passes(it, filter, showLoose) then
				if it.onHold then holdItems[#holdItems + 1] = it else logItems[#logItems + 1] = it end
			end
		end
		-- epics ordered by their best item, items by priority inside
		local best = {}
		table.sort(logItems, cmp)
		for i, it in ipairs(logItems) do if not best[it.epicKey] then best[it.epicKey] = i end end
		table.sort(logItems, function(a, b)
			if a.epicKey ~= b.epicKey then return best[a.epicKey] < best[b.epicKey] end
			return cmp(a, b)
		end)
		local function group(key, label, list, opts, epicLabels)
			rows[#rows + 1] = { label = (fold[key] and "+ " or "- ") .. label .. "  (" .. #list .. ")", foldKey = key, color = S.gold }
			if fold[key] then return end
			local lastEpic
			for _, it in ipairs(list) do
				if epicLabels and it.epicKey ~= lastEpic then
					lastEpic = it.epicKey
					rows[#rows + 1] = { label = "   " .. (it.epicName or L["Loose tasks"]), color = it.color or S.colors.muted }
				end
				rows[#rows + 1] = { item = it, opts = { add = opts.add, proposed = proposedSet[it.key] } }
			end
		end
		group("log", L["In your log"], logItems, { add = true }, true)
		local av = {}
		for _, it in ipairs(m.avail) do if passes(it, filter, showLoose) then av[#av + 1] = it end end
		group("avail", L["Available"], av, {})
		local up = {}
		for _, it in ipairs(m.upcoming) do if passes(it, filter, showLoose) then up[#up + 1] = it end end
		group("upcoming", L["Upcoming"], up, {})
		if #holdItems > 0 then group("hold", L["On hold"], holdItems, { add = true }) end
		bl.count:SetText(#logItems)
		layout(bl, rows)
	end
end

function B:Schedule(now)
	if not (self.frame and self.frame:IsShown()) then return end
	if now then
		SoA.guard("board render", self.Render, self)
		return
	end
	SoA:Throttle("board-render", 0.25, function() B:Render() end)
end

function SoA:ToggleBoard()
	if not B.frame then B:Create() end
	if B.frame:IsShown() then B.frame:Hide() else B.frame:Show() end
end

function B:OnEnable()
	for _, msg in ipairs({ "MODEL_CHANGED", "SPRINT", "PRIORITY", "SETTINGS" }) do
		SoA:Listen(msg, function() B:Schedule() end)
	end
	-- burndown and forecast move on with time
	C_Timer.NewTicker(10, function()
		if B.frame and B.frame:IsShown() then SoA.Model:Dirty() B:Schedule() end
	end)
end
