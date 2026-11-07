-- Scrum of Azeroth by DinX: compact always-visible quest list, only when no
-- partner tracker (CasterKit's, later Roads of Azeroth's) is shown.
-- The list itself is plain frames (redrawn freely, also in combat). Quest item
-- buttons are SecureActionButtonTemplate buttons on UIParent (type "item",
-- clicked only by you); they are created, moved, shown and hidden only out of
-- combat. In combat they stay where they are and a relayout waits for the end
-- of combat. Blizzard's objective tracker is only hidden when you turn that on,
-- never in combat, with the same taint-safe method CasterKit uses.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local T = SoA:NewModule("Tracker")
local PAD, HEAD_H, ROW_H, OBJ_H, EPIC_H = 6, 34, 15, 13, 15
local ITEM_SIZE, MAX_ITEMS = 26, 10
local MIN_W, MIN_H = 180, 120

local function cfg() return SoA.char.tracker2 end

function T:ShouldShow()
	if not (SoA.char and cfg().enabled) then return false end
	local B = SoA.Bridge
	return not (B and B.PartnerTracker and B.PartnerTracker())
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function savePoint(f)
	local left, top = f:GetLeft(), f:GetTop()
	if left and top then
		cfg().point = { math.floor(left + 0.5), math.floor(top + 0.5), f:GetScale() }
	end
end

local function applyPoint(f)
	local p = cfg().point
	f:ClearAllPoints()
	if type(p) == "table" and num(p[1]) and num(p[2]) then
		-- keep the screen position when the scale changed since it was saved
		local k = num(p[3], f:GetScale()) / f:GetScale()
		f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p[1] * k, p[2] * k)
	else
		local s = f:GetScale()
		f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (UIParent:GetWidth() - 300) / s, (UIParent:GetHeight() - 260) / s)
	end
end

