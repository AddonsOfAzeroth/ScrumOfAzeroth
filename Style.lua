-- Scrum of Azeroth by DinX: flat look. With CasterKit loaded its Style is used,
-- so both add-ons look exactly the same.
local _, ns = ...
local SoA = ns.SoA

local S = {}
SoA.Style = S

local CKS = _G.CasterKit and _G.CasterKit.Style -- CasterKit loads first (OptionalDeps)

S.flat = "Interface\\Buttons\\WHITE8x8"
S.font = STANDARD_TEXT_FONT
S.colors = (CKS and CKS.colors) or {
	bg = { 0.04, 0.05, 0.08, 0.85 },
	border = { 0, 0, 0, 1 },
	edge = { 0.16, 0.19, 0.25, 1 },
	accent = { 0.41, 0.80, 0.94 },
	text = { 0.91, 0.93, 0.95 },
	muted = { 0.60, 0.65, 0.71 },
	warn = { 0.95, 0.30, 0.30 },
	hint = { 1.00, 0.82, 0.25 },
	proc = { 0.85, 0.45, 1.00 },
	xp = { 0.58, 0.36, 0.86 },
	rested = { 0.25, 0.55, 0.95 },
}
S.gold = { 1.00, 0.82, 0.00 }
S.green = { 0.30, 0.90, 0.30 }
S.card = { 0.08, 0.10, 0.14, 0.95 }

function S:Backdrop(frame, alpha)
	if CKS then return CKS:Backdrop(frame, alpha) end
	if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
	frame:SetBackdrop({ bgFile = self.flat, edgeFile = self.flat, edgeSize = 1 })
	local c = self.colors.bg
	frame:SetBackdropColor(c[1], c[2], c[3], alpha or c[4])
	frame:SetBackdropBorderColor(0, 0, 0, 1)
end

function S:Font(parent, size, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFont(self.font, size or 12, "OUTLINE")
	fs:SetTextColor(unpack(self.colors.text))
	return fs
end

function S:SetFont(fs, size)
	if fs.soaSize ~= size then
		fs:SetFont(self.font, size, "OUTLINE")
		fs.soaSize = size
	end
end

function S:StatusBar(parent, color)
	if CKS then return CKS:StatusBar(parent, color) end
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(self.flat)
	if color then bar:SetStatusBarColor(unpack(color)) end
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.1, 0.1, 0.12, 0.9)
	bar.bg = bg
	return bar
end

-- Flat text button: dark fill, black border, accent border on hover.
function S:Button(parent, text, width, height, onClick)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(width or 100, height or 20)
	self:Backdrop(b, 1)
	b.text = self:Font(b, 11)
	b.text:SetPoint("CENTER")
	b.text:SetText(text or "")
	b:SetScript("OnEnter", function(btn)
		btn:SetBackdropBorderColor(unpack(S.colors.accent))
		if btn.tip and GameTooltip then
			GameTooltip:SetOwner(btn, "ANCHOR_TOP")
			GameTooltip:AddLine(btn.tip, 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function(btn)
		if btn.active then
			btn:SetBackdropBorderColor(unpack(S.colors.accent))
		else
			btn:SetBackdropBorderColor(0, 0, 0, 1)
		end
		if GameTooltip and GameTooltip:IsOwned(btn) then GameTooltip:Hide() end
	end)
	if onClick then b:SetScript("OnClick", onClick) end
	return b
end

-- Toggle look for a pair such as Kanban / Scrum: the active one in the accent colour.
function S:SetActive(b, on)
	b.active = on and true or false
	if on then
		b:SetBackdropBorderColor(unpack(self.colors.accent))
		b.text:SetTextColor(unpack(self.colors.accent))
	else
		b:SetBackdropBorderColor(0, 0, 0, 1)
		b.text:SetTextColor(unpack(self.colors.muted))
	end
end

function S:Hex(c)
	return string.format("%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- 12345 -> "12,345" with the separator of the language.
function S:Digits(n)
	n = SoA.num(n, 0)
	local s = tostring(math.floor(n + 0.5))
	local sign, digits = s:match("^(-?)(%d+)$")
	if not digits then return s end
	local sep = SoA.L["thousands"]
	local out = digits:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
	if out:sub(1, #sep) == sep then out = out:sub(#sep + 1) end
	return sign .. out
end

-- 4200 -> "4.2k"
function S:Short(n)
	n = SoA.num(n, 0)
	if n < 1000 then return self:Digits(n) end
	if n >= 100000 then return self:Digits(n / 1000) .. "k" end
	local s = string.format("%.1f", n / 1000):gsub("%.0$", "")
	return s:gsub("%.", SoA.L["decimal"]) .. "k"
end

-- Minutes as "14 min" or "1h05"
function S:Minutes(m)
	m = SoA.num(m, 0)
	if m < 1 then return "<1 min" end
	local r = math.floor(m + 0.5)
	if r < 60 then return r .. " min" end
	return string.format(SoA.L["%dh%02d"], math.floor(r / 60), r % 60)
end
