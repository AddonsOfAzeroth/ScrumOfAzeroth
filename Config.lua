-- Scrum of Azeroth by DinX: settings. One list of options, shown in our own
-- window (/soa config), in Blizzard's settings (AddOns tab) and, with
-- CasterKit, as a page in CasterKit's settings (see Bridge_CasterKit.lua).
local _, ns = ...
local SoA = ns.SoA
local num = SoA.num

local C = SoA:NewModule("Config")

local function changed()
	SoA:Fire("SETTINGS")
	SoA:Fire("MODEL_DIRTY")
	if SoA.Hooks and SoA.Hooks.Changed then pcall(SoA.Hooks.Changed) end
	C:Refresh()
end

local function opt(group, key)
	return function() return SoA.char[group][key] end,
		function(v) SoA.char[group][key] = v changed() end
end

-- ck = true: also on CasterKit's page (which has less room)
function C:Options()
	local L = SoA.L
	local o = {}
	local function add(t) o[#o + 1] = t end
	local g, s
	add({ type = "header", text = L["Board"], ck = true })
	g, s = opt("board", "mode")
	add({ type = "choice", label = L["Board mode"], opts = { { "kanban", L["Kanban"] }, { "scrum", L["Scrum"] } }, get = g, set = s, ck = true })
	g, s = opt("tracker", "groupEpics")
	add({ type = "check", label = L["Group quests by epic in CasterKit's tracker"], tip = L["Questlines become epic rows with progress; right-click folds them. Needs CasterKit."], get = g, set = s, ck = true })
	g, s = opt("board", "showLoose")
	add({ type = "check", label = L["Show loose tasks (quests without a questline)"], get = g, set = s, ck = true })
	g, s = opt("board", "showDone")
	add({ type = "check", label = L["Show the Done column"], get = g, set = s, ck = true })
	g, s = opt("board", "sprint")
	add({ type = "check", label = L["Sprint strip and burndown"], tip = L["Also the sprint line in CasterKit's tracker."], get = g, set = s, ck = true })
	g, s = opt("board", "showHold")
	add({ type = "check", label = L["Show an On hold column"], tip = L["Otherwise on-hold cards are listed at the bottom of To do (Kanban) or the backlog (Scrum)."], get = g, set = s })
	g, s = opt("board", "autoDone")
	add({ type = "check", label = L["Custom tickets: Ready moves to Done by itself"], get = g, set = s })
	g, s = opt("review", "popup")
	add({ type = "check", label = L["Show the sprint review when a sprint ends"], get = g, set = s })

	add({ type = "header", text = L["Priority"], ck = true })
	g, s = opt("priority", "weighting")
	add({ type = "choice", label = L["Priority weighting"], opts = {
		{ "balanced", L["Balanced"] }, { "xp", L["XP per minute"] }, { "story", L["Story first (chains)"] } }, get = g, set = s, ck = true })
	add({ type = "choice", label = L["Blocked from levels above you"], opts = {
		{ 2, "+2" }, { 3, "+3" }, { 4, "+4" }, { 5, "+5" }, { 6, "+6" }, { 8, "+8" } },
		get = function() return SoA.Blockers.Config().margin end,
		set = function(v) SoA.Blockers.Config().margin = v changed() end })

	add({ type = "header", text = L["Sprint capacity"], ck = true })
	g, s = opt("capacity", "kind")
	add({ type = "choice", label = L["Capacity in"], opts = { { "time", L["Minutes"] }, { "xp", L["XP"] } }, get = g, set = s, ck = true })
	g, s = opt("capacity", "minutes")
	add({ type = "choice", label = L["Time budget"], opts = {
		{ 30, "30 min" }, { 45, "45 min" }, { 60, "60 min" }, { 90, "90 min" }, { 120, "2h" }, { 180, "3h" }, { 240, "4h" } }, get = g, set = s, ck = true })
	g, s = opt("capacity", "xp")
	add({ type = "choice", label = L["XP target"], opts = {
		{ 2000, "2,000" }, { 5000, "5,000" }, { 10000, "10,000" }, { 20000, "20,000" }, { 50000, "50,000" }, { 100000, "100,000" } }, get = g, set = s })

	add({ type = "header", text = L["Language"] })
	add({ type = "choice", label = L["Language"], opts = { { "auto", L["Automatic"] }, { "enUS", "English" }, { "nlNL", "Nederlands" } },
		get = function() return SoA.db.language end,
		set = function(v) SoA.db.language = v changed() end })

	add({ type = "header", text = L["Data"] })
	add({ type = "button", label = L["Open the board"], fn = function() SoA:ToggleBoard() end, ck = true })
	add({ type = "button", label = L["Start new sprint"], fn = function() SoA.Sprint:NewSprint() SoA:Print(L["New sprint started."]) end })
	add({ type = "button", label = L["Re-import history"], fn = function() SoA.Review:Import(true) end })
	add({ type = "button", label = L["Reset learned estimates"], fn = function()
		SoA.Estimate:Reset()
		SoA:Print(L["Learned estimates reset: defaults are used again."])
	end })
	add({ type = "button", label = L["Reset sprint history"], fn = function()
		SoA.Review:Reset()
		SoA:Print(L["Sprint history reset."])
	end })
	add({ type = "note", text = L["Imported once per character: completed quests, played time, lifetime statistics. Fight times and drop rates are learned while you play."] })
	return o
end

---------------------------------------------------------------------------
-- Own widgets (CasterKit look)
---------------------------------------------------------------------------
local function buildInto(parent, width)
	local S = SoA.Style
	local widgets = {}
	local y = -8
	for _, o in ipairs(C:Options()) do
		if o.type == "header" then
			local fs = S:Font(parent, 13)
			fs:SetPoint("TOPLEFT", 12, y - 4)
			fs:SetText(o.text)
			fs:SetTextColor(unpack(S.gold))
			y = y - 26
		elseif o.type == "check" then
			local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
			b:SetSize(16, 16)
			b:SetPoint("TOPLEFT", 12, y)
			S:Backdrop(b, 1)
			local mark = b:CreateTexture(nil, "OVERLAY")
			mark:SetPoint("TOPLEFT", 3, -3)
			mark:SetPoint("BOTTOMRIGHT", -3, 3)
			mark:SetColorTexture(unpack(S.colors.accent))
			local fs = S:Font(b, 11)
			fs:SetPoint("LEFT", b, "RIGHT", 8, 0)
			fs:SetWidth(width - 60)
			fs:SetJustifyH("LEFT")
			fs:SetText(o.label)
			b:SetHitRectInsets(0, -(width - 60), 0, 0)
			b.refresh = function() mark:SetShown(o.get() and true or false) end
			b:SetScript("OnClick", function() o.set(not o.get()) b.refresh() end)
			if o.tip then
				b:SetScript("OnEnter", function(btn)
					GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
					GameTooltip:AddLine(o.tip, 1, 1, 1, true)
					GameTooltip:Show()
				end)
				b:SetScript("OnLeave", function(btn) if GameTooltip:IsOwned(btn) then GameTooltip:Hide() end end)
			end
			widgets[#widgets + 1] = b
			y = y - 22
		elseif o.type == "choice" then
			local fs = S:Font(parent, 11)
			fs:SetPoint("TOPLEFT", 12, y - 3)
			fs:SetText(o.label)
			local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
			holder:SetSize(170, 20)
			holder:SetPoint("TOPRIGHT", parent, "TOPLEFT", width - 12, y)
			S:Backdrop(holder, 1)
			local text = S:Font(holder, 11)
			text:SetPoint("CENTER")
			holder.refresh = function()
				text:SetText("-")
				local cur = o.get()
				for _, v in ipairs(o.opts) do if v[1] == cur then text:SetText(v[2]) end end
			end
			for _, d in ipairs({ { -1, "LEFT", "<" }, { 1, "RIGHT", ">" } }) do
				local a = CreateFrame("Button", nil, holder)
				a:SetSize(20, 20)
				a:SetPoint(d[2])
				local t = S:Font(a, 12)
				t:SetPoint("CENTER")
				t:SetText(d[3])
				t:SetTextColor(unpack(S.colors.accent))
				a:SetScript("OnClick", function()
					local idx = 1
					for i, v in ipairs(o.opts) do if v[1] == o.get() then idx = i end end
					idx = (idx - 1 + d[1]) % #o.opts + 1
					o.set(o.opts[idx][1])
					holder.refresh()
				end)
			end
			widgets[#widgets + 1] = holder
			y = y - 26
		elseif o.type == "button" then
			local b = S:Button(parent, o.label, 200, 20, o.fn)
			b:SetPoint("TOPLEFT", 12, y)
			y = y - 26
		elseif o.type == "note" then
			local fs = parent:CreateFontString(nil, "OVERLAY")
			fs:SetFont(S.font, 10, "")
			fs:SetTextColor(unpack(S.colors.muted))
			fs:SetPoint("TOPLEFT", 12, y - 2)
			fs:SetWidth(width - 24)
			fs:SetJustifyH("LEFT")
			fs:SetText(o.text)
			y = y - (fs:GetStringHeight() + 10)
		end
	end
	return widgets, -y
end

local sets = {}

function C:Refresh()
	for _, list in ipairs(sets) do
		for _, w in ipairs(list) do if w.refresh then w.refresh() end end
	end
end

-- Settings live in one place: CasterKit's page when CasterKit is loaded,
-- otherwise our own window (and Blizzard's AddOns tab).
function SoA:ToggleConfig()
	if SoA.Bridge and SoA.Bridge.ShowConfigPage and SoA.Bridge.ShowConfigPage("soa") then return end
	C:ToggleOwn()
end

function C:ShowOwn()
	if not (C.frame and C.frame:IsShown()) then C:ToggleOwn() end
end

function C:ToggleOwn()
	local L, S = SoA.L, SoA.Style
	if not C.frame then
		local f = CreateFrame("Frame", "ScrumOfAzerothConfig", UIParent, "BackdropTemplate")
		f:SetFrameStrata("DIALOG")
		f:SetToplevel(true)
		f:EnableMouse(true)
		f:SetMovable(true)
		f:SetClampedToScreen(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		S:Backdrop(f, 0.97)
		tinsert(UISpecialFrames, "ScrumOfAzerothConfig")
		local title = S:Font(f, 14)
		title:SetPoint("TOPLEFT", 12, -10)
		title:SetText(("Scrum of Azeroth  |cff999999v%s|r"):format(SoA.version))
		title:SetTextColor(unpack(S.gold))
		local close = S:Button(f, "X", 22, 20, function() f:Hide() end)
		close:SetPoint("TOPRIGHT", -8, -8)
		local body = CreateFrame("Frame", nil, f)
		body:SetPoint("TOPLEFT", 0, -32)
		body:SetSize(460, 10)
		local widgets, h = buildInto(body, 460)
		sets[#sets + 1] = widgets
		f:SetSize(460, h + 44)
		f:SetPoint("CENTER")
		f:Hide()
		C.frame = f
	end
	if C.frame:IsShown() then C.frame:Hide() else C.frame:Show() C:Refresh() end
end

function C:OnEnable()
	-- Blizzard settings, AddOns tab
	if type(_G.CasterKit) ~= "table" and Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		local panel = CreateFrame("Frame")
		local widgets = buildInto(panel, 520)
		sets[#sets + 1] = widgets
		panel:SetScript("OnShow", function() C:Refresh() end)
		pcall(function()
			local cat = Settings.RegisterCanvasLayoutCategory(panel, "Scrum of Azeroth")
			Settings.RegisterAddOnCategory(cat)
		end)
	end
end
