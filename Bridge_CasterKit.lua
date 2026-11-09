-- Scrum of Azeroth by DinX: bridge to the optional partners.
-- Everything SoA asks of another add-on goes through the small Bridge.*
-- functions below, so only this file changes when the route/GPS/tracker moves
-- from CasterKit into "Roads of Azeroth".
--
-- Route / GPS / tracker (Roads of Azeroth API first, else CasterKit):
--   Bridge.GetRoute()                 -> { [questID] = { xp, distance, minutes, rank, zoneMatch } }
--   Bridge.IsRouteLocked()            -> bool
--   Bridge.GetSprintKeys()            -> { "id:o", "id:t", ... } (frozen route) or nil
--   Bridge.SetSprintKeys(keys)        replace the frozen route and replan
--   Bridge.Recalculate()              plan from here (= new sprint)
--   Bridge.LockRoute()                turn on "keep the route"
--   Bridge.RequestReplan()            light replan (priorities changed)
--   Bridge.SelectQuest(id, title)     arrow/GPS to a quest (tracker click)
--   Bridge.SelectedQuest()            -> questID
--   Bridge.OpenQuest(id, logIndex)
--   Bridge.AddStop(stop)              stop = { questID, title } or { mapID, x, y, title }
--   Bridge.PointTo(mapID, x, y, title)
--   Bridge.GetTravelEstimate(questID) -> yards from the planner, or nil
--   Bridge.RegisterEpicProvider(p)    epic groups, sprint line, priority markers in the tracker
--   Bridge.Notify()                   tell the tracker our data changed
-- CasterKit-only:
--   Bridge.RegisterConfigPage(def), Bridge.ShowConfigPage(key)
local _, ns = ...
local SoA = ns.SoA
local num = SoA.num

local Bridge = SoA:NewModule("Bridge")
SoA.Bridge = Bridge
SoA.Hooks = SoA.Hooks or {}
local H = SoA.Hooks
local A = SoA.Actions

local IsLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded

local function CK()
	local c = _G.CasterKit
	if type(c) == "table" and type(c.char) == "table" then return c end
end

-- Roads of Azeroth (future): a global with an API table, version >= 1
local function Roads()
	local r = _G.RoadsOfAzeroth
	local api = type(r) == "table" and r.API
	if type(api) == "table" and num(api.version, 0) >= 1 then return api end
end

local function call(obj, name, ...)
	local fn = obj and obj[name]
	if type(fn) ~= "function" then return false end
	return pcall(fn, obj, ...)
end

-- Roads' API uses plain functions (API.Fn(...)), CasterKit modules use methods.
local function roads(name, ...)
	local api = Roads()
	local fn = api and api[name]
	if type(fn) ~= "function" then return false end
	return pcall(fn, ...)
end

local function QP() local c = CK() return c and type(c.QuestPlan) == "table" and c.QuestPlan or nil end

---------------------------------------------------------------------------
-- Route / GPS / tracker
---------------------------------------------------------------------------
function Bridge.GetRoute()
	local ok, list = roads("GetRoutePlan")
	if not ok then ok, list = call(QP(), "Get", "smart") end
	if not ok or type(list) ~= "table" then return end
	local out = {}
	for _, e in ipairs(list) do
		local id = type(e) == "table" and num(e.questID)
		if id then
			out[id] = { xp = num(e.xp), distance = num(e.distance), minutes = num(e.minutes), rank = num(e.rank), zoneMatch = e.zoneMatch and true or false,
				skip = type(e.skip) == "string" and e.skip or nil, followUps = num(e.followUps) }
		end
	end
	return out
end

function Bridge.HasRoute()
	if Roads() then return true end
	local qp = QP()
	return qp ~= nil and qp.GetFrozenRoute ~= nil and qp.SetFrozenRoute ~= nil and qp.IsLocked ~= nil
end