function T:Create()
	local L, S = SoA.L, SoA.Style
	local f = CreateFrame("Frame", "ScrumOfAzerothTracker", UIParent, "BackdropTemplate")
	f:SetFrameStrata("MEDIUM")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:SetResizable(true)
	S:Backdrop(f, 0.6)
	f:Hide()
	self.frame = f
	local maxW, maxH = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
	if f.SetResizeBounds then f:SetResizeBounds(MIN_W, MIN_H, maxW, maxH)
	elseif f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) f:SetMaxResize(maxW, maxH) end

	local head = CreateFrame("Frame", nil, f)
	head:SetPoint("TOPLEFT", 0, 0)
	head:SetPoint("TOPRIGHT", 0, 0)
	head:SetHeight(HEAD_H)
	head:EnableMouse(true)
	head:RegisterForDrag("LeftButton")
	head:SetScript("OnDragStart", function() if not cfg().locked then f:StartMoving() end end)
	head:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		savePoint(f)
		applyPoint(f)
		T:QueueItems()
	end)
	f.title = S:Font(head, 12)
	f.title:SetPoint("TOPLEFT", PAD, -5)
	f.title:SetTextColor(unpack(S.gold))
	f.title:SetText(L["Quests"])
	f.sortBtn = CreateFrame("Button", nil, head)
	f.sortBtn.text = S:Font(f.sortBtn, 10)
	f.sortBtn.text:SetPoint("LEFT")
	f.sortBtn.text:SetTextColor(unpack(S.colors.accent))
	f.sortBtn:SetPoint("LEFT", f.title, "RIGHT", 4, 0)
	f.sortBtn:SetScript("OnClick", function(btn) T:SortMenu(btn) end)
	f.stratBtn = CreateFrame("Button", nil, head)
	f.stratBtn.text = S:Font(f.stratBtn, 10)
	f.stratBtn.text:SetPoint("LEFT")
	f.stratBtn.text:SetTextColor(unpack(S.colors.accent))
	f.stratBtn:SetPoint("LEFT", f.sortBtn, "RIGHT", 2, 0)
	f.stratBtn:SetScript("OnClick", function()
		local Br = SoA.Bridge
		local list = Br.RouteStrategies and Br.RouteStrategies()
		if type(list) ~= "table" or #list == 0 then return end
		local cur, idx = Br.GetRouteStrategy(), 1
		for i, k in ipairs(list) do if k == cur then idx = i end end
		Br.SetRouteStrategy(list[idx % #list + 1])
		C_Timer.After(0.5, function() SoA.Model:Dirty() T:Schedule() end)
	end)
	f.fold = S:Button(head, "-", 18, 16, function()
		cfg().folded = not cfg().folded
		T:Render()
	end)
	f.fold:SetPoint("TOPRIGHT", -PAD, -3)
	f.board = S:Button(head, L["Board"], 44, 16, function() SoA:ToggleBoard() end)
	S:ApplyFont(f.board.text, 10)
	f.board:SetPoint("RIGHT", f.fold, "LEFT", -3, 0)
	f.sprint = S:Font(head, 10)
	f.sprint:SetPoint("TOPLEFT", PAD, -20)
	f.sprint:SetPoint("RIGHT", -PAD, 0)
	f.sprint:SetJustifyH("LEFT")
	f.sprint:SetWordWrap(false)
	f.sprint:SetTextColor(unpack(S.colors.muted))

	local sc, content = S:ScrollArea(f)
	sc:SetPoint("TOPLEFT", PAD, -HEAD_H)
	sc:SetPoint("BOTTOMRIGHT", -3, PAD)
	sc:HookScript("OnMouseWheel", function() T:QueueItems() end)
	f.scroll, f.content = sc, content
	f.titles, f.objs, f.epics = {}, {}, {}

	-- resize grip
	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(12, 12)
	grip:SetPoint("BOTTOMRIGHT", -1, 1)
	for i = 0, 2 do
		local t = grip:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(S.colors.muted[1], S.colors.muted[2], S.colors.muted[3], 0.8)
		t:SetSize(2 + i * 4, 1)
		t:SetPoint("BOTTOMRIGHT", -1, 2 + i * 3)
	end
	grip:SetScript("OnMouseDown", function()
		if cfg().locked then return end
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
		applyPoint(f)
		T:Render()
	end)
	f.grip = grip
	f:SetScript("OnSizeChanged", function()
		if f.sizing then SoA:Throttle("tracker-reflow", 0.1, function() T:Render(true) end) end
	end)
	self:ApplyLayout()
end

function T:ApplyLayout()
	local f = self.frame
	if not f then return end
	local c = cfg()
	f:SetScale(math.max(0.6, math.min(1.5, num(c.scale, 1))))
	f:SetWidth(math.max(MIN_W, num(c.width, 250)))
	applyPoint(f)
	f.grip:SetShown(not c.locked)
end

---------------------------------------------------------------------------
-- Rows (insecure, pooled)
---------------------------------------------------------------------------
local function titleRow(f, i)
	local r = f.titles[i]
	if r then return r end
	local S = SoA.Style
	local B = SoA.Board
	r = CreateFrame("Button", nil, f.content)
	r:SetHeight(ROW_H)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)
	r.prio = B.PrioIcon(r)
	r.prio:SetPoint("LEFT", 0, 0)
	r.prio:EnableMouse(false)
	r.dot = r:CreateTexture(nil, "ARTWORK")
	r.dot:SetSize(5, 5)
	r.dot:SetPoint("LEFT", 14, 0)
	r.dot:SetColorTexture(1, 1, 1, 1)
	r.right = S:Font(r, 10)
	r.right:SetPoint("RIGHT", 0, 0)
	r.right:SetTextColor(unpack(S.colors.muted))
	r.chain = S:ChainIcon(r)
	r.chain:EnableMouse(false)
	r.chain:SetPoint("RIGHT", r.right, "LEFT", -3, 0)
	r.text = S:Font(r, 11)
	r.text:SetPoint("LEFT", 22, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	r:SetScript("OnClick", function(self, button)
		SoA.guard("tracker click", B.ClickItem, self.item, button, T.frame, true)
	end)
	r:SetScript("OnEnter", function(self)
		local it = self.item
		if not it then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(it.title or "?", 1, 1, 1, 1, true)
		local L = SoA.L
		if it.epicName then local c = it.color or SoA.Style.colors.muted GameTooltip:AddLine(it.epicName, c[1], c[2], c[3]) end
		if it.est then GameTooltip:AddDoubleLine(L["Estimate"], SoA.Estimate:Format(it.est), 0.6, 0.65, 0.71, 1, 1, 1) end
		for _, rs in ipairs(it.blockReasons or {}) do GameTooltip:AddLine(L["Blocked"] .. ": " .. rs, 1, 0.3, 0.3, true) end
		if it.onHold then GameTooltip:AddLine(L["On hold"] .. ": " .. (it.holdText or ""), 1, 0.82, 0, true) end
		if it.shared and it.shared.note then GameTooltip:AddLine(it.shared.note, 0.41, 0.8, 0.94, true) end
		GameTooltip:AddLine(L["Click: select and show details · Shift-click: GPS stop · Right-click: menu"], 0.6, 0.65, 0.71, true)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
	f.titles[i] = r
	return r
end

local function objRow(f, i)
	local r = f.objs[i]
	if r then return r end
	local S = SoA.Style
	r = CreateFrame("Frame", nil, f.content)
	r.text = S:Font(r, 10)
	r.text:SetPoint("TOPLEFT", 0, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(true)
	r.bar = S:StatusBar(r, S.colors.accent)
	r.bar:SetHeight(3)
	r.bar:SetMinMaxValues(0, 1)
	f.objs[i] = r
	return r
end

local function epicRow(f, i)
	local r = f.epics[i]
	if r then return r end
	local S = SoA.Style
	r = CreateFrame("Button", nil, f.content)
	r:SetHeight(EPIC_H)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	r.text = S:Font(r, 11)
	r.text:SetPoint("LEFT", 0, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	r.count = S:Font(r, 10)
	r.count:SetPoint("RIGHT", 0, 0)
	r.count:SetTextColor(unpack(S.colors.muted))
	r:SetScript("OnClick", function(self, button)
		if button == "RightButton" or not self.epicKey or self.epicKey == "loose" then
			local col = cfg().collapsed
			col[self.key] = not col[self.key] or nil
			T:Render()
		else
			SoA.Detail:OpenEpic(self.epicKey, { window = not (SoA.Board.frame and SoA.Board.frame:IsShown()), anchor = T.frame })
		end
	end)
	r:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		local e = self.epicKey and (SoA.Epics:ByKey(self.epicKey) or (SoA.Stories and SoA.Stories:ByKey(self.epicKey)))
		if e and e.story then SoA.Stories:Tooltip(GameTooltip, e) elseif e then SoA.Epics:Tooltip(GameTooltip, e) else GameTooltip:SetText(self.name or "?") end
		GameTooltip:AddLine(SoA.L["Click: epic details · Right-click: fold"], 0.6, 0.65, 0.71, true)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
	f.epics[i] = r
	return r
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------
function T:Mode()
	local c = cfg().content
	if c == "auto" then
		return (SoA.char.board.mode == "scrum" and SoA.Sprint:IsActive()) and "sprint" or "doing"
	end
	return c
end

function T:Items(m)
	local mode = self:Mode()
	local out = {}
	for _, it in ipairs(m.items) do
		if it.kind == "quest" or it.kind == "ticket" then
			local ok
			if mode == "sprint" then ok = it.inSprint
			elseif mode == "doing" then ok = (it.column == "doing" or it.column == "ready") and not it.onHold
			else ok = true end
			if ok then out[#out + 1] = it end
		end
	end
	local sort = cfg().sort
	local valid = false
	for _, k in ipairs(SoA.Model:SortModes()) do if k == sort then valid = true end end
	if not valid then sort = "priority" end
	SoA.Model:Sort(out, sort)
	return out, sort
end

function T:SortMenu(anchor)
	local L, M = SoA.L, SoA.Model
	local entries = { { text = L["Sort by"], header = true } }
	for _, k in ipairs(M:SortModes()) do
		entries[#entries + 1] = { text = (cfg().sort == k and "> " or "   ") .. L[M.SORT_LABEL[k]], fn = function() cfg().sort = k T:Render() end }
	end
	SoA.Board.ShowMenu(anchor, entries)
end

local STATUS_COLOR = {
	todo = { 0.60, 0.65, 0.71 }, doing = { 0.41, 0.80, 0.94 }, ready = { 0.30, 0.90, 0.30 }, hold = { 1.00, 0.82, 0.25 }, done = { 0.45, 0.85, 0.45 },
}

T.visible = {} -- rows with a quest item: { logIndex, link, tex, charges, title, y, h }

function T:Render(fromResize)
	local f = self.frame
	if not f then return end
	if not self:ShouldShow() then
		f:Hide()
		self:QueueItems()
		return
	end
	local L, S, M = SoA.L, SoA.Style, SoA.Model
	local c = cfg()
	local m = M:Get()
	local list, sort = self:Items(m)
	-- header
	f.sortBtn.text:SetText("· " .. L[M.SORT_LABEL[sort] or sort])
	f.sortBtn:SetSize((f.sortBtn.text:GetStringWidth() or 40) + 4, 14)
	local strat = sort == "route" and SoA.Bridge.GetRouteStrategy and SoA.Bridge.GetRouteStrategy()
	f.stratBtn:SetShown(strat and true or false)
	if strat then
		f.stratBtn.text:SetText("· " .. L[SoA.Bridge.STRATEGY_LABEL[strat] or strat])
		f.stratBtn:SetSize((f.stratBtn.text:GetStringWidth() or 40) + 4, 14)
	end
	f.fold.text:SetText(c.folded and "+" or "-")
	local st = SoA.Sprint:IsActive() and SoA.Sprint:Status(m)
	if st and st.items > 0 then
		f.sprint:SetText(L["Sprint %d/%d · %d/%d min"]:format(st.doneItems, st.items, st.delivered + 0.5, st.committed + 0.5))
	else
		f.sprint:SetText(L["%d quests · %s"]:format(#list, L[({ sprint = "Sprint", doing = "In progress + Ready", all = "All tracked" })[self:Mode()] or ""]))
	end
	if not fromResize then f:SetWidth(math.max(MIN_W, num(c.width, 250))) end
	local width = (f:GetWidth() or 250) - PAD - 3 - 8
	local y, ti, oi, ei = 0, 0, 0, 0
	wipe(self.visible)
	if not c.folded then
		-- epic groups like CasterKit's tracker (setting shared with it)
		local groups, order = {}, {}
		local grouping = SoA.char.tracker.groupEpics
		for i, it in ipairs(list) do
			if i > num(c.maxRows, 12) then break end
			local key = grouping and (it.epicKey or "loose") or "all"
			local g = groups[key]
			if not g then
				g = { key = key, name = it.epicName or (it.kind == "ticket" and L["Ticket"]) or L["Loose tasks"], color = it.color, items = {}, epicKey = it.epicKey }
				groups[key] = g
				order[#order + 1] = g
			end
			g.items[#g.items + 1] = it
		end
		for _, g in ipairs(order) do
			local folded = false
			local indent = 0
			if grouping and #order > 1 or (grouping and g.key ~= "loose") then
				ei = ei + 1
				local r = epicRow(f, ei)
				r.key, r.epicKey, r.name = "tr:" .. tostring(g.key), g.epicKey, g.name
				folded = c.collapsed[r.key] and true or false
				local col = g.color or S.colors.muted
				r.text:SetText((folded and "+ " or "") .. g.name)
				r.text:SetTextColor(col[1], col[2], col[3])
				r.text:SetWidth(width - 30)
				local e = m.epics[g.key] and (SoA.Epics:ByKey(g.key) or (SoA.Stories and SoA.Stories:ByKey(g.key)))
				r.count:SetText(e and e.total and e.total > 0 and (e.done .. "/" .. e.total) or #g.items)
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -y)
				r:SetWidth(width)
				r:Show()
				y = y + EPIC_H + 2
				indent = 6
			end
			if not folded then
				for _, it in ipairs(g.items) do
					ti = ti + 1
					local r = titleRow(f, ti)
					r.item = it
					r.prio:SetShown(true)
					SoA.Board.SetPrio(r.prio, it.priority or 3, it.pinned)
					local stc = STATUS_COLOR[M.Status(it)] or S.colors.text
					r.dot:SetVertexColor(stc[1], stc[2], stc[3])
					local right
					if it.onHold then right = "|cffffd100" .. L["On hold"] .. "|r"
					elseif it.blocked then right = "|cffff4d4d" .. L["Blocked"] .. "|r"
					elseif it.ready then right = "|cff4ce64c" .. L["Ready"] .. "|r"
					elseif it.minutes then right = S:Minutes(it.minutes) end
					r.right:SetText(right or "")
					r.chain:SetShown(it.shared ~= nil)
					local title = it.title or "?"
					if it.kind == "quest" and it.showLevel then title = "[" .. it.showLevel .. "] " .. title end
					r.text:SetText(title)
					if it.kind == "quest" and it.level then r.text:SetTextColor(SoA.Log:LevelColor(it.level)) else r.text:SetTextColor(1, 1, 1) end
					local rw = (r.right:GetStringWidth() or 0) + (it.shared and 18 or 0) + 6
					r.text:SetWidth(math.max(40, width - indent - 22 - rw))
					r:ClearAllPoints()
					r:SetPoint("TOPLEFT", f.content, "TOPLEFT", indent, -y)
					r:SetWidth(width - indent)
					r:SetAlpha((it.onHold and not it.resumeReady) and 0.6 or 1)
					r:Show()
					if it.kind == "quest" and it.itemLink and it.itemTex and it.index then
						self.visible[#self.visible + 1] = { logIndex = it.index, link = it.itemLink, tex = it.itemTex, title = it.title, y = y }
					end
					y = y + ROW_H
					if not it.ready then
						for _, o in ipairs(it.objectives or {}) do
							if o.text and o.text ~= "" and not o.done then
								oi = oi + 1
								local orow = objRow(f, oi)
								orow.text:SetWidth(width - indent - 24)
								orow.text:SetText(o.text)
								local h = math.max(OBJ_H - 2, orow.text:GetStringHeight() or 10)
								local frac
								if o.pct then frac = o.pct / 100 elseif o.need and o.need > 1 then frac = (o.have or 0) / o.need end
								orow.bar:SetShown(frac ~= nil)
								if frac then
									orow.bar:ClearAllPoints()
									orow.bar:SetPoint("TOPLEFT", orow.text, "BOTTOMLEFT", 0, -1)
									orow.bar:SetWidth(width - indent - 24)
									orow.bar:SetValue(frac)
									h = h + 5
								end
								orow:ClearAllPoints()
								orow:SetPoint("TOPLEFT", f.content, "TOPLEFT", indent + 22, -y)
								orow:SetSize(width - indent - 24, h)
								orow:Show()
								y = y + h + 1
							end
						end
					end
					y = y + 3
				end
			end
		end
	end
	for i = ti + 1, #f.titles do f.titles[i]:Hide() f.titles[i].item = nil end
	for i = oi + 1, #f.objs do f.objs[i]:Hide() end
	for i = ei + 1, #f.epics do f.epics[i]:Hide() end
	f.content:SetSize(width, math.max(1, y))
	-- grows downward up to the saved height, then scrolls
	if not f.sizing then
		local want = HEAD_H + (c.folded and 0 or (y + PAD + 4))
		f:SetHeight(math.max(c.folded and HEAD_H or MIN_H * 0.5, math.min(num(c.height, 320), want)))
	end
	f.scroll:SetShown(not c.folded)
	f:Show()
	f.scroll:Refresh()
	self:QueueItems()
	self:ApplyHiding()
end

function T:Schedule()
	SoA:Throttle("tracker-render", 0.3, function() T:Render() end)
end

---------------------------------------------------------------------------
-- Quest item buttons (secure; out of combat only)
---------------------------------------------------------------------------
local buttons = {}

local function itemButton(i)
	local b = buttons[i]
	if b then return b end
	local S = SoA.Style
	b = CreateFrame("Button", "ScrumOfAzerothQuestItem" .. i, UIParent, "SecureActionButtonTemplate,BackdropTemplate")
	b:SetSize(ITEM_SIZE, ITEM_SIZE)
	b:SetFrameStrata("MEDIUM")
	b:RegisterForClicks("AnyUp", "AnyDown")
	b:SetAttribute("type", "item")
	S:Backdrop(b, 1)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 1, -1)
	b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cd:SetAllPoints(b.icon)
	b.count = S:Font(b, 10)
	b.count:SetPoint("BOTTOMRIGHT", -2, 2)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b.icon)
	hl:SetColorTexture(1, 1, 1, 0.15)
	b:SetScript("OnEnter", function(self)
		if not self.link then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		pcall(GameTooltip.SetHyperlink, GameTooltip, self.link)
		if self.questTitle then GameTooltip:AddLine(self.questTitle, 1, 0.82, 0) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
	b:Hide()
	buttons[i] = b
	return b
end

local function updateCooldowns()
	if not GetQuestLogSpecialItemCooldown then return end
	for _, b in ipairs(buttons) do
		if b:IsShown() and b.logIndex then
			local start, dur, enable = try(GetQuestLogSpecialItemCooldown, b.logIndex)
			start, dur = num(start), num(dur)
			if start and dur and dur > 0 and num(enable, 1) ~= 0 then b.cd:SetCooldown(start, dur) else b.cd:Clear() end
		end
	end
end

local function layoutItems()
	local f = T.frame
	local show = f and f:IsShown() and not cfg().folded
	local list = show and T.visible or {}
	local fs = f and f:GetEffectiveScale() / UIParent:GetEffectiveScale() or 1
	local left, top = f and f:GetLeft(), f and f:GetTop()
	local right = f and f:GetRight()
	local scroll = f and (f.scroll:GetVerticalScroll() or 0) or 0
	local viewH = f and (f.scroll:GetHeight() or 0) or 0
	local n = 0
	for _, v in ipairs(list) do
		local rowY = v.y - scroll
		if n < MAX_ITEMS and left and top and rowY >= -2 and rowY + ROW_H <= viewH + 2 then
			n = n + 1
			local b = itemButton(n)
			b:SetAttribute("item", v.link)
			b.link, b.questTitle, b.logIndex = v.link, v.title, v.logIndex
			b.icon:SetTexture(v.tex)
			local _, _, charges = try(GetQuestLogSpecialItemInfo, v.logIndex)
			charges = num(charges, 0)
			b.count:SetText(charges > 1 and charges or "")
			local y = (top - HEAD_H - rowY) * fs
			b:ClearAllPoints()
			if left * fs > ITEM_SIZE + 8 then
				b:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left * fs - 3, y + 6)
			else
				b:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right * fs + 3, y + 6)
			end
			b:Show()
		end
	end
	for i = n + 1, #buttons do
		buttons[i]:Hide()
		buttons[i]:SetAttribute("item", nil)
		buttons[i].link, buttons[i].logIndex = nil, nil
	end
	updateCooldowns()
end

-- Secure changes wait for the end of combat.
function T:QueueItems()
	SoA:OutOfCombat("tracker-items", function() SoA.guard("tracker items", layoutItems) end)
end

---------------------------------------------------------------------------
-- Blizzard's objective tracker (optional, standalone only)
---------------------------------------------------------------------------
local hooked = {}
local hidBlizzard, toldReload = false, false
local BLIZZARD = { "ObjectiveTrackerFrame", "QuestWatchFrame", "WatchFrame" }

function T:ApplyHiding()
	local want = cfg().hideBlizzard and self:ShouldShow()
	if hidBlizzard and not want then
		if not toldReload then
			toldReload = true
			SoA:Print(SoA.L["Type /reload to bring back Blizzard's quest tracker."])
		end
		return
	end
	if not want then return end
	SoA:OutOfCombat("tracker-hide", function()
		for _, name in ipairs(BLIZZARD) do
			local fr = _G[name]
			if fr and fr.Hide then
				if not hooked[fr] then
					hooked[fr] = true
					fr:HookScript("OnShow", function(self)
						if cfg().hideBlizzard and T:ShouldShow() then
							SoA:OutOfCombat("tracker-hide-" .. name, function() SoA.HideBlizzardFrame(self) end)
						end
					end)
				end
				SoA.HideBlizzardFrame(fr)
				hidBlizzard = true
			end
		end
	end)
end

function T:Refresh()
	if not self.frame then self:Create() end
	self:ApplyLayout()
	self:Render()
end

function T:OnEnable()
	self:Create()
	for _, msg in ipairs({ "MODEL_CHANGED", "SPRINT", "PRIORITY", "SETTINGS", "PARTNERS" }) do
		SoA:Listen(msg, function() T:Schedule() end)
	end
	SoA:Listen("SETTINGS", function() T:ApplyLayout() end)
	SoA:On("BAG_UPDATE_COOLDOWN", function() SoA.guard("tracker cd", updateCooldowns) end)
	SoA:On("QUEST_LOG_UPDATE", function() T:Schedule() end)
	C_Timer.After(2, function() T:Render() end)
end
