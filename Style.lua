-- Scrum of Azeroth by DinX: flat look. With CasterKit loaded its Style is used,
-- so both add-ons look exactly the same.
local ADDON, ns = ...
local SoA = ns.SoA

local S = {}
SoA.Style = S

local CKS = _G.CasterKit and _G.CasterKit.Style -- CasterKit loads first (OptionalDeps)

S.flat = "Interface\\Buttons\\WHITE8x8"
-- Roboto (Apache License 2.0, see media\LICENSE-Roboto.txt) reads better than the
-- game font at small sizes; "wow" in the settings brings the game font back.
S.ROBOTO = "Interface\\AddOns\\" .. ADDON .. "\\media\\Roboto-Regular.ttf"

-- A font file added while the game runs is only found after a restart; until
-- then (or if it is missing) fall back to the game font so no text disappears.
local probe
local function usable(path)
	probe = probe or UIParent:CreateFontString(nil, "OVERLAY")
	local ok = pcall(probe.SetFont, probe, path, 12, "")
	return ok and probe:GetFont() ~= nil and (probe:GetFont()):lower():find("roboto", 1, true) ~= nil
end
S.font = (CKS and CKS.font) or (usable(S.ROBOTO) and S.ROBOTO) or STANDARD_TEXT_FONT
S.flags = (CKS and CKS.flags) or ""

-- With CasterKit its font choice wins, so both add-ons look the same.
function S:LoadFont(db)
	if CKS and CKS.font then self.font, self.flags = CKS.font, CKS.flags or "" return end
	self.font = (db and db.font == "wow" or not usable(self.ROBOTO)) and STANDARD_TEXT_FONT or self.ROBOTO
	self.flags = (db and db.fontOutline) and "OUTLINE" or ""
end

-- Font, flags and a soft shadow in one go (flags: nil = the chosen style).
function S:ApplyFont(fs, size, flags)
	fs:SetFont(self.font, size or 12, flags or self.flags)
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
end
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
	self:ApplyFont(fs, size)
	fs:SetTextColor(unpack(self.colors.text))
	return fs
end

function S:SetFont(fs, size)
	if fs.soaSize ~= size then
		self:ApplyFont(fs, size)
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

-- Scroll area with a slim scrollbar on the right. Set the content height, then
-- call scroll:Refresh(). The wheel is only taken when there is something to scroll.
function S:ScrollArea(parent)
	local sc = CreateFrame("ScrollFrame", nil, parent)
	local content = CreateFrame("Frame", nil, sc)
	content:SetSize(10, 10)
	sc:SetScrollChild(content)
	local bar = CreateFrame("Slider", nil, parent)
	bar:SetOrientation("VERTICAL")
	bar:SetWidth(5)
	bar:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", sc, "BOTTOMRIGHT", 0, 0)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.06)
	bar:SetThumbTexture(self.flat)
	local thumb = bar:GetThumbTexture()
	thumb:SetSize(5, 24)
	thumb:SetVertexColor(self.colors.accent[1], self.colors.accent[2], self.colors.accent[3], 0.8)
	bar:SetMinMaxValues(0, 0)
	bar:SetValueStep(1)
	bar:SetValue(0)
	bar:Hide()
	bar:SetScript("OnValueChanged", function(_, v)
		if not sc.syncing then sc:SetVerticalScroll(v) end
	end)
	local function sync()
		sc.syncing = true
		bar:SetValue(sc:GetVerticalScroll() or 0)
		sc.syncing = false
	end
	sc:SetScript("OnMouseWheel", function(f, delta)
		local max = f:GetVerticalScrollRange() or 0
		f:SetVerticalScroll(math.max(0, math.min(max, (f:GetVerticalScroll() or 0) - delta * 40)))
		sync()
	end)
	function sc:Refresh()
		if self.UpdateScrollChildRect then self:UpdateScrollChildRect() end
		local h = self:GetHeight() or 0
		local ch = content:GetHeight() or 0
		local max = math.max(0, ch - h)
		if (self:GetVerticalScroll() or 0) > max then self:SetVerticalScroll(max) end
		bar:SetMinMaxValues(0, max)
		bar:SetShown(max > 0)
		self:EnableMouseWheel(max > 0)
		if ch > 0 then thumb:SetHeight(math.max(16, h * h / ch)) end
		sync()
	end
	-- scroll so that [top, bottom] (offsets from the content top) is visible
	function sc:ShowRange(top, bottom)
		local h = self:GetHeight() or 0
		local cur = self:GetVerticalScroll() or 0
		if top < cur then self:SetVerticalScroll(top)
		elseif bottom > cur + h then self:SetVerticalScroll(math.max(0, bottom - h)) end
		self:Refresh()
	end
	sc.content, sc.bar = content, bar
	return sc, content, bar
end