function Bridge.IsRouteLocked()
	local ok, v = roads("IsRouteLocked")
	if not ok then ok, v = call(QP(), "IsLocked") end
	return ok and v == true
end

function Bridge.GetSprintKeys()
	local ok, keys = roads("GetFrozenRoute")
	if not ok then ok, keys = call(QP(), "GetFrozenRoute") end
	return ok and type(keys) == "table" and keys or nil
end

function Bridge.SetSprintKeys(keys)
	if not roads("SetFrozenRoute", keys) then call(QP(), "SetFrozenRoute", keys) end
end

function Bridge.Recalculate()
	if not roads("Recalculate") then call(QP(), "Recalculate") end
end

function Bridge.LockRoute()
	if roads("LockRoute") then return end
	local c = CK()
	if not c then return end
	c.char.quests.lockRoute = true
	c:Fire("SETTINGS", "quests")
	call(QP(), "Recalculate")
end

function Bridge.RequestReplan()
	if not roads("RequestReplan") then call(QP(), "Request") end
end

function Bridge.SelectQuest(id, title)
	if roads("SelectQuest", id, title) then return true end
	local c = CK()
	return c and call(c.Quests, "ClickQuest", id, title) or false
end

function Bridge.SelectedQuest()
	local ok, id = roads("SelectedQuest")
	if ok then return num(id) end
	local c = CK()
	return c and type(c.Quests) == "table" and num(c.Quests.selected) or nil
end

function Bridge.OpenQuest(id, index)
	if roads("OpenQuest", id, index) then return true end
	local c = CK()
	return c and call(c.Quests, "OpenQuest", id, index) or false
end

function Bridge.AddStop(stop)
	if type(stop) ~= "table" then return false end
	if roads("AddStop", stop) then return true end
	local c = CK()
	local N = c and c.Nav
	if stop.questID then return call(N, "AddQuest", stop.questID, stop.title) end
	return call(N, "Add", stop.mapID, stop.x, stop.y, stop.title, "quest")
end

function Bridge.PointTo(m, x, y, title)
	if roads("PointTo", m, x, y, title) then return true end
	local c = CK()
	if not c then return false end
	local okN, owns = call(c.Nav, "OwnsArrow")
	if okN and owns and call(c.Nav, "SetOverride", m, x, y, title, "quest") then return true end
	return call(c.Arrow, "SetTarget", m, x, y, title)
end

-- Route strategy ("balanced", "turnin", "quest", "nearest"): Roads API, else CasterKit's planner.
Bridge.STRATEGY_LABEL = { balanced = "Balanced", turnin = "Turn in first", quest = "Quest first", nearest = "Nearest" }

function Bridge.RouteStrategies()
	local ok, list = roads("GetRouteStrategies")
	if ok and type(list) == "table" then return list end
	local qp = QP()
	if qp and type(qp.STRATEGIES) == "table" then return qp.STRATEGIES end
end

function Bridge.GetRouteStrategy()
	local ok, s = roads("GetRouteStrategy")
	if not ok then ok, s = call(QP(), "Strategy") end
	return ok and type(s) == "string" and s or nil
end

function Bridge.SetRouteStrategy(key)
	if roads("SetRouteStrategy", key) then return true end
	return call(QP(), "SetStrategy", key)
end

-- A partner quest tracker is shown (CasterKit's tracker, or Roads of Azeroth's).
function Bridge.PartnerTracker()
	local ok, v = roads("HasTracker")
	if ok and v then return true end
	local c = CK()
	return c ~= nil and type(c.Quests) == "table" and type(c.char.quests) == "table" and c.char.quests.enabled ~= false
end

function Bridge.GetTravelEstimate(questID)
	local r = Bridge.GetRoute()
	return r and r[questID] and r[questID].distance or nil
end

function Bridge.RegisterEpicProvider(p)
	if roads("RegisterEpicProvider", p) then return end
	local c = _G.CasterKit
	if type(c) == "table" then c.EpicProvider = p end
