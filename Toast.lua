-- Scrum of Azeroth by DinX: small toast stack (plain frames, safe in combat).
-- Toasts only tell; an optional button runs an action only when you click it.
local _, ns = ...
local SoA = ns.SoA

local T = SoA:NewModule("Toast")
local MAX, W, H, GAP = 4, 280, 46, 4
local LIFE, LIFE_ACTION = 8, 14

local holder
local toasts = {}
local recent = {} -- key -> time: the same toast at most once a minute

local function layout()
	for i, t in ipairs(toasts) do
		t:ClearAllPoints()
		t:SetPoint("TOP", holder, "TOP", 0, -(i - 1) * (H + GAP))
	end
end

local function remove(t)
	for i, x in ipairs(toasts) do
		if x == t then table.remove(toasts, i) break end
	end
	t:Hide()
	t.inUse = false
	layout()
end

local pool = {}
local function make()
	for _, t in ipairs(pool) do if not t.inUse then return t end end
	local S = SoA.Style
	local t = CreateFrame("Button", nil, holder, "BackdropTemplate")
	t:SetSize(W, H)
	S:Backdrop(t, 0.95)
	t:SetFrameStrata("DIALOG")
	t.stripe = t:CreateTexture(nil, "ARTWORK")
	t.stripe:SetPoint("TOPLEFT", 1, -1)
	t.stripe:SetPoint("BOTTOMLEFT", 1, 1)
	t.stripe:SetWidth(3)
	t.stripe:SetColorTexture(1, 1, 1, 1)
	t.head = S:Font(t, 10)
	t.head:SetPoint("TOPLEFT", 10, -6)
	t.head:SetText("Scrum of Azeroth")
	t.head:SetTextColor(unpack(S.gold))
	t.text = S:Font(t, 11)
	t.text:SetPoint("TOPLEFT", 10, -19)
	t.text:SetPoint("RIGHT", -8, 0)
	t.text:SetJustifyH("LEFT")
	t.text:SetWordWrap(true)
	if t.text.SetMaxLines then t.text:SetMaxLines(2) end
	t.btn = S:Button(t, "", 76, 18)
	S:ApplyFont(t.btn.text, 10)
	t.btn:SetPoint("TOPRIGHT", -6, -4)
	t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	t:SetScript("OnClick", function(self) remove(self) end)
	pool[#pool + 1] = t
	return t
end

-- text, optional color {r,g,b}, optional action = { label, fn }, optional key (dedupe)
function T:Show(text, color, action, key)
	if not (SoA.char and SoA.char.toasts and SoA.char.toasts.enabled) then return end
	if key then
		if recent[key] and GetTime() - recent[key] < 60 then return end
		recent[key] = GetTime()
	end
	if not holder then
		holder = CreateFrame("Frame", "ScrumOfAzerothToasts", UIParent)
		holder:SetSize(W, H)
		holder:SetPoint("TOP", UIParent, "TOP", 0, -150)
	end
	while #toasts >= MAX do remove(toasts[#toasts]) end
	local t = make()
	t.inUse = true
	local c = color or SoA.Style.colors.accent
	t.stripe:SetVertexColor(c[1], c[2], c[3])
	t.text:SetText(text or "")
	if action then
		t.btn.text:SetText(action[1])
		t.btn:SetScript("OnClick", function()
			remove(t)
			SoA.guard("toast action", action[2])
		end)
		t.btn:Show()
		t.text:SetPoint("RIGHT", t.btn, "LEFT", -6, 0)
	else
		t.btn:Hide()
		t.text:SetPoint("RIGHT", -8, 0)
	end
	table.insert(toasts, 1, t)
	layout()
	t:Show()
	local stamp = GetTime()
	t.stamp = stamp
	C_Timer.After(action and LIFE_ACTION or LIFE, function()
		if t.inUse and t.stamp == stamp then remove(t) end
	end)
end
