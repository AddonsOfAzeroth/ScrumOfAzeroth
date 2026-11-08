-- Scrum of Azeroth by DinX: ticket details (Jira issue view). Docked at the
-- right of the board, or a separate movable window. Tabs: Overview, Stats,
-- History. Epics get the same panel with totals and time per quest.
-- Plain frames only (safe in combat). Rewards are display only: choosing a
-- reward stays in Blizzard's turn-in window. The quest log selection is only
-- borrowed out of combat to read the quest text, then restored.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local D = SoA:NewModule("Detail")
local W, H_WINDOW = 390, 540
local TOP_H = 30
local PARCHMENT = { 0.93, 0.87, 0.73 }
local TEXT_TTL = 60

local SIGNAL = {
	objective = { color = { 0.30, 0.90, 0.30 }, label = "Objective progress right after the fight" },
	target = { color = { 1.00, 0.82, 0.00 }, label = "The target's name matched this quest" },
	focus = { color = { 0.41, 0.80, 0.94 }, label = "The quest you follow, nearby" },
	none = { color = { 0.60, 0.65, 0.71 }, label = "No signal: unassigned" },
	manual = { color = { 0.85, 0.45, 1.00 }, label = "Corrected by you" },
}
D.SIGNAL = SIGNAL

---------------------------------------------------------------------------
-- Canvas: pooled widgets laid out top to bottom in a scroll area
---------------------------------------------------------------------------
local Canvas = {}
Canvas.__index = Canvas

local function newCanvas(parent)
	local S = SoA.Style
	local sc, content = S:ScrollArea(parent)
	sc:SetPoint("TOPLEFT", 0, 0)
	sc:SetPoint("BOTTOMRIGHT", 0, 0)
	return setmetatable({ sc = sc, content = content, pools = {}, used = {} }, Canvas)
end

function Canvas:Begin(width)
	self.w, self.y = width, 0
	for k in pairs(self.pools) do self.used[k] = 0 end
end

function Canvas:take(kind, make)
	self.pools[kind] = self.pools[kind] or {}
	local n = (self.used[kind] or 0) + 1
	self.used[kind] = n
	local o = self.pools[kind][n]
	if not o then o = make() self.pools[kind][n] = o end
	o:ClearAllPoints()
	o:Show()
	return o
end

function Canvas:End()
	for k, list in pairs(self.pools) do
		for i = (self.used[k] or 0) + 1, #list do list[i]:Hide() end
	end
	self.content:SetSize(self.w, math.max(1, self.y + 6))
	self.sc:Refresh()
end

function Canvas:Gap(h) self.y = self.y + (h or 6) end

-- opts: size, color, indent, plain (no outline), right
function Canvas:Text(text, opts)
	opts = opts or {}
	local S = SoA.Style
	local fs = self:take("fs", function() return self.content:CreateFontString(nil, "OVERLAY") end)
	S:ApplyFont(fs, opts.size or 11, opts.plain and "" or nil)
	local c = opts.color or S.colors.text
	fs:SetTextColor(c[1], c[2], c[3])
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(true)
	local x = opts.indent or 0
	fs:SetWidth(self.w - x)
	fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -self.y)
	fs:SetText(text or "")
	self.y = self.y + math.max(opts.size or 11, fs:GetStringHeight() or 0) + (opts.gap or 3)
	return fs
end

function Canvas:Header(text)
	self:Gap(6)
	local fs = self:Text(text, { size = 12, color = SoA.Style.gold })
	local line = self:take("line", function()
		local t = self.content:CreateTexture(nil, "ARTWORK")
		t:SetColorTexture(1, 1, 1, 0.08)
		return t
	end)
	line:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -self.y + 1)
	line:SetSize(self.w, 1)
	self.y = self.y + 3
	return fs
end

function Canvas:Pair(label, value, color)
	local S = SoA.Style
	local l = self:take("fs", function() return self.content:CreateFontString(nil, "OVERLAY") end)
	S:ApplyFont(l, 11)
	l:SetTextColor(unpack(S.colors.muted))
	l:SetJustifyH("LEFT")
	l:SetWidth(150)
	l:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -self.y)
	l:SetText(label)
	local v = self:take("fs", function() return self.content:CreateFontString(nil, "OVERLAY") end)
	S:ApplyFont(v, 11)
	local c = color or S.colors.text
	v:SetTextColor(c[1], c[2], c[3])
	v:SetJustifyH("LEFT")
	v:SetWordWrap(true)
	v:SetWidth(self.w - 154)
	v:SetPoint("TOPLEFT", self.content, "TOPLEFT", 154, -self.y)
	v:SetText(value or "-")
	self.y = self.y + math.max(13, v:GetStringHeight() or 0) + 2
end

function Canvas:Bar(frac, color, label, indent)
	local S = SoA.Style
	local b = self:take("bar", function()
		local bar = S:StatusBar(self.content)
		bar.text = S:Font(bar, 9)
		bar.text:SetPoint("CENTER")
		return bar
	end)
	local x = indent or 0
	b:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -self.y)
	b:SetSize(self.w - x, 10)
	b:SetMinMaxValues(0, 1)
	b:SetValue(math.max(0, math.min(1, frac or 0)))
	local c = color or S.colors.accent
	b:SetStatusBarColor(c[1], c[2], c[3])
	b.text:SetText(label or "")
	self.y = self.y + 13
	return b
end

-- Flowing row of buttons: { { label, fn, tip }, ... }
function Canvas:Buttons(list)
	local S = SoA.Style
	local x = 0
	for _, d in ipairs(list) do
		local b = self:take("btn", function()
			local btn = S:Button(self.content, "", 80, 18)
			S:ApplyFont(btn.text, 10)
			btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			return btn
		end)
		b.text:SetText(d[1])
		local w = math.max(50, (b.text:GetStringWidth() or 40) + 14)
		if x > 0 and x + w > self.w then x, self.y = 0, self.y + 21 end
		b:SetSize(w, 18)
		b:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -self.y)
		b.tip = d[3]
		b:SetScript("OnClick", function(btn) SoA.guard("detail button", d[2], btn) end)
		x = x + w + 4
	end
	self.y = self.y + 22
end