end

function Bridge.Notify()
	SoA:Throttle("bridge-notify", 0.3, function()
		if roads("NotifyEpicsChanged") then return end
		local c = CK()
		if c then c:Fire("EPICS") end
	end)
end

-- partner messages: route changed / recalculated / settings
local function listenPartners()
	local c = _G.CasterKit
	if type(c) == "table" and c.Listen and not Bridge.ckListening then
		Bridge.ckListening = true
		c:Listen("QUESTPLAN_RECALC", function()
			if SoA.Sprint.backend == Bridge.backend then SoA.guard("recalc", SoA.Sprint.Reset, SoA.Sprint) end
		end)
		c:Listen("QUESTPLAN", function() SoA.Model:Dirty() SoA:Fire("MODEL_CHANGED") end)
		c:Listen("NAV", function() SoA:Fire("SETTINGS") end)
		c:Listen("SETTINGS", function(group)
			if group == "quests" then SoA.Model:Dirty() SoA:Fire("SPRINT") SoA:Fire("PARTNERS") end
		end)
	end
	local api = Roads()
	if api and api.RegisterCallback and not Bridge.roadsListening then
		Bridge.roadsListening = true
		pcall(api.RegisterCallback, Bridge, "ROA_ROUTE_RECALCULATED", function()
			if SoA.Sprint.backend == Bridge.backend then SoA.guard("recalc", SoA.Sprint.Reset, SoA.Sprint) end
		end)
		pcall(api.RegisterCallback, Bridge, "ROA_ROUTE_CHANGED", function() SoA.Model:Dirty() SoA:Fire("MODEL_CHANGED") end)
	end
end

---------------------------------------------------------------------------
-- CasterKit-only: settings page with CasterKit's own widgets
---------------------------------------------------------------------------
function Bridge.RegisterConfigPage(def)
	local c = _G.CasterKit
	if type(c) ~= "table" then return false end
	c.configPages = type(c.configPages) == "table" and c.configPages or {}
	for _, d in ipairs(c.configPages) do if d.key == def.key then return true end end
	table.insert(c.configPages, def)
	return true
end

function Bridge.ShowConfigPage(key)
	local c = CK()
	if not (c and c.ToggleConfig and type(c.Config) == "table" and c.Config.Show) then return false end
	local ok = pcall(c.ToggleConfig, c, true)
	if ok and c.Config.pages and c.Config.pages[key] then pcall(c.Config.Show, c.Config, key) return true end
	return false
end

---------------------------------------------------------------------------
-- Sprint backend: the locked route of the partner is the sprint
---------------------------------------------------------------------------
local backend = {}
Bridge.backend = backend
function backend:Kind() return Roads() and "roads" or "casterkit" end
function backend:IsActive() return Bridge.IsRouteLocked() end
function backend:GetKeys() return Bridge.GetSprintKeys() end
function backend:SetKeys(keys) Bridge.SetSprintKeys(keys) end
function backend:NewSprint() Bridge.Recalculate() end -- the partner's "recalculated" message resets our data

---------------------------------------------------------------------------
-- Epic provider for the partner tracker
---------------------------------------------------------------------------
local P = {}
local function peek() return SoA.Model and SoA.Model:Peek() end

function P:GroupingEnabled() return SoA.char and SoA.char.tracker.groupEpics and true or false end
function P:GetEpic(questID) return SoA.API.GetEpic(questID) end
function P:LooseGroup()
	return { key = "loose", name = SoA.L["Loose tasks"], color = SoA.Style.colors.muted, header = SoA.char and SoA.char.board.showLoose ~= false }