-- Small chain-link icon (two overlapping hollow links) drawn from flat textures.
function S:ChainIcon(parent)
	local f = CreateFrame("Button", nil, parent)
	f:SetSize(14, 9)
	f.tex = {}
	for link = 0, 1 do
		local x0 = link * 6
		for _, e in ipairs({ { x0, 0, 8, 1 }, { x0, -8, 8, 1 }, { x0, 0, 1, 9 }, { x0 + 7, 0, 1, 9 } }) do
			local t = f:CreateTexture(nil, "OVERLAY")
			t:SetColorTexture(1, 1, 1, 1)
			t:SetPoint("TOPLEFT", f, "TOPLEFT", e[1], e[2])
			t:SetSize(e[3], e[4])
			f.tex[#f.tex + 1] = t
		end
	end
	function f:SetColor(r, g, b) for _, t in ipairs(self.tex) do t:SetVertexColor(r, g, b) end end
	f:SetColor(unpack(self.colors.accent))
	return f
end

-- Colour of an item quality (r, g, b).
function S:Quality(q)
	q = SoA.num(q)
	if q and C_Item and C_Item.GetItemQualityColor then
		local r, g, b = SoA.try(C_Item.GetItemQualityColor, q)
		if SoA.num(r) then return r, g, b end
	end
	local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c and c.r then return c.r, c.g, c.b end
	return 0.6, 0.6, 0.6
end

-- Minutes as "14 min" or "1h05"
function S:Minutes(m)
	m = SoA.num(m, 0)
	if m < 1 then return "<1 min" end
	local r = math.floor(m + 0.5)
	if r < 60 then return r .. " min" end
	return string.format(SoA.L["%dh%02d"], math.floor(r / 60), r % 60)
end

---------------------------------------------------------------------------
-- Resize: a grip in the bottom-right corner (shown with the movers, or always
-- on windows) scales the frame: its layout stays as it is and grows or
-- shrinks as a whole. The top-left corner stays put. Double-click: normal size.
-- opts: key (saved in SoA.char.sizes) or get/set for a frame's own scale
-- setting; save(frame) stores the new position; parent for the grip.
---------------------------------------------------------------------------
local MIN_SCALE, MAX_SCALE = 0.5, 2

local function sizes()
	SoA.char.sizes = SoA.char.sizes or {}
	return SoA.char.sizes
end

-- the scale a frame gets from its own settings; the grip multiplies it
function S:SetBaseScale(frame, base)
	frame.baseScale = base
	self:ApplyScale(frame)
end

function S:ApplyScale(frame)
	if InCombatLockdown() and frame:IsProtected() then return end
	local g = frame.sizeKey and sizes()[frame.sizeKey] or 1
	frame:SetScale((frame.baseScale or 1) * g)
end

local function pinTopLeft(frame, scale)
	local left, top = frame:GetLeft(), frame:GetTop()
	local fs = frame:GetEffectiveScale()
	frame:SetScale(scale)
	if not (left and top) then return end
	local nfs = frame:GetEffectiveScale()
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * fs / nfs, top * fs / nfs)
end

-- the window's top-left in SoA's point format { point, relativePoint, x, y }
function S:TopLeftPoint(frame)
	local left, top = frame:GetLeft(), frame:GetTop()
	if left and top then return { "TOPLEFT", "BOTTOMLEFT", math.floor(left + 0.5), math.floor(top + 0.5) } end
end
local function savePoint() end

function S:AddSizeGrip(frame, opts)
	local key = opts.key
	if key and not opts.get then frame.sizeKey = key end
	local get = opts.get or function() return sizes()[key] or 1 end
	local set = opts.set or function(v) sizes()[key] = v end
	local base = function() if opts.get then return 1 end return frame.baseScale or 1 end
	local save = opts.save or function(f) savePoint(f, key) end
	local grip = CreateFrame("Button", nil, opts.parent or frame)
	grip:SetSize(14, 14)
	grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
	grip:SetFrameLevel((opts.parent or frame):GetFrameLevel() + 20)
	for i = 0, 2 do
		local t = grip:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(self.colors.muted[1], self.colors.muted[2], self.colors.muted[3], 0.9)
		t:SetSize(2 + i * 4, 1)
		t:SetPoint("BOTTOMRIGHT", -1, 2 + i * 3)
	end
	grip:SetScript("OnEnter", function(g)
		GameTooltip:SetOwner(g, "ANCHOR_RIGHT")
		GameTooltip:SetText(SoA.L["Drag: bigger or smaller. Double-click: normal size."], 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
	grip:SetScript("OnMouseDown", function(g)
		if InCombatLockdown() and frame:IsProtected() then return end
		local startX = GetCursorPosition()
		local start = get()
		local w = math.max(20, frame:GetWidth() * frame:GetEffectiveScale())
		g:SetScript("OnUpdate", function()
			if InCombatLockdown() and frame:IsProtected() then return end
			local s = start * math.max(0.1, (w + GetCursorPosition() - startX) / w)
			s = math.floor(math.max(MIN_SCALE, math.min(MAX_SCALE, s)) * 100 + 0.5) / 100
			if s ~= get() then
				set(s)
				pinTopLeft(frame, base() * s)
			end
		end)
	end)
	grip:SetScript("OnMouseUp", function(g)
		if not g:GetScript("OnUpdate") then return end
		g:SetScript("OnUpdate", nil)
		save(frame)
		if opts.done then opts.done() end
		SoA:Fire("SIZE", key)
	end)
	grip:SetScript("OnDoubleClick", function()
		if InCombatLockdown() and frame:IsProtected() then return end
		set(1)
		pinTopLeft(frame, base())
		save(frame)
		if opts.done then opts.done() end
		SoA:Fire("SIZE", key)
	end)
	return grip
end