-- Clickable row: { color, text, right, tip = function(tt), click = function(button, row), indent }
function Canvas:Row(o)
	local S = SoA.Style
	local r = self:take("row", function()
		local row = CreateFrame("Button", nil, self.content)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row.sq = row:CreateTexture(nil, "ARTWORK")
		row.sq:SetSize(7, 7)
		row.sq:SetPoint("LEFT", 2, 0)
		row.sq:SetColorTexture(1, 1, 1, 1)
		row.right = S:Font(row, 10)
		row.right:SetPoint("RIGHT", -2, 0)
		row.right:SetTextColor(unpack(S.colors.muted))
		row.text = S:Font(row, 11)
		row.text:SetPoint("LEFT", 14, 0)
		row.text:SetPoint("RIGHT", row.right, "LEFT", -4, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.06)
		row:SetScript("OnEnter", function(btn)
			if btn.tipFn then
				GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
				SoA.guard("detail tip", btn.tipFn, GameTooltip)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function(btn) if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end end)
		row:SetScript("OnClick", function(btn, button) if btn.clickFn then SoA.guard("detail row", btn.clickFn, button, btn) end end)
		return row
	end)
	local x = o.indent or 0
	r:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -self.y)
	r:SetSize(self.w - x, 16)
	local c = o.color or S.colors.muted
	r.sq:SetVertexColor(c[1], c[2], c[3])
	r.sq:SetShown(o.color ~= false)
	r.text:SetText(o.text or "")
	local tc = o.textColor or S.colors.text
	r.text:SetTextColor(tc[1], tc[2], tc[3])
	r.right:SetText(o.right or "")
	r.tipFn, r.clickFn = o.tip, o.click
	self.y = self.y + 17
	return r
end

-- Reward icons: { { tex, count, quality, link, label, upgrade, tipFn } }
function Canvas:Icons(list)
	local S = SoA.Style
	local x = 0
	for _, d in ipairs(list) do
		local b = self:take("icon", function()
			local btn = CreateFrame("Button", nil, self.content, "BackdropTemplate")
			btn:SetSize(32, 32)
			S:Backdrop(btn, 1)
			btn.icon = btn:CreateTexture(nil, "ARTWORK")
			btn.icon:SetPoint("TOPLEFT", 2, -2)
			btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
			btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			btn.count = S:Font(btn, 10)
			btn.count:SetPoint("BOTTOMRIGHT", -2, 2)
			-- left-aligned under the icon: centred it stuck out past the left edge and was clipped
			btn.up = S:Font(btn, 8)
			btn.up:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -1)
			btn.up:SetWidth(35)
			btn.up:SetJustifyH("LEFT")
			btn.up:SetWordWrap(false)
			btn.up:SetTextColor(0.3, 0.9, 0.3)
			btn:SetScript("OnEnter", function(self2)
				GameTooltip:SetOwner(self2, "ANCHOR_RIGHT")
				SoA.guard("reward tip", function()
					if self2.tipFn then self2.tipFn(GameTooltip)
					elseif self2.link then GameTooltip:SetHyperlink(self2.link) end
					if IsShiftKeyDown() and self2.link and GameTooltip_ShowCompareItem then pcall(GameTooltip_ShowCompareItem, GameTooltip) end
				end)
				GameTooltip:Show()
			end)
			btn:SetScript("OnLeave", function(self2) if GameTooltip:IsOwned(self2) then GameTooltip:Hide() end end)
			return btn
		end)
		if x > 0 and x + 36 > self.w then x, self.y = 0, self.y + 46 end
		b:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, -self.y)
		b.icon:SetTexture(d.tex)
		b.count:SetText((d.count and d.count > 1) and d.count or "")
		local r, g, bl = S:Quality(d.quality)
		b:SetBackdropBorderColor(r, g, bl, 1)
		b.up:SetText(d.upgrade and SoA.L["Upgrade"] or "")
		b.link, b.tipFn = d.link, d.tipFn
		x = x + 36
	end
	if #list > 0 then self.y = self.y + 46 end
end