end
function P:EpicTooltip(tt, key)
	local L = SoA.L
	if key == "loose" then
		tt:SetText(L["Loose tasks"], 0.6, 0.65, 0.71)
		tt:AddLine(L["Quests without a questline."], 1, 1, 1, true)
	elseif type(key) == "string" and key:sub(1, 3) == "st:" then
		if not (SoA.Stories and SoA.Stories:Tooltip(tt, SoA.Stories:ByKey(key))) then return false end
	else
		local e = SoA.Epics:ByKey(key)
		if not (e and SoA.Epics:Tooltip(tt, e)) then return false end
	end
	tt:AddLine(L["Click: select the next quest · Right-click: fold"], 0.6, 0.65, 0.71, true)
	return true
end
function P:ToggleBoard() SoA:ToggleBoard() end
function P:BoardTooltip(tt)
	local L = SoA.L
	tt:SetText(L["Quest board"], 1, 0.82, 0)
	tt:AddLine(L["Kanban and Scrum view of your quests (/soa)."], 1, 1, 1, true)
	return true
end
function P:SprintLine()
	if not (SoA.char and SoA.char.board.sprint and SoA.Sprint:IsActive()) then return end
	local L, S = SoA.L, SoA.Style
	local st = SoA.Sprint:Status(peek() or false)
	if not st or st.items == 0 then return end
	return L["Sprint %d/%d · %s left · %s XP"]:format(st.doneItems, st.items, S:Minutes(st.remaining), S:Digits(st.xpRemaining))
end
function P:SprintTooltip(tt)
	if not SoA.Sprint:IsActive() then return false end
	local L, S = SoA.L, SoA.Style
	local st = SoA.Sprint:Status(peek() or false)
	if not st then return false end
	tt:SetText(L["Sprint"], 1, 0.82, 0)
	if st.goal and st.goal ~= "" then tt:AddLine(L["Goal: %s"]:format(st.goal), 1, 1, 1, true) end
	tt:AddLine(L["Committed %s / Delivered %s"]:format(S:Minutes(st.committed), S:Minutes(st.delivered)), 1, 1, 1)
	tt:AddLine(L["%s / %s XP"]:format(S:Short(st.xpDelivered), S:Short(st.xpCommitted)), 1, 0.82, 0)
	local ft = SoA.Review:ForecastText()
	if ft then tt:AddLine(ft, 0.6, 0.65, 0.71, true) end
	tt:AddLine(L["Click: open the quest board"], 0.6, 0.65, 0.71)
	return true
end
function P:PriorityMarker(questID)
	local pr = SoA.API.GetPriority(questID)
	if pr then return SoA.Priority:Marker(pr) end
end
function P:GetPriority(questID) return SoA.API.GetPriority(questID) end -- cached only
function P:IsOnHold(questID) return SoA.API.IsOnHold(questID) end
function P:GetKillTime()
	local v, n = SoA.Estimate:KillTime()
	if n >= SoA.Estimate.LEARNED_N then return v end
end
function P:GetDropRate(text) return SoA.Estimate:DropRateByText(text) end
function P:SharedWith(questID)
	local m = peek()
	local it = m and m.byKey[questID]
	return it and it.shared and it.shared.partnerKey or nil
end
-- a click on a quest in the partner tracker: open the board with its details
function P:OnQuestClick(questID)
	if SoA.Detail then SoA.Detail:OpenFromTracker(num(questID)) end
end

-- All SoA settings on CasterKit's page, in a scroll area (CasterKit's own widgets).
local function configPage(page)
	local L = SoA.L
	local S = SoA.Style
	local mt = getmetatable(page)
	local holder = page.frame
	local sc, content = S:ScrollArea(holder)
	sc:SetPoint("TOPLEFT", 0, 0)
	sc:SetPoint("BOTTOMRIGHT", 0, 0)
	content:SetWidth(470)
	local sub = setmetatable({ frame = content, y = 0, widgets = page.widgets }, mt)
	sub:Note(L["All settings of the Scrum of Azeroth add-on."])
	for _, o in ipairs(SoA.Config:Options()) do
		if o.type == "header" then sub:Gap(4) sub:Header(o.text)
		elseif o.type == "check" then sub:Check(o.label, o.tip, o.get, o.set)
		elseif o.type == "choice" then sub:Choice(o.label, o.opts, o.get, o.set)
		elseif o.type == "slider" and sub.Slider then sub:Slider(o.label, o.min, o.max, o.step, o.get, o.set, o.fmt)
		elseif o.type == "button" then sub:Button(o.label, o.fn, 220)
		elseif o.type == "note" then sub:Note(o.text)
		end
	end
	content:SetHeight(-sub.y + 10)
	holder:HookScript("OnShow", function() sc:Refresh() end)
	C_Timer.After(0, function() sc:Refresh() end)
