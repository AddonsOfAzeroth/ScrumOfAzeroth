-- Scrum of Azeroth by DinX: custom tickets (tasks that are not quests, such as
-- "Sell junk and repair" or "Farm 20 Linen Cloth"). Status and checklist are
-- moved by hand; an item objective reads GetItemCount (read-only).
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local T = SoA:NewModule("Tickets")
T.STATUS = { "todo", "doing", "ready", "done" }

-- ScrumOfAzerothCharDB.tickets = { list = array of { key = "t:<n>", title, status, minutes, label,
--   checklist = { { text, done } }, item = { need, spec, label }, map = { m, x, y }, notes, created, doneAt, manual }, next = n }
local function db()
	local c = SoA.char
	if not c then return { list = {}, next = 1 } end
	if type(c.tickets) ~= "table" then c.tickets = {} end
	if type(c.tickets.list) ~= "table" then c.tickets.list = {} end
	-- 0.1.x kept a map key -> ticket: turn it into an array of records
	local l = c.tickets.list
	local isArray = true
	for k in pairs(l) do if type(k) ~= "number" then isArray = false break end end
	if not isArray then
		local arr = {}
		for k, t in pairs(l) do
			if type(t) == "table" then
				t.key = t.key or (type(k) == "string" and k or nil)
				if t.key then arr[#arr + 1] = t end
			end
		end
		table.sort(arr, function(a, b) return num(a.created, 0) < num(b.created, 0) end)
		c.tickets.list = arr
	end
	c.tickets.next = num(c.tickets.next, 1)
	return c.tickets
end

local function indexOf(key)
	for i, t in ipairs(db().list) do
		if type(t) == "table" and t.key == key then return i end
	end
end

function T:All()
	local out = {}
	for _, t in ipairs(db().list) do
		if type(t) == "table" then out[#out + 1] = t end
	end
	table.sort(out, function(a, b) return num(a.created, 0) < num(b.created, 0) end)
	return out
end

function T:Get(key)
	local i = indexOf(key)
	return i and db().list[i] or nil
end

function T:New()
	local d = db()
	local key = "t:" .. d.next
	d.next = d.next + 1
	return { key = key, title = "", checklist = {}, minutes = 15, status = "todo", created = time() }
end

function T:Save(t)
	if not (t and t.key) then return end
	local i = indexOf(t.key)
	local list = db().list
	if i then list[i] = t else list[#list + 1] = t end
	SoA:Fire("MODEL_DIRTY")
end

function T:Delete(key)
	local i = indexOf(key)
	if i then table.remove(db().list, i) end
	if SoA.Sprint then SoA.Sprint:Remove(key) end
	if SoA.Priority then SoA.Priority:SetManual(key, nil) end
	SoA:Fire("MODEL_DIRTY")
end

function T:SetStatus(key, status)
	local t = self:Get(key)
	if not t then return end
	t.status = status
	SoA:Fire("TICKET_STATUS", key, status)
	if status == "done" then
		t.doneAt = time()
		if SoA.Sprint then SoA.Sprint:MarkDone(key, t.title) end
	end
	SoA:Fire("MODEL_DIRTY")
end

local RANK = { todo = 1, doing = 2, ready = 3, done = 4 }

-- Automatic status: first tick or item gained -> In progress; everything
-- ticked and the count reached -> Ready (-> Done with the setting). After a
-- manual move the automatic status only moves forward until "Resume automatic".
-- Called while the model builds: changes the ticket without firing messages.
function T:AutoStatus(t, have)
	if not t or t.status == "done" then return end
	local any, all, parts = false, true, 0
	for _, c in ipairs(t.checklist or {}) do
		parts = parts + 1
		if c.done then any = true else all = false end
	end
	if t.item then
		parts = parts + 1
		have = have or self:ItemCount(t) or 0
		if have > num(t.itemBase, 0) then any = true end
		if have < t.item.need then all = false end
	end
	if parts == 0 then return end
	local want = (all and "ready") or (any and "doing") or "todo"
	if want == "ready" and SoA.char.board.autoDone then want = "done" end
	if want == t.status then return end
	if t.manual and RANK[want] < RANK[t.status or "todo"] then return end
	t.status = want
	if want == "done" then
		t.doneAt = time()
		if SoA.Sprint then SoA.Sprint:MarkDone(t.key, t.title) end
	end
end

function T:ResumeAuto(key)
	local t = self:Get(key)
	if t then t.manual = nil SoA:Fire("MODEL_DIRTY") end
end

-- Next / previous column (a manual move)
function T:Move(key, dir)
	local t = self:Get(key)
	if not t then return end
	t.manual = true
	local idx = 1
	for i, s in ipairs(self.STATUS) do if s == t.status then idx = i end end
	idx = math.max(1, math.min(#self.STATUS, idx + dir))
	local old = t.status
	if SoA.Flow then SoA.Flow:Forget(key) end
	self:SetStatus(key, self.STATUS[idx])
	if SoA.Activity and old ~= t.status then SoA.Activity:Event(key, "manual", { from = old, to = t.status }) end
end

function T:Toggle(key, i)
	local t = self:Get(key)
	local c = t and t.checklist and t.checklist[i]
	if not c then return end
	c.done = not c.done
	SoA:Fire("MODEL_DIRTY")
end

function T:ItemCount(t)
	if not (t and t.item and t.item.spec) then return end
	local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
	return num((try(fn, t.item.spec)), 0)
end

-- "20 Linen Cloth" / "20 x 2589" -> { need = 20, spec = "Linen Cloth" | 2589 }
function T:ParseItem(text)
	text = str(text and strtrim(text))
	if not text then return end
	local n, rest = text:match("^(%d+)%s*[xX]?%s*(.+)$")
	if not n then return end
	rest = strtrim(rest)
	return { need = tonumber(n), spec = tonumber(rest) or rest, label = rest }
end

---------------------------------------------------------------------------
-- Create / edit dialog
---------------------------------------------------------------------------
local dlg

local function edit(parent, w, h, multi)
	local S = SoA.Style
	local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
	e:SetSize(w, h or 20)
	S:Backdrop(e, 1)
	e:SetFont(S.font, 12, "")
	e:SetTextInsets(6, 6, multi and 4 or 0, multi and 4 or 0)
	e:SetAutoFocus(false)
	e:SetMultiLine(multi and true or false)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	if not multi then e:SetScript("OnEnterPressed", e.ClearFocus) end
	return e
end

local function label(parent, text, x, y)
	local fs = SoA.Style:Font(parent, 11)
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	fs:SetTextColor(unpack(SoA.Style.colors.muted))
	return fs
end

local function build()
	local L, S = SoA.L, SoA.Style
	local f = CreateFrame("Frame", "ScrumOfAzerothTicket", UIParent, "BackdropTemplate")
	f:SetSize(380, 490)
	f:SetPoint("CENTER", 0, 60)
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
	tinsert(UISpecialFrames, "ScrumOfAzerothTicket")
	S:AddSizeGrip(f, { key = "ticket" })
	S:ApplyScale(f)

	f.head = S:Font(f, 14)
	f.head:SetPoint("TOPLEFT", 12, -10)
	f.head:SetTextColor(unpack(S.gold))

	label(f, L["Title"], 12, -38)
	f.title = edit(f, 356)
	f.title:SetPoint("TOPLEFT", 12, -54)
	f.title:SetMaxLetters(80)

	label(f, L["Estimate (minutes)"], 12, -82)
	f.minutes = edit(f, 80)
	f.minutes:SetPoint("TOPLEFT", 12, -98)
	f.minutes:SetNumeric(true)
	f.minutes:SetMaxLetters(4)

	label(f, L["Label / epic"], 110, -82)
	f.label = edit(f, 258)
	f.label:SetPoint("TOPLEFT", 110, -98)
	f.label:SetMaxLetters(40)

	label(f, L["Item objective (e.g. 20 Linen Cloth)"], 12, -126)
	f.item = edit(f, 356)
	f.item:SetPoint("TOPLEFT", 12, -142)
	f.item:SetMaxLetters(60)

	label(f, L["Checklist (one step per line)"], 12, -170)
	f.list = edit(f, 356, 96, true)
	f.list:SetPoint("TOPLEFT", 12, -186)
	f.list:SetMaxLetters(600)

	label(f, L["Notes"], 12, -290)
	f.notes = edit(f, 356, 54, true)
	f.notes:SetPoint("TOPLEFT", 12, -306)
	f.notes:SetMaxLetters(400)

	label(f, L["Priority"], 12, -366)
	f.prio = S:Button(f, "", 120, 20, function()
		local cur = f.ticketPrio or 3
		cur = cur % 5 + 1
		f.ticketPrio = cur
		f.prio.text:SetText(SoA.Priority:Name(cur))
		local c = SoA.Priority:Color(cur)
		f.prio.text:SetTextColor(c[1], c[2], c[3])
	end)
	f.prio:SetPoint("TOPLEFT", 12, -382)

	label(f, L["Location"], 150, -366)
	f.loc = S:Font(f, 11)
	f.loc:SetPoint("TOPLEFT", 150, -386)
	f.loc:SetWidth(100)
	f.loc:SetJustifyH("LEFT")
	f.here = S:Button(f, L["Here"], 50, 20, function()
		local m = SoA:PlayerMap()
		local pos = m and C_Map.GetPlayerMapPosition and try(C_Map.GetPlayerMapPosition, m, "player")
		if type(pos) == "table" and pos.GetXY then
			local ok, x, y = pcall(pos.GetXY, pos)
			x, y = ok and num(x), ok and num(y)
			if x and y then
				f.ticketMap = { m = m, x = x, y = y }
				f:ShowLoc()
			end
		end
	end)
	f.here:SetPoint("TOPLEFT", 260, -382)
	f.here.tip = L["Use your current position as the ticket's location."]
	f.clearLoc = S:Button(f, "x", 22, 20, function() f.ticketMap = nil f:ShowLoc() end)
	f.clearLoc:SetPoint("LEFT", f.here, "RIGHT", 4, 0)

	function f:ShowLoc()
		local m = self.ticketMap
		if m then
			local info = C_Map and C_Map.GetMapInfo and try(C_Map.GetMapInfo, m.m)
			local name = type(info) == "table" and str(info.name) or "?"
			self.loc:SetText(("%s %.0f, %.0f"):format(name, m.x * 100, m.y * 100))
		else
			self.loc:SetText(L["none"])
		end
	end

	f.save = S:Button(f, L["Save"], 100, 22, function() T:SaveDialog() end)
	f.save:SetPoint("BOTTOMRIGHT", -12, 12)
	f.cancel = S:Button(f, L["Cancel"], 80, 22, function() f:Hide() end)
	f.cancel:SetPoint("RIGHT", f.save, "LEFT", -6, 0)
	f.delete = S:Button(f, L["Delete"], 80, 22, function()
		if f.ticket then T:Delete(f.ticket.key) end
		f:Hide()
	end)
	f.delete:SetPoint("BOTTOMLEFT", 12, 12)
	return f
end

function T:OpenDialog(key)
	dlg = dlg or build()
	local L = SoA.L
	local t = key and self:Get(key)
	local isNew = not t
	t = t or self:New()
	dlg.ticket = t
	dlg.isNew = isNew
	dlg.head:SetText(isNew and L["New ticket"] or L["Edit ticket"])
	dlg.title:SetText(t.title or "")
	dlg.minutes:SetText(tostring(num(t.minutes, 15)))
	dlg.label:SetText(t.label or "")
	dlg.item:SetText(t.item and (t.item.need .. " " .. tostring(t.item.label or t.item.spec)) or "")
	local lines = {}
	for _, c in ipairs(t.checklist or {}) do lines[#lines + 1] = c.text end
	dlg.list:SetText(table.concat(lines, "\n"))
	dlg.notes:SetText(t.notes or "")
	dlg.ticketPrio = SoA.Priority:Manual(t.key) or 3
	dlg.prio.text:SetText(SoA.Priority:Name(dlg.ticketPrio))
	local c = SoA.Priority:Color(dlg.ticketPrio)
	dlg.prio.text:SetTextColor(c[1], c[2], c[3])
	dlg.ticketMap = t.map
	dlg:ShowLoc()
	dlg.delete:SetShown(not isNew)
	dlg:Show()
	dlg.title:SetFocus()
end

function T:SaveDialog()
	local t = dlg and dlg.ticket
	if not t then return end
	local title = str(strtrim(dlg.title:GetText() or ""))
	if not title then
		SoA:Print(SoA.L["A ticket needs a title."])
		return
	end
	t.title = title
	t.minutes = math.max(1, num(tonumber(dlg.minutes:GetText() or ""), 15))
	t.label = str(strtrim(dlg.label:GetText() or ""))
	t.item = self:ParseItem(dlg.item:GetText())
	if t.item then t.itemBase = self:ItemCount(t) or 0 end
	-- keep ticks of steps whose text did not change
	local old = {}
	for _, c in ipairs(t.checklist or {}) do old[c.text] = c.done end
	t.checklist = {}
	for line in (dlg.list:GetText() or ""):gmatch("[^\n]+") do
		line = strtrim(line)
		if line ~= "" then t.checklist[#t.checklist + 1] = { text = line, done = old[line] or false } end
	end
	t.map = dlg.ticketMap
	t.notes = str(strtrim(dlg.notes:GetText() or ""))
	self:Save(t)
	SoA.Priority:SetManual(t.key, dlg.ticketPrio)
	dlg:Hide()
end

function T:OnEnable()
	db()
	SoA:On("BAG_UPDATE", function()
		SoA:Throttle("tickets-bags", 1, function() SoA:Fire("MODEL_DIRTY") end)
	end)
	SoA:On("BAG_UPDATE_DELAYED", function()
		for _, t in ipairs(T:All()) do
			if t.item then SoA:Throttle("tickets-bags", 1, function() SoA:Fire("MODEL_DIRTY") end) break end
		end
	end)
end