-- Mini bar chart (sparkline) of values.
function Canvas:Spark(values, color)
	local holder = self:take("spark", function()
		local f = CreateFrame("Frame", nil, self.content)
		f.bars = {}
		f.avg = f:CreateTexture(nil, "OVERLAY")
		f.avg:SetColorTexture(1, 1, 1, 0.5)
		return f
	end)
	holder:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -self.y)
	holder:SetSize(self.w, 26)
	local n = math.min(#values, 40)
	local maxV, sum = 1, 0
	for i = #values - n + 1, #values do maxV = math.max(maxV, values[i]) sum = sum + values[i] end
	local bw = n > 0 and math.max(2, math.floor(self.w / math.max(n, 10)) - 1) or 2
	local c = color or SoA.Style.colors.accent
	for i = 1, math.max(n, #holder.bars) do
		local t = holder.bars[i]
		if i <= n then
			if not t then
				t = holder:CreateTexture(nil, "ARTWORK")
				t:SetColorTexture(1, 1, 1, 1)
				holder.bars[i] = t
			end
			local v = values[#values - n + i]
			t:ClearAllPoints()
			t:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", (i - 1) * (bw + 1), 0)
			t:SetSize(bw, math.max(1, v / maxV * 24))
			t:SetVertexColor(c[1], c[2], c[3], i == n and 1 or 0.6)
			t:Show()
		elseif t then
			t:Hide()
		end
	end
	if n > 0 then
		holder.avg:ClearAllPoints()
		holder.avg:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, (sum / n) / maxV * 24)
		holder.avg:SetSize(n * (bw + 1), 1)
		holder.avg:Show()
	else
		holder.avg:Hide()
	end
	self.y = self.y + 30
end

---------------------------------------------------------------------------
-- Quest log reading (text and rewards), cached per quest
---------------------------------------------------------------------------
local textCache = {}

local function withSelected(questID, fn)
	local QL = C_QuestLog
	if not (QL and QL.SetSelectedQuest and QL.GetSelectedQuest) or InCombatLockdown() then return pcall(fn) end
	local prev = num(try(QL.GetSelectedQuest))
	try(QL.SetSelectedQuest, questID)
	local ok, err = pcall(fn)
	if prev and prev > 0 then try(QL.SetSelectedQuest, prev) end
	return ok, err
end

local function readRewards(id, r)
	local function items(kind, n, infoFn)
		local out = {}
		for i = 1, math.min(n, 12) do
			local name, tex, count, quality, _, itemID = try(infoFn, i, id)
			local link = GetQuestLogItemLink and str(try(GetQuestLogItemLink, kind, i, id))
			tex = num(tex) or str(tex)
			itemID = num(itemID)
			-- older builds read the selected quest: only trust a link of the same item
			if link and itemID and not link:find("item:" .. itemID .. ":", 1, true) then link = nil end
			if not link and itemID then link = "item:" .. itemID end
			if tex then out[#out + 1] = { tex = tex, count = num(count, 1), quality = num(quality), link = link, name = str(name), index = i, kind = kind } end
		end
		return out
	end
	if GetNumQuestLogChoices and GetQuestLogChoiceInfo then
		r.choices = items("choice", num((try(GetNumQuestLogChoices, id, true)), 0), GetQuestLogChoiceInfo)
	end
	if GetNumQuestLogRewards and GetQuestLogRewardInfo then
		r.items = items("reward", num((try(GetNumQuestLogRewards, id)), 0), GetQuestLogRewardInfo)
	end
	r.xp = GetQuestLogRewardXP and num((try(GetQuestLogRewardXP, id)))
	r.money = GetQuestLogRewardMoney and num((try(GetQuestLogRewardMoney, id)))
	r.honor = GetQuestLogRewardHonor and num((try(GetQuestLogRewardHonor, id)))
	r.currencies = {}
	local QL = C_QuestLog
	local list = QL and QL.GetQuestRewardCurrencies and try(QL.GetQuestRewardCurrencies, id)
	if type(list) == "table" then
		for _, c in ipairs(list) do
			if type(c) == "table" then
				local tex = num(c.texture) or str(c.texture)
				if tex then r.currencies[#r.currencies + 1] = { tex = tex, count = num(c.totalRewardAmount) or num(c.baseRewardAmount), quality = num(c.quality), name = str(c.name), currencyID = num(c.currencyID) } end
			end
		end
	elseif GetNumQuestLogRewardCurrencies and GetQuestLogRewardCurrencyInfo then
		for i = 1, num((try(GetNumQuestLogRewardCurrencies, id)), 0) do
			local name, tex, amount, cid, quality = try(GetQuestLogRewardCurrencyInfo, i, id)
			tex = num(tex) or str(tex)
			if tex then r.currencies[#r.currencies + 1] = { tex = tex, count = num(amount), quality = num(quality), name = str(name), currencyID = num(cid) } end
		end
	end
	r.spells = {}
	local QI = C_QuestInfoSystem
	local ids = QI and QI.GetQuestRewardSpells and try(QI.GetQuestRewardSpells, id)
	if type(ids) == "table" and QI.GetQuestRewardSpellInfo then
		for _, sid in ipairs(ids) do
			local info = try(QI.GetQuestRewardSpellInfo, id, sid)
			local tex = type(info) == "table" and (num(info.texture) or str(info.texture))
			if tex then r.spells[#r.spells + 1] = { tex = tex, name = str(info.name), spellID = num(sid) } end
		end
	elseif GetNumQuestLogRewardSpells and GetQuestLogRewardSpell then
		for i = 1, num((try(GetNumQuestLogRewardSpells, id)), 0) do
			local tex, name = try(GetQuestLogRewardSpell, i, id)
			tex = num(tex) or str(tex)
			if tex then r.spells[#r.spells + 1] = { tex = tex, name = str(name) } end
		end
	end
	r.rep = {}
	local reps = QL and QL.GetQuestLogMajorFactionReputationRewards and try(QL.GetQuestLogMajorFactionReputationRewards, id)
	if type(reps) == "table" then
		for _, e in ipairs(reps) do
			if type(e) == "table" and num(e.factionID) then
				local name
				if C_Reputation and C_Reputation.GetFactionDataByID then
					local fd = try(C_Reputation.GetFactionDataByID, e.factionID)
					name = type(fd) == "table" and str(fd.name)
				end
				if not name and C_MajorFactions and C_MajorFactions.GetMajorFactionData then
					local md = try(C_MajorFactions.GetMajorFactionData, e.factionID)
					name = type(md) == "table" and str(md.name)
				end
				r.rep[#r.rep + 1] = { name = name or ("#" .. e.factionID), amount = num(e.rewardAmount) }
			end
		end
	end
end

local function questInfo(id)
	local c = textCache[id]
	if c and GetTime() - c.at < TEXT_TTL then return c end
	if InCombatLockdown() and c then return c end
	local QL = C_QuestLog
	local idx = QL and QL.GetLogIndexForQuestID and num(try(QL.GetLogIndexForQuestID, id))
	c = { at = GetTime() }
	if idx and idx > 0 then
		withSelected(id, function()
			if GetQuestLogQuestText then
				local d, o = try(GetQuestLogQuestText, idx)
				if not str(d) then d, o = try(GetQuestLogQuestText) end
				c.desc, c.obj = str(d), str(o)
			end
			if GetQuestLogCompletionText then c.completion = str((try(GetQuestLogCompletionText, idx))) end
			readRewards(id, c)
		end)
	end
	textCache[id] = c
	return c
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local TABS = { "overview", "stats", "history" }
local TAB_LABEL = { overview = "Overview", stats = "Stats", history = "History" }

function D:Build()
	local L, S = SoA.L, SoA.Style
	local f = CreateFrame("Frame", "ScrumOfAzerothDetail", UIParent, "BackdropTemplate")
	f:SetSize(W, H_WINDOW)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) if not self.docked then self:StartMoving() end end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		if not self.docked then
			local p, _, rp, x, y = self:GetPoint()
			SoA.char.detail.point = { p, rp, math.floor(x + 0.5), math.floor(y + 0.5) }
		end
	end)
	S:Backdrop(f, 0.97)
	f:Hide()
	tinsert(UISpecialFrames, "ScrumOfAzerothDetail")
	f:SetScript("OnHide", function() D.key, D.epicKey, D.item = nil, nil, nil if SoA.Board then SoA.Board:Schedule() end end)
	local bar = f:CreateTexture(nil, "BACKGROUND")
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", -1, -1)
	bar:SetHeight(TOP_H - 2)
	bar:SetColorTexture(0.08, 0.10, 0.14, 1)
	f.tabs = {}
	local x = 8
	for _, k in ipairs(TABS) do
		local b = S:Button(f, L[TAB_LABEL[k]], 76, 20, function() D.tab = k D:Render() end)
		b:SetPoint("TOPLEFT", x, -5)
		f.tabs[k] = b
		x = x + 80
	end
	local close = S:Button(f, "X", 22, 20, function() f:Hide() end)
	close:SetPoint("TOPRIGHT", -6, -5)
	f.body = CreateFrame("Frame", nil, f)
	f.body:SetPoint("TOPLEFT", 10, -(TOP_H + 6))
	f.body:SetPoint("BOTTOMRIGHT", -6, 8)
	f.canvas = newCanvas(f.body)
	self.frame = f
	self.tab = "overview"
end

function D:Place(opts)
	local f = self.frame
	local B = SoA.Board
	local board = B and B.frame
	f:ClearAllPoints()
	local docked = SoA.char.detail.docked and not (opts and opts.window) and board and board:IsShown()
	f.docked = docked and true or false
	if docked then
		f:SetFrameStrata("HIGH")
		f:SetPoint("TOPLEFT", board, "TOPRIGHT", 2, 0)
		f:SetPoint("BOTTOMLEFT", board, "BOTTOMRIGHT", 2, 0)
		f:SetWidth(W)
	else
		f:SetFrameStrata("DIALOG")
		f:SetSize(W, H_WINDOW)
		local anchor = opts and opts.anchor
		local pt = SoA.char.detail.point
		if anchor and anchor.GetRight and anchor:GetRight() then
			local right = anchor:GetRight() * anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
			if right + W + 10 < UIParent:GetWidth() then
				f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
			else
				f:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -6, 0)
			end
		elseif type(pt) == "table" and pt[1] then
			f:SetPoint(pt[1], UIParent, pt[2], num(pt[3], 0), num(pt[4], 0))
		else
			f:SetPoint("CENTER", 200, 0)
		end
	end
end

-- The model item for a key (quest ID, "t:n", "d:<id>", ...), or a minimal one.
local function itemFor(key)
	local m = SoA.Model:Get()
	if type(key) == "table" then
		if key.kind == "combo" then return key.members[1] end
		return key
	end
	local it = m.byKey[key]
	if it then return it end
	local id = type(key) == "number" and key or (type(key) == "string" and tonumber(key:match("^[dau]:(%d+)$") or ""))
	if id then
		it = m.byKey[id]
		if it then return it end
		for _, list in ipairs({ m.done, m.sprintDone }) do
			for _, d in ipairs(list) do if d.id == id then return d end end
		end
		return { kind = SoA.Log:InLog(id) and "quest" or "done", key = id, id = id, title = SoA.Log:Title(id) or (SoA.L["Quest"] .. " " .. id), objectives = {} }
	end
	if type(key) == "string" and key:sub(1, 2) == "t:" then
		local t = SoA.Tickets:Get(key)
		if t then return { kind = "ticket", key = key, title = t.title, ticket = t, objectives = {} } end
	end
end

function D:Open(key, opts)
	if not self.frame then self:Build() end
	local it = itemFor(key)
	if not it then return end
	self.item, self.epicKey = it, nil
	self.key = SoA.Activity.NormKey(it.id or it.key)
	if it.kind == "avail" or it.kind == "upcoming" then self.key = it.id end
	if self.tab ~= "overview" and self.tab ~= "stats" and self.tab ~= "history" then self.tab = "overview" end
	self:Place(opts)
	self.frame:Show()
	self:Render()
	if SoA.Board then SoA.Board:Schedule() end
end

function D:OpenEpic(epicKey, opts)
	if not self.frame then self:Build() end
	self.epicKey, self.item, self.key = epicKey, nil, nil
	if self.tab == "history" then self.tab = "overview" end
	self:Place(opts)
	self.frame:Show()
	self:Render()
end

function D:IsShowing(key)
	return self.frame and self.frame:IsShown() and self.key ~= nil and self.key == SoA.Activity.NormKey(key)
end

-- Tracker click (SoA's own tracker or a partner tracker through the provider).
function D:OpenFromTracker(questID, anchor)
	if not (questID and SoA.char) then return end
	if SoA.char.detail.trackerClick == "details" then
		self:Open(questID, { window = true, anchor = anchor })
		return
	end
	local B = SoA.Board
	if not (B.frame and B.frame:IsShown()) then SoA:ToggleBoard() end
	self:Open(questID)
	B:Focus(questID)
end

function D:Close() if self.frame then self.frame:Hide() end end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function moneyText(c)
	c = num(c)
	if not c then return end
	if GetMoneyString and c >= 0 then return GetMoneyString(c) end
	return math.floor(c / 10000) .. "g"
end

local function mapName(m)
	local info = m and C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m)
	return type(info) == "table" and str(info.name) or nil
end

local function statusText(it)
	local L = SoA.L
	local st = SoA.Model.Status(it)
	return L[SoA.Flow.STATUS_LABEL[st] or st] or st
end

-- Targets for "Move to..." / "Split with...": open quests, tickets, Travel, Unassigned.
local function pickTargets(exclude)
	local L = SoA.L
	local m = SoA.Model:Get()
	local list = {}
	for _, it in ipairs(m.items) do
		if (it.kind == "quest" or it.kind == "ticket") and it.key ~= exclude then list[#list + 1] = it end
	end
	SoA.Model:Sort(list, "priority")
	local out = {}
	for i = 1, math.min(#list, 20) do out[#out + 1] = { key = list[i].key, text = list[i].title, color = list[i].color } end
	out[#out + 1] = { key = SoA.Activity.TRAVEL, text = L["Travel"] }
	out[#out + 1] = { key = SoA.Activity.NONE, text = L["Unassigned"] }
	return out
end

local function pickMenu(anchor, header, exclude, fn)
	local entries = { { text = header, header = true } }
	for _, t in ipairs(pickTargets(exclude)) do
		entries[#entries + 1] = { text = "   " .. (t.text or "?"), color = t.color, fn = function() fn(t.key) end }
	end
	SoA.Board.ShowMenu(anchor, entries)
end

local function fightMenu(anchor, rec, isWalk, curKey)
	local L = SoA.L
	local Act = SoA.Activity
	local entries = {
		{ text = isWalk and L["Walk"] or L["Fight"], header = true },
		{ text = "   " .. L["Move to..."], fn = function()
			pickMenu(anchor, L["Move to..."], curKey, function(k)
				if isWalk then Act:MoveWalk(rec.id, k) else Act:MoveFight(rec.id, k) end
			end)
		end },
		{ text = "   " .. L["Split..."], fn = function()
			pickMenu(anchor, L["Split 50/50 with..."], curKey, function(k)
				if isWalk then Act:SplitWalk(rec.id, k) else Act:SplitFight(rec.id, curKey, k) end
			end)
		end },
	}
	SoA.Board.ShowMenu(anchor, entries)
end

local function fightTip(tt, f, key)
	local L, S = SoA.L, SoA.Style
	local Act = SoA.Activity
	tt:SetText(L["Fight"] .. "  " .. date("%d/%m %H:%M", num(f.t, 0)), 1, 0.82, 0)
	tt:AddDoubleLine(L["Duration"], ("%.0fs"):format(num(f.dur, 0)), 0.6, 0.65, 0.71, 1, 1, 1)
	if f.dmg then tt:AddDoubleLine(L["Damage"], S:Digits(f.dmg) .. (f.dps and ("  (" .. S:Digits(f.dps) .. " DPS)") or ""), 0.6, 0.65, 0.71, 1, 1, 1) end
	if f.heal then tt:AddDoubleLine(L["Healing"], S:Digits(f.heal), 0.6, 0.65, 0.71, 1, 1, 1) end
	if f.xp then tt:AddDoubleLine(L["XP"], S:Digits(f.xp), 0.6, 0.65, 0.71, 1, 0.82, 0) end
	if f.money and f.money > 0 then tt:AddDoubleLine(L["Money"], moneyText(f.money) or "", 0.6, 0.65, 0.71, 1, 1, 1) end
	tt:AddDoubleLine(L["Downtime after"], ("%ds"):format(num(f.down, 0)), 0.6, 0.65, 0.71, 1, 1, 1)
	if f.died then tt:AddLine(L["You died in this fight."], 1, 0.3, 0.3) end
	if f.targets and f.targets[1] then tt:AddLine(L["Target: %s"]:format(table.concat(f.targets, ", ")), 0.6, 0.65, 0.71, true) end
	local sg = SIGNAL[f.sig or "none"] or SIGNAL.none
	tt:AddLine(L["Signal: %s"]:format(L[sg.label]), sg.color[1], sg.color[2], sg.color[3], true)
	for _, p in ipairs(f.parts or {}) do
		tt:AddDoubleLine("  " .. Act:Title(p.key), ("%d%% · %s"):format(num(p.share, 1) * 100 + 0.5, L[p.role or "?"] or p.role or ""), 1, 1, 1, 0.6, 0.65, 0.71)
	end
	tt:AddLine(L["Right-click: move to another ticket or split"], 0.6, 0.65, 0.71, true)
end

---------------------------------------------------------------------------
-- Overview
---------------------------------------------------------------------------
local function questActions(cv, it)
	local L = SoA.L
	local A = SoA.Actions
	local list = {
		{ L["Track"], function() A.Select(it.id, it.title) SoA.Board:Schedule() end, L["Select the quest (arrow / super-track)."] },
		{ L["Show on map"], function()
			if InCombatLockdown() then return end
			local m = GetQuestUiMapID and num((try(GetQuestUiMapID, it.id, true)))
			if OpenWorldMap and m and m > 0 then try(OpenWorldMap, m) elseif ToggleWorldMap then try(ToggleWorldMap) end
		end },
		{ L["Add GPS stop"], function() A.AddStop(it.id, it.title) end },
		{ L["Open in quest log"], function() A.Open(it.id, it.index) end },
	}
	if it.kind == "quest" or it.kind == "ticket" then
		list[#list + 1] = { L["Put on hold"], function(btn) SoA.Board.HoldMenu(btn, it) end }
		list[#list + 1] = { L["Move to..."], function(btn) SoA.Board.MoveMenu(btn, it) end }
		if it.inSprint then
			list[#list + 1] = { L["Back to backlog"], function() SoA.Sprint:Remove(it.key) SoA.Board:NotifyCK() end }
		elseif SoA.Sprint:IsActive() then
			list[#list + 1] = { L["+ Add to sprint"], function() SoA.Sprint:Add(it.key) SoA.Board:NotifyCK() end }
		end
	end
	if it.kind == "ticket" then
		list = {
			{ L["Edit"], function() SoA.Tickets:OpenDialog(it.key) end },
			{ L["Put on hold"], function(btn) SoA.Board.HoldMenu(btn, it) end },
			{ L["Move to..."], function(btn) SoA.Board.MoveMenu(btn, it) end },
		}
		local t = it.ticket
		if t and type(t.map) == "table" then
			list[#list + 1] = { L["Point to"], function() A.PointTo(t.map.m, t.map.x, t.map.y, t.title) end }
		end
		if it.inSprint then
			list[#list + 1] = { L["Back to backlog"], function() SoA.Sprint:Remove(it.key) SoA.Board:NotifyCK() end }
		elseif SoA.Sprint:IsActive() then
			list[#list + 1] = { L["+ Add to sprint"], function() SoA.Sprint:Add(it.key) SoA.Board:NotifyCK() end }
		end
	end
	if it.kind ~= "ticket" and SoA.EpicFlow and SoA.EpicFlow:CanShow(it) then
		list[#list + 1] = { L["Show flow"], function() SoA.EpicFlow:OpenFor(it) end, L["The flow of this quest's epic: a zoomable map."] }
	end
	if SoA.Flow:CanStart(it) then
		table.insert(list, 1, { L["Start"], function() SoA.Flow:Start(it) SoA.Detail:Schedule() end, L["In progress now, into the sprint and selected, so the route can lead you there."] })
	end
	cv:Buttons(list)
end

local function header(cv, it)
	local L, S = SoA.L, SoA.Style
	local title = it.title or "?"
	local tc = S.colors.text
	if it.kind == "quest" and it.level then
		title = "[" .. (it.showLevel or it.level) .. "] " .. title
		local r, g, b = SoA.Log:LevelColor(it.level)
		tc = { r, g, b }
	end
	cv:Text(title, { size = 14, color = tc })
	if it.epicName then
		local c = it.color or S.colors.muted
		cv:Text(it.epicName .. (it.epic and it.epic.tag and ("  ·  " .. it.epic.tag) or ""), { size = 10, color = c })
	end
	local bits = {}
	if it.priority and it.kind ~= "done" then
		bits[#bits + 1] = "|cff" .. S:Hex(SoA.Priority:Color(it.priority)) .. SoA.Priority:Name(it.priority) .. "|r"
	end
	bits[#bits + 1] = statusText(it) .. (it.manualStatus and (" (" .. L["manual"] .. ")") or "")
	if it.est then bits[#bits + 1] = SoA.Estimate:Format(it.est) end
	if it.xp then bits[#bits + 1] = "|cffffd100" .. S:Digits(it.xp) .. " XP|r" end
	cv:Text(table.concat(bits, "  ·  "), { size = 11 })
	if it.blocked and it.blockReasons then
		for _, r in ipairs(it.blockReasons) do cv:Text(L["Blocked"] .. ": " .. r, { color = S.colors.warn }) end
	end
	if it.onHold then cv:Text(L["On hold"] .. ": " .. (it.holdText or ""), { color = S.gold }) end
	if it.shared and it.shared.note then cv:Text(it.shared.note, { color = S.colors.accent, size = 10 }) end
end

local function objectives(cv, it)
	local L, S, Est = SoA.L, SoA.Style, SoA.Estimate
	if not (it.objectives and #it.objectives > 0) then return end
	cv:Header(L["Objectives"])
	local kt = Est:KillTime()
	for _, o in ipairs(it.objectives) do
		if o.text and o.text ~= "" then
			local c = o.done and { 0.45, 0.85, 0.45 } or S.colors.text
			if it.kind == "ticket" and o.check then
				cv:Row({ color = o.done and S.green or S.colors.muted, text = o.text, textColor = c,
					click = function() SoA.Tickets:Toggle(it.key, o.check) end,
					tip = function(tt) tt:AddLine(L["Click to tick this step"], 1, 1, 1) end })
			else
				cv:Text((o.done and "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t " or "- ") .. o.text, { color = c })
			end
			if not o.done then
				local frac, label
				if o.pct then frac, label = o.pct / 100, ("%d%%"):format(o.pct)
				elseif o.need and o.need > 0 then frac, label = (o.have or 0) / o.need, ("%d/%d"):format(o.have or 0, o.need) end
				if frac then cv:Bar(frac, nil, label, 10) end
				local left = (o.need and o.need > 0) and math.max(0, o.need - (o.have or 0)) or nil
				if it.kind == "quest" and left and o.kind == "item" then
					local rate, enc = Est:DropRate(it.id, o.index)
					cv:Text(L["Drop rate ~%d%% (%s) · ~%d kills left"]:format(rate * 100 + 0.5,
						enc >= Est.LEARNED_N and L["learned"] or L["estimate"], math.ceil(left / rate)), { size = 10, color = S.colors.muted, indent = 10 })
				elseif it.kind == "quest" and left and o.kind == "monster" then
					cv:Text(L["%d kills left · ~%s"]:format(left, S:Minutes(left * kt / 60)), { size = 10, color = S.colors.muted, indent = 10 })
				end
			end
		end
	end
end

local function rewards(cv, it, info)
	local L, S = SoA.L, SoA.Style
	local any = (info.choices and #info.choices > 0) or (info.items and #info.items > 0) or info.xp or info.money
		or (#(info.currencies or {}) > 0) or (#(info.spells or {}) > 0) or (#(info.rep or {}) > 0)
	if not any then return end
	cv:Header(L["Rewards"])
	local up = SoA.Upgrade:ForQuest(it.id)
	local function mark(list)
		for _, d in ipairs(list) do
			d.upgrade = up and d.link and up.link == d.link
			if d.kind and d.index then
				local kind, index, qid = d.kind, d.index, it.id
				d.tipFn = function(tt)
					-- the link is checked against the quest; SetQuestLogItem only as a fallback
					if d.link then tt:SetHyperlink(d.link)
					elseif tt.SetQuestLogItem then pcall(tt.SetQuestLogItem, tt, kind, index, qid) end
					if up and up.link == d.link then SoA.Upgrade:Tooltip(tt, up) end
				end
			end
		end
		return list
	end
	if info.choices and #info.choices > 0 then
		cv:Text(L["Choose one of:"], { size = 10, color = S.colors.muted })
		cv:Icons(mark(info.choices))
	end
	if info.items and #info.items > 0 then
		cv:Text(L["You will receive:"], { size = 10, color = S.colors.muted })
		cv:Icons(mark(info.items))
	end
	local extra = {}
	for _, c in ipairs(info.currencies or {}) do
		local cid = c.currencyID
		extra[#extra + 1] = { tex = c.tex, count = c.count, quality = c.quality, tipFn = function(tt)
			if cid and tt.SetCurrencyByID then pcall(tt.SetCurrencyByID, tt, cid) else tt:SetText(c.name or "?") end
		end }
	end
	for _, sp in ipairs(info.spells or {}) do
		local sid = sp.spellID
		extra[#extra + 1] = { tex = sp.tex, tipFn = function(tt)
			if sid and tt.SetSpellByID then pcall(tt.SetSpellByID, tt, sid) else tt:SetText(sp.name or "?") end
		end }
	end
	if #extra > 0 then cv:Icons(extra) end
	local line = {}
	if info.xp and info.xp > 0 then line[#line + 1] = "|cffffd100" .. S:Digits(info.xp) .. " XP|r" end
	if info.money and info.money > 0 then line[#line + 1] = moneyText(info.money) end
	if info.honor and info.honor > 0 then line[#line + 1] = L["%d honor"]:format(info.honor) end
	if #line > 0 then cv:Text(table.concat(line, "   ")) end
	for _, r in ipairs(info.rep or {}) do
		cv:Text(L["Reputation: %s +%d"]:format(r.name, r.amount or 0), { size = 10, color = { 0.4, 0.8, 1 } })
	end
	cv:Text(L["Rewards are chosen in Blizzard's turn-in window. Shift: compare with your gear."], { size = 9, color = S.colors.muted, plain = true })
end

local function epicSteps(cv, e)
	local L, S = SoA.L, SoA.Style
	if not (e and e.steps and #e.steps > 0) then return end
	cv:Header(L["Epic: %s"]:format(e.name or "?"))
	if e.total and e.total > 0 then cv:Bar(e.done / e.total, e.color, L["%d of %d steps done"]:format(e.done or 0, e.total)) end
	for i, s in ipairs(e.steps) do
		if i > 40 then cv:Text(L["... and %d more"]:format(#e.steps - 40), { color = S.colors.muted }) break end
		local qid = s.questID
		local title = qid and (SoA.Log:Title(qid) or s.text) or s.text or "?"
		local state = s.state or (s.done and "done") or (qid and SoA.Log:InLog(qid) and "log") or (qid and "future") or "initiative"
		local color, right
		if state == "done" or s.done then color, right = S.green, L["Done"]
		elseif state == "ready" then color, right = S.green, L["Ready to turn in"]
		elseif state == "log" then color, right = S.colors.accent, L["In your log"]
		elseif state == "initiative" then color, right = S.colors.proc, L["Initiative"]
		else color, right = S.colors.muted, L["Upcoming"] end
		cv:Row({ color = color, text = title, right = right,
			textColor = (state == "future" or state == "initiative") and S.colors.muted or S.colors.text,
			click = qid and function()
				if SoA.Log:InLog(qid) then SoA.Actions.Select(qid, title) D:Open(qid) end
			end or nil })
	end
end

local function where(cv, it)
	local L, S = SoA.L, SoA.Style
	if it.kind ~= "quest" then return end
	local bits = {}
	local m = GetQuestUiMapID and num((try(GetQuestUiMapID, it.id, true)))
	local zone = mapName(m)
	if zone then bits[#bits + 1] = zone end
	local d = it.planDistance or SoA.Estimate:Distance(it.id)
	if d then bits[#bits + 1] = L["%d yd"]:format(d + 0.5) end
	if #bits == 0 and not it.turnIn then return end
	cv:Header(L["Where"])
	if #bits > 0 then cv:Text(table.concat(bits, "  ·  ")) end
	if it.ready and it.turnIn then cv:Text(L["Turn in: %s"]:format(it.turnIn), { color = S.green }) end
end

function D:Overview(cv, it)
	local L, S = SoA.L, SoA.Style
	header(cv, it)
	cv:Gap(4)
	if it.kind == "quest" then questActions(cv, it) end
	if it.kind == "ticket" then
		questActions(cv, it)
		local t = it.ticket or {}
		objectives(cv, it)
		if t.item then
			local have = SoA.Tickets:ItemCount(t) or 0
			cv:Header(L["Item goal"])
			cv:Text(("%s"):format(tostring(t.item.label or t.item.spec)))
			cv:Bar(have / math.max(1, t.item.need), nil, ("%d/%d"):format(math.min(have, t.item.need), t.item.need))
		end
		if type(t.map) == "table" then
			cv:Header(L["Location"])
			cv:Text(("%s %.0f, %.0f"):format(mapName(t.map.m) or "?", (t.map.x or 0) * 100, (t.map.y or 0) * 100))
		end
		if str(t.notes) then
			cv:Header(L["Notes"])
			cv:Text(t.notes, { color = PARCHMENT, plain = true, size = 12 })
		end
		return
	end
	if it.kind == "avail" then
		cv:Buttons({ { L["Point to the quest giver"], function() SoA.Actions.PointTo(it.mapID, it.x, it.y, it.title) end } })
	end
	local id = it.id
	local info = (id and (it.kind == "quest")) and questInfo(id) or {}
	if info.desc or info.obj then
		cv:Header(L["Description"])
		if info.obj then cv:Text(info.obj, { color = PARCHMENT, plain = true, size = 12, gap = 8 }) end
		if info.desc then cv:Text(info.desc, { color = PARCHMENT, plain = true, size = 12 }) end
	end
	if it.ready and info.completion then
		cv:Header(L["Turn-in text"])
		cv:Text(info.completion, { color = PARCHMENT, plain = true, size = 12 })
	end
	objectives(cv, it)
	if it.kind == "quest" then rewards(cv, it, info) end
	local e = it.epic or (it.epicKey and SoA.Epics:ByKey(it.epicKey))
	epicSteps(cv, e)
	if it.story and it.story ~= e then epicSteps(cv, it.story) end
	where(cv, it)
end

---------------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------------
local function statBlock(cv, s, estimate)
	local L, S = SoA.L, SoA.Style
	cv:Pair(L["Fights"], s.shared > 0 and L["%d (%d shared)"]:format(s.fights, s.shared) or tostring(s.fights))
	cv:Pair(L["Average DPS"], s.avgDps and S:Digits(s.avgDps) or "-")
	if #s.dpsList > 1 then cv:Spark(s.dpsList) end
	local actual = s.active / 60
	cv:Pair(L["Time actual / estimated"], S:Minutes(actual) .. " / " .. (estimate and S:Minutes(estimate) or "-"),
		(estimate and actual > estimate * 1.25) and S.colors.warn or nil)
	cv:Pair(L["Walking"], s.walk > 0 and S:Minutes(s.walk / 60) or "-")
	cv:Pair(L["Downtime"], s.downPct and ("%d%%"):format(s.downPct * 100 + 0.5) or "-")
	cv:Pair(L["XP per minute"], s.xpm and S:Digits(s.xpm) or "-")
	cv:Pair(L["Deaths"], tostring(s.deaths), s.deaths > 0 and S.colors.warn or nil)
	cv:Pair(L["Kills per minute"], s.kpm and ("%.1f"):format(s.kpm):gsub("%.", L["decimal"]) or "-")
end

local function efficiency(cv, s, estimate)
	local L, S = SoA.L, SoA.Style
	local score, tips = SoA.Activity:Score(s, estimate)
	cv:Header(L["Efficiency"])
	local c = score >= 75 and S.green or (score >= 50 and S.gold or S.colors.warn)
	cv:Bar(score / 100, c, L["Score %d/100"]:format(score))
	for _, t in ipairs(tips) do cv:Text("- " .. t, { size = 11, plain = true, color = PARCHMENT }) end
end

function D:Stats(cv, it)
	local L, S = SoA.L, SoA.Style
	local Act, Est = SoA.Activity, SoA.Estimate
	local key = self.key
	local s = Act:Stats(key)
	local estimate = s.firstEstimate or (SoA.Sprint:Committed(it.key)) or (it.minutes)
	cv:Text(it.title or "?", { size = 13, color = S.gold })
	cv:Header(L["Activity"])
	statBlock(cv, s, estimate)
	-- drops per kill: measured here and the learned estimate
	if it.kind == "quest" then
		for _, o in ipairs(it.objectives or {}) do
			if o.kind == "item" then
				local rate, enc = Est:DropRate(it.id, o.index)
				local measured = s.dropRate and ("%.2f"):format(s.dropRate) or "-"
				cv:Pair(L["Drops per kill"], L["%s measured · %.2f %s"]:format(measured, rate, enc >= Est.LEARNED_N and L["learned"] or L["estimate"]))
				break
			end
		end
	end
	efficiency(cv, s, estimate)
	-- shared fights
	local shared = {}
	for _, e in ipairs(Act:FightsOf(key)) do if #(e.fight.parts or {}) > 1 then shared[#shared + 1] = e end end
	if #shared > 0 then
		cv:Header(L["Shared fights"])
		for i = #shared, math.max(1, #shared - 14), -1 do
			local f, p = shared[i].fight, shared[i].part
			local others = {}
			for _, q in ipairs(f.parts) do if q.key ~= key then others[#others + 1] = Act:Title(q.key) .. " (" .. (L[q.role or "?"] or q.role or "") .. ")" end end
			local sg = SIGNAL[f.sig or "none"] or SIGNAL.none
			cv:Row({ color = sg.color, text = table.concat(others, ", "), right = ("%d%% · %.0fs"):format(num(p.share, 1) * 100 + 0.5, num(f.dur, 0)),
				tip = function(tt) fightTip(tt, f, key) end,
				click = function(button, row) if button == "RightButton" then fightMenu(row, f, false, key) end end })
		end
	end
end

---------------------------------------------------------------------------
-- History (Jira-like timeline, newest first)
---------------------------------------------------------------------------
local EVENT_COLOR = {
	accepted = { 0.41, 0.80, 0.94 }, sprint = { 0.41, 0.80, 0.94 }, backlog = { 0.60, 0.65, 0.71 },
	progress = { 0.30, 0.90, 0.30 }, moved = { 0.41, 0.80, 0.94 }, ready = { 0.30, 0.90, 0.30 },
	manual = { 0.85, 0.45, 1.00 }, auto = { 0.85, 0.45, 1.00 }, lost = { 0.95, 0.30, 0.30 },
	blocked = { 0.95, 0.30, 0.30 }, unblocked = { 0.30, 0.90, 0.30 }, hold = { 1.00, 0.82, 0.25 },
	resumed = { 0.30, 0.90, 0.30 }, turnedin = { 1.00, 0.82, 0.00 }, death = { 0.95, 0.30, 0.30 },
	corrected = { 0.85, 0.45, 1.00 }, start = { 0.30, 0.90, 0.30 },
}

local function eventText(e)
	local L = SoA.L
	local function st(s) return s and (L[SoA.Flow.STATUS_LABEL[s] or s] or s) or "?" end
	local k = e.kind
	if k == "accepted" then return L["Accepted"] end
	if k == "sprint" then return L["Added to the sprint"] end
	if k == "backlog" then return L["Back to the backlog"] end
	if k == "progress" then
		local t = e.text or ""
		return L["Progress: %s"]:format(t)
	end
	if k == "moved" then return L["Moved: %s > %s"]:format(st(e.from), st(e.to)) end
	if k == "ready" then return L["Ready to turn in"] end
	if k == "manual" then return L["Moved by you: %s > %s"]:format(st(e.from), st(e.to)) end
	if k == "auto" then return L["Automatic status resumed"] end
	if k == "start" then return L["Started by you"] end
	if k == "lost" then return L["Objective lost: %s"]:format(e.text or "?") end
	if k == "blocked" then return L["Blocked"] .. (e.reason and (": " .. e.reason) or "") end
	if k == "unblocked" then return L["Unblocked"] end
	if k == "hold" then return L["Put on hold"] .. (e.reason and (": " .. L[e.reason]) or "") end
	if k == "resumed" then return L["Resumed"] end
	if k == "turnedin" then return L["Turned in"] end
	if k == "death" then return L["Died"] end
	if k == "corrected" then return L["Fight moved here by you"] end
	return k
end

function D:History(cv, it)
	local L, S = SoA.L, SoA.Style
	local Act = SoA.Activity
	local key = self.key
	local rows = {}
	for _, e in ipairs(Act:Events(key)) do rows[#rows + 1] = { t = num(e.t, 0), event = e } end
	for _, e in ipairs(Act:FightsOf(key)) do rows[#rows + 1] = { t = num(e.fight.t, 0), fight = e.fight, part = e.part } end
	for _, w in ipairs(Act:WalksOf(key)) do rows[#rows + 1] = { t = num(w.t, 0), walk = w } end
	table.sort(rows, function(a, b) return a.t > b.t end)
	cv:Text(it.title or "?", { size = 13, color = S.gold })
	if #rows == 0 then cv:Text(L["Nothing recorded yet."], { color = S.colors.muted }) return end
	local lastDay
	for i, r in ipairs(rows) do
		if i > 150 then break end
		local day = date("%d/%m", r.t)
		if day ~= lastDay then
			lastDay = day
			cv:Text(day, { size = 10, color = S.colors.muted })
		end
		local time = date("%H:%M", r.t)
		if r.fight then
			local f, p = r.fight, r.part
			local sg = SIGNAL[f.sig or "none"] or SIGNAL.none
			local text = L["Fight %ds"]:format(num(f.dur, 0) + 0.5)
			if f.dps then text = text .. " · " .. S:Digits(f.dps) .. " DPS" end
			if #(f.parts or {}) > 1 then text = text .. " · " .. L["shared %d%%"]:format(num(p.share, 1) * 100 + 0.5) end
			if f.died then text = text .. " · |cffff4d4d" .. L["died"] .. "|r" end
			cv:Row({ color = sg.color, text = text, right = time, indent = 6,
				tip = function(tt) fightTip(tt, f, key) end,
				click = function(button, row) if button == "RightButton" then fightMenu(row, f, false, key) end end })
		elseif r.walk then
			local w = r.walk
			local kind = w.kind == "turnin" and L["to the turn-in"] or (w.kind == "taxi" and L["flight"] or (w.kind == "travel" and L["travel"] or ""))
			cv:Row({ color = { 0.55, 0.55, 0.75 }, text = L["Walk %s"]:format(S:Minutes(num(w.dur, 0) / 60)) .. (kind ~= "" and (" · " .. kind) or ""),
				right = time, indent = 6,
				tip = function(tt)
					tt:SetText(L["Walk"], 1, 0.82, 0)
					tt:AddLine(("%ds"):format(num(w.dur, 0)), 1, 1, 1)
					if w.manual then tt:AddLine(L["Corrected by you"], 0.85, 0.45, 1) end
					tt:AddLine(L["Right-click: move to another ticket or split"], 0.6, 0.65, 0.71, true)
				end,
				click = function(button, row) if button == "RightButton" then fightMenu(row, w, true, key) end end })
		else
			local e = r.event
			cv:Row({ color = EVENT_COLOR[e.kind] or S.colors.muted, text = eventText(e), right = time, indent = 6 })
		end
	end
end

---------------------------------------------------------------------------
-- Epic view
---------------------------------------------------------------------------
function D:EpicView(cv, tab)
	local L, S = SoA.L, SoA.Style
	local key = self.epicKey
	if key and key:sub(1, 3) == "dg:" and SoA.Dungeons then return SoA.Dungeons:EpicView(cv, tab, self) end
	local e = (key and key:sub(1, 3) == "st:" and SoA.Stories and SoA.Stories:ByKey(key)) or SoA.Epics:ByKey(key)
	local m = SoA.Model:Get()
	local me = m.epics[key]
	local name = (e and e.name) or (me and me.name) or key
	local color = (e and e.color) or (me and me.color) or S.gold
	cv:Text(name, { size = 14, color = color })
	if e and e.tag then cv:Text(e.tag, { size = 10, color = S.colors.muted }) end
	if SoA.EpicFlow and SoA.EpicFlow:NormKey(key) then
		cv:Buttons({ { L["Show flow"], function() SoA.EpicFlow:Open(key) end } })
	end
	local s = SoA.Activity:EpicStats(key)
	if tab == "overview" then
		if e then epicSteps(cv, e) end
		if #s.perQuest > 0 then
			cv:Header(L["Time per quest"])
			for _, q in ipairs(s.perQuest) do
				cv:Row({ color = color, text = SoA.Activity:Title(q.key),
					right = S:Minutes(q.minutes) .. (q.estimate and (" / " .. S:Minutes(q.estimate)) or "") .. "  ·  " .. L["%d fights"]:format(q.fights),
					click = function() D:Open(q.key) end })
			end
		end
	else
		cv:Header(L["Totals over %d quests"]:format(s.quests))
		statBlock(cv, s, nil)
		if s.quests > 0 then
			cv:Pair(L["Average per quest"], S:Minutes(s.active / 60 / s.quests))
		end
		efficiency(cv, s, nil)
	end
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------
function D:Render()
	local f = self.frame
	if not (f and f:IsShown()) then return end
	local S = SoA.Style
	local epic = self.epicKey ~= nil
	if not epic and self.item then
		-- refresh the item from the latest model
		local fresh = itemFor(self.item.kind == "ticket" and self.item.key or (self.item.id or self.item.key))
		if fresh then self.item = fresh end
	end
	for _, k in ipairs(TABS) do
		local b = f.tabs[k]
		b:SetShown(not (epic and k == "history"))
		S:SetActive(b, self.tab == k)
	end
	local cv = f.canvas
	cv:Begin(math.max(100, (f.body:GetWidth() or (W - 16)) - 10))
	if epic then
		SoA.guard("detail epic", self.EpicView, self, cv, self.tab)
	elseif self.item then
		if self.tab == "stats" then SoA.guard("detail stats", self.Stats, self, cv, self.item)
		elseif self.tab == "history" then SoA.guard("detail history", self.History, self, cv, self.item)
		else SoA.guard("detail overview", self.Overview, self, cv, self.item) end
	end
	cv:End()
end

function D:Schedule()
	if not (self.frame and self.frame:IsShown()) then return end
	SoA:Throttle("detail-render", 0.5, function() D:Render() end)
end

function D:OnEnable()
	for _, msg in ipairs({ "MODEL_CHANGED", "ACTIVITY", "SPRINT", "PRIORITY", "SETTINGS", "DUNGEON" }) do
		SoA:Listen(msg, function() D:Schedule() end)
	end
	SoA:On("QUEST_TURNED_IN", function(_, id) id = num(id) if id then textCache[id] = nil end end)
end