end

---------------------------------------------------------------------------
-- Attach (load-order independent: now, at a partner's ADDON_LOADED, or at login)
---------------------------------------------------------------------------
local actionsInstalled = false

local function installActions()
	if actionsInstalled then return end
	actionsInstalled = true
	local base = {}
	for k, v in pairs(A) do base[k] = v end
	A.Select = function(id, title) if not Bridge.SelectQuest(id, title) then base.Select(id) end end
	A.Selected = function() return Bridge.SelectedQuest() or base.Selected() end
	A.Open = function(id, index) if not Bridge.OpenQuest(id, index) then base.Open(id, index) end end
	A.AddStop = function(id, title) if not Bridge.AddStop({ questID = id, title = title }) then base.AddStop(id) end end
	A.PointTo = function(m, x, y, title) if not Bridge.PointTo(m, x, y, title) then base.PointTo(m, x, y) end end
	A.AddPointStop = function(m, x, y, title)
		if not Bridge.AddStop({ mapID = m, x = x, y = y, title = title }) then base.AddPointStop(m, x, y) end
	end
end

function Bridge:Attach()
	local hasCK, hasRoads = type(_G.CasterKit) == "table", Roads() ~= nil
	if not (hasCK or hasRoads) then return end
	Bridge.RegisterEpicProvider(P)
	if hasCK then
		Bridge.RegisterConfigPage({ key = "soa", label = SoA.L["Quest board"], group = "Scrum of Azeroth", build = configPage })
	end
	if not (SoA.char and (CK() or hasRoads)) then return end -- saved data not ready yet: again at login
	if Bridge.HasRoute() then SoA.Sprint.backend = backend end
	installActions()
	H.Plan = Bridge.GetRoute
	H.LockRoute = Bridge.HasRoute() and Bridge.LockRoute or nil
	H.Changed = function() Bridge.Notify() Bridge.RequestReplan() end
	listenPartners()
	Bridge.attached = true
	SoA.Model:Dirty()
	SoA:Fire("MODEL_CHANGED")
	SoA:Fire("PARTNERS") -- the compact tracker hides itself when a partner tracker is there
end

local function refreshPartner()
	if not Bridge.attached then return end
	SoA:Throttle("bridge-model", 2, function()
		SoA.Model:Get()
		Bridge.Notify()
	end)
end

function Bridge:OnInit()
	self:Attach() -- partners that loaded before us register their hooks now
end

function Bridge:OnEnable()
	self:Attach()
	for _, msg in ipairs({ "MODEL_CHANGED", "SPRINT", "PRIORITY", "EPICS", "SETTINGS" }) do SoA:Listen(msg, refreshPartner) end
	refreshPartner()
end

-- a partner that loads after us (load on demand, or no OptionalDeps order)
SoA:On("ADDON_LOADED", function(_, name)
	if name == "CastersOfAzeroth" or name == "CasterKit" or name == "RoadsOfAzeroth" then
		C_Timer.After(0, function()
			Bridge:Attach()
			if IsLoggedIn and IsLoggedIn() then refreshPartner() end
		end)
	end
end)

function Bridge.PartnerLoaded(name) return IsLoaded and IsLoaded(name) or false end
