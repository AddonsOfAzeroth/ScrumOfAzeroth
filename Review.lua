-- Scrum of Azeroth by DinX: level forecast, sprint review, velocity and the
-- first-run history import (completed quests, played time, statistics).
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local R = SoA:NewModule("Review")
local HISTORY_MAX = 30
local VELOCITY_N = 5

local session = { xp = 0, active = 0 }
local lastXP, lastMax

-- ScrumOfAzerothCharDB.review = { popup, history = array of sprint summaries, pace = { xph, hours },
--   sessions = array of { start, stop, active, xp, quests, fights }, lifetime, played, imported }
local SESSIONS_MAX = 100
local function rdb()
	local c = SoA.char
	if not c then return { history = {}, pace = {}, sessions = {} } end
	if type(c.review) ~= "table" then c.review = { popup = true } end
	local r = c.review
	if type(r.history) ~= "table" then r.history = {} end
	if type(r.pace) ~= "table" then r.pace = {} end
	if type(r.sessions) ~= "table" then r.sessions = {} end
	return r
end

-- This session as a record (updated every minute and at logout).
local sessionRec
local function storeSession()
	local r = rdb()
	if not sessionRec then
		sessionRec = { start = SoA.loginTime or time() }
		r.sessions[#r.sessions + 1] = sessionRec
		while #r.sessions > SESSIONS_MAX do table.remove(r.sessions, 1) end
	end
	sessionRec.stop = time()
	sessionRec.active = session.active
	sessionRec.xp = session.xp
	sessionRec.quests = #SoA.sessionDone
	if SoA.Activity then sessionRec.fights = SoA.Activity:RangeStats(sessionRec.start).fights end
	sessionRec.level = num(UnitLevel("player"))
end

local function readXP()
	local cur = UnitXP and num((try(UnitXP, "player")))
	local max = UnitXPMax and num((try(UnitXPMax, "player")))
	return cur, max
end

---------------------------------------------------------------------------
-- XP and time tracking (session and current sprint)
---------------------------------------------------------------------------
local function onXP(_, unit)
	if unit ~= nil and (SoA.IsSecret(unit) or unit ~= "player") then return end
	local cur, max = readXP()
	if not cur then return end
	if lastXP then
		local gain
		if cur >= lastXP then gain = cur - lastXP elseif lastMax then gain = (lastMax - lastXP) + cur end
		if gain and gain > 0 and gain < 10000000 then
			session.xp = session.xp + gain
			if SoA.Sprint:IsActive() then
				local s = SoA.Sprint.Data()
				s.xpGained = num(s.xpGained, 0) + gain
			end
		end
	end
	lastXP, lastMax = cur, max
end

local function tick()
	if not SoA.char then return end
	session.active = session.active + 1
	if not SoA.Sprint:IsActive() then return end
	local s = SoA.Sprint.Data()
	s.active = num(s.active, 0) + 1
	if InCombatLockdown() then
		s.combat = num(s.combat, 0) + 1
	else
		local speed = GetUnitSpeed and num((try(GetUnitSpeed, "player")))
		if speed and speed > 0.5 then s.move = num(s.move, 0) + 1 end
	end
end

-- XP per hour: this session, blended with earlier sessions, else the played-time baseline.
function R:XPPerHour()
	local r = rdb()
	local hours = session.active / 3600
	local sess = hours >= 0.05 and session.xp > 0 and session.xp / hours or nil
	local hist = num(r.pace.xph)
	if sess and hist then
		local w = math.min(1, hours)
		return sess * w + hist * (1 - w)
	end
	return sess or hist or num(r.baseline)
end

function R:Forecast()
	local cur, max = readXP()
	local rate = self:XPPerHour()
	if not (cur and max and max > 0 and rate and rate > 0) then return end
	local need = max - cur
	-- about half of leveling XP comes from kills, which rested XP doubles
	local rested = GetXPExhaustion and num((try(GetXPExhaustion))) or 0
	local eff = need - math.min(rested, need) * 0.5
	return { level = num(UnitLevel("player"), 1) + 1, hours = eff / rate, rate = rate }
end

-- Level reached with `xp` more (later levels assumed to need the same XP).
function R:LevelAfter(xp)
	local cur, max = readXP()
	if not (cur and max and max > 0 and xp) then return end
	local level, total = num(UnitLevel("player"), 1), cur + xp
	for _ = 1, 20 do
		if total < max then break end
		total, level = total - max, level + 1
	end
	return level, math.floor(total / max * 100)
end

function R:ForecastText()
	local L, S = SoA.L, SoA.Style
	local f = self:Forecast()
	if not f then return end
	return L["Level %d in ~%s at your current pace"]:format(f.level, S:Minutes(f.hours * 60))
end

---------------------------------------------------------------------------
-- Sprint review history and velocity
---------------------------------------------------------------------------
function R:Summarize(s)
	if type(s) ~= "table" or not s.started then return end
	local e = { id = s.started, goal = s.goal, planned = 0, delivered = 0, items = 0, doneItems = 0 }
	for key, est in pairs(s.est or {}) do
		e.items = e.items + 1
		e.planned = e.planned + (num(est) or 0)
		if s.done and s.done[key] then
			e.doneItems = e.doneItems + 1
			e.delivered = e.delivered + (num(est) or 0)
		end
	end
	e.held = 0
	for _ in pairs(type(s.held) == "table" and s.held or {}) do e.held = e.held + 1 end
	e.active = num(s.active, 0)
	e.combat = num(s.combat, 0)
	e.move = num(s.move, 0)
	e.idle = math.max(0, e.active - e.combat - e.move)
	e.xp = num(s.xpGained, 0)
	e.xph = e.active > 60 and e.xp / (e.active / 3600) or nil
	e.deaths = num(s.deaths, 0)
	e.levels = num(UnitLevel("player"), 1) - num(s.startLevel, num(UnitLevel("player"), 1))
	local money = GetMoney and num((try(GetMoney)))
	e.money = money and s.startMoney and (money - s.startMoney) or nil
	-- combat (Activity.lua): fights, average DPS, deaths, downtime
	if SoA.Activity then
		local cs = SoA.Activity:RangeStats(s.started, s.ended)
		e.fights = cs.fights
		e.avgDps = cs.avgDps and math.floor(cs.avgDps + 0.5) or nil
		e.fightDeaths = cs.deaths
		e.downPct = cs.downPct and math.floor(cs.downPct * 1000 + 0.5) / 10 or nil
	end
	return e
end

-- Store or update the review of a sprint (also at logout, so nothing is lost).
function R:Store(s, final)
	local e = self:Summarize(s)
	if not e or (e.items == 0 and e.active < 300) then return end
	e.ended, e.final = time(), final and true or false
	local h = rdb().history
	for i, old in ipairs(h) do
		if old.id == e.id then h[i] = e return end
	end
	h[#h + 1] = e
	while #h > HISTORY_MAX do table.remove(h, 1) end
end

function R:History() return rdb().history end

-- Delivered estimated minutes per hour played in the sprint.
local function velocity(e)
	if not e.active or e.active < 600 then return end
	return e.delivered / (e.active / 3600)
end
R.VelocityOf = velocity

-- Average share of the plan that was delivered over the last finished sprints.
function R:DeliveryRatio()
	local h = rdb().history
	local sum, n = 0, 0
	for i = #h, 1, -1 do
		local e = h[i]
		if e.final and e.planned > 0 then
			sum, n = sum + math.min(1.5, e.delivered / e.planned), n + 1
			if n >= VELOCITY_N then break end
		end
	end
	if n > 0 then return sum / n end
end

function R:Reset()
	local r = rdb()
	r.history, r.pace = {}, {}
	SoA:Fire("SPRINT")
end

---------------------------------------------------------------------------
-- History import (once per character, again via the button in settings)
---------------------------------------------------------------------------
local hidden, waiting = {}, false

local function restoreChat()
	for _, f in ipairs(hidden) do pcall(f.RegisterEvent, f, "TIME_PLAYED_MSG") end
	wipe(hidden)
	waiting = false
end

-- /played without the chat line: the chat frames skip that one event while we
-- wait for it (no hooks on Blizzard functions, so nothing gets tainted).
local function requestPlayed()
	if not RequestTimePlayed or waiting then return end
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local f = _G["ChatFrame" .. i]
		if f and f.IsEventRegistered and f:IsEventRegistered("TIME_PLAYED_MSG") then
			f:UnregisterEvent("TIME_PLAYED_MSG")
			hidden[#hidden + 1] = f
		end
	end
	waiting = true
	if not pcall(RequestTimePlayed) then restoreChat() return end
	C_Timer.After(5, function() if waiting then restoreChat() end end)
end

local function onPlayed(_, total, thisLevel)
	local r = rdb()
	thisLevel, total = num(thisLevel), num(total)
	if thisLevel then
		r.played = { total = total, level = thisLevel, at = time() }
		local cur = readXP()
		if cur and thisLevel > 600 then r.baseline = cur / (thisLevel / 3600) end
	end
	if waiting then C_Timer.After(0, restoreChat) end
end

-- Statistics by name (English and Dutch), with the usual ID only as a checked fallback.
local STATS = {
	quests = { names = { "quests completed", "voltooide quests" }, id = 98 },
	kills = { names = { "creatures killed", "total kills", "wezens gedood" }, id = 1197 },
	deaths = { names = { "total deaths", "totaal aantal doden" }, id = 60 },
	gold = { names = { "total gold acquired", "totaal verkregen goud" }, id = 328 },
}

function R:ImportStats()
	if not (GetStatistic and GetAchievementInfo) then return 0 end
	local found = {}
	local cats = GetStatisticsCategoryList and try(GetStatisticsCategoryList)
	if type(cats) == "table" and GetCategoryNumAchievements then
		for _, cat in ipairs(cats) do
			local n = num((try(GetCategoryNumAchievements, cat, true))) or 0
			for i = 1, math.min(n, 200) do
				local id, name = try(GetAchievementInfo, cat, i)
				id, name = num(id), str(name)
				if id and name then
					local low = name:lower()
					for k, w in pairs(STATS) do
						if not found[k] then
							for _, nm in ipairs(w.names) do if low == nm then found[k] = id end end
						end
					end
				end
			end
		end
	end
	for k, w in pairs(STATS) do
		if not found[k] then
			local _, name = try(GetAchievementInfo, w.id)
			if str(name) then found[k] = w.id end
		end
	end
	local life, count = {}, 0
	for k, id in pairs(found) do
		local v = str(try(GetStatistic, id))
		if v then
			local _, name = try(GetAchievementInfo, id)
			local plain = v:gsub("|T.-|t", " ")
			life[k] = { text = plain, name = str(name), value = k ~= "gold" and tonumber((plain:gsub("[^%d]", ""))) or nil }
			count = count + 1
		end
	end
	rdb().lifetime = life
	return count
end

function R:Import(manual)
	local L = SoA.L
	local n = SoA.Log:ImportCompleted()
	local stats = self:ImportStats()
	requestPlayed()
	rdb().imported = time()
	SoA:Fire("EPICS")
	if manual then
		SoA:Print(L["History imported: %s completed quests, %d statistics, played time requested."]:format(n and tostring(n) or "?", stats))
	end
end

---------------------------------------------------------------------------
-- Review window
---------------------------------------------------------------------------
local win

local function line(e, label)
	local L, S = SoA.L, SoA.Style
	if not e then return label .. ": " .. L["none"] end
	local parts = {
		L["planned %s, delivered %s"]:format(S:Minutes(e.planned), S:Minutes(e.delivered)),
		L["%d/%d items"]:format(e.doneItems, e.items),
		L["time %s"]:format(S:Minutes(e.active / 60)),
	}
	if e.xph then parts[#parts + 1] = L["%s XP/h"]:format(S:Short(e.xph)) end
	if e.levels and e.levels > 0 then parts[#parts + 1] = L["+%d levels"]:format(e.levels) end
	if e.money then parts[#parts + 1] = (GetMoneyString and e.money >= 0) and GetMoneyString(e.money) or (math.floor(e.money / 10000) .. "g") end
	parts[#parts + 1] = L["%d deaths"]:format(e.deaths or 0)
	if (e.held or 0) > 0 then parts[#parts + 1] = L["%d put on hold during sprint"]:format(e.held) end
	if e.active > 0 then
		parts[#parts + 1] = L["walking %d%% · combat %d%% · idle %d%%"]:format(e.move / e.active * 100, e.combat / e.active * 100, e.idle / e.active * 100)
	end
	if (e.fights or 0) > 0 then
		parts[#parts + 1] = L["%d fights"]:format(e.fights)
		if e.avgDps then parts[#parts + 1] = L["avg %s DPS"]:format(S:Digits(e.avgDps)) end
		if e.downPct then parts[#parts + 1] = L["downtime %d%%"]:format(e.downPct + 0.5) end
	end
	local text = label .. "\n" .. table.concat(parts, " · ")
	if e.goal and e.goal ~= "" then text = text .. "\n" .. L["Goal: %s"]:format(e.goal) end
	return text
end

local function build()
	local L, S = SoA.L, SoA.Style
	local f = CreateFrame("Frame", "ScrumOfAzerothReview", UIParent, "BackdropTemplate")
	f:SetSize(560, 560)
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
	tinsert(UISpecialFrames, "ScrumOfAzerothReview")
	local title = S:Font(f, 14)
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(L["Sprint review"])
	title:SetTextColor(unpack(S.colors.accent))
	local close = S:Button(f, "X", 22, 20, function() f:Hide() end)
	close:SetPoint("TOPRIGHT", -8, -8)

	f.chartLabel = S:Font(f, 11)
	f.chartLabel:SetPoint("TOPLEFT", 12, -38)
	f.chartLabel:SetTextColor(unpack(S.colors.muted))
	f.chart = CreateFrame("Frame", nil, f, "BackdropTemplate")
	f.chart:SetPoint("TOPLEFT", 12, -54)
	f.chart:SetSize(536, 70)
	S:Backdrop(f.chart, 0.6)
	f.bars = {}

	f.ratio = S:Font(f, 11)
	f.ratio:SetPoint("TOPLEFT", 12, -130)
	f.ratio:SetWidth(536)
	f.ratio:SetJustifyH("LEFT")

	f.current = S:Font(f, 11)
	f.current:SetPoint("TOPLEFT", 12, -152)
	f.current:SetWidth(536)
	f.current:SetJustifyH("LEFT")
	f.last = S:Font(f, 11)
	f.last:SetPoint("TOPLEFT", f.current, "BOTTOMLEFT", 0, -10)
	f.last:SetWidth(536)
	f.last:SetJustifyH("LEFT")

	f.lifeHead = S:Font(f, 12)
	f.lifeHead:SetPoint("TOPLEFT", f.last, "BOTTOMLEFT", 0, -14)
	f.lifeHead:SetText(L["Lifetime"])
	f.lifeHead:SetTextColor(unpack(S.gold))
	f.life = S:Font(f, 11)
	f.life:SetPoint("TOPLEFT", f.lifeHead, "BOTTOMLEFT", 0, -4)
	f.life:SetWidth(536)
	f.life:SetJustifyH("LEFT")
	f.roadHead = S:Font(f, 12)
	f.roadHead:SetPoint("TOPLEFT", f.life, "BOTTOMLEFT", 0, -14)
	f.roadHead:SetText(L["Roadmap: zone stories"])
	f.roadHead:SetTextColor(unpack(S.gold))
	f.road = S:Font(f, 11)
	f.road:SetPoint("TOPLEFT", f.roadHead, "BOTTOMLEFT", 0, -4)
	f.road:SetWidth(536)
	f.road:SetJustifyH("LEFT")
	f.note = S:Font(f, 10)
	f.note:SetPoint("BOTTOMLEFT", 12, 10)
	f.note:SetWidth(536)
	f.note:SetJustifyH("LEFT")
	f.note:SetTextColor(unpack(S.colors.muted))
	f.note:SetText(L["Imported: completed quests, played time, lifetime statistics. Not importable: old fight times and drop rates, which start at the defaults."])
	return f
end

function R:Refresh()
	if not (win and win:IsShown()) then return end
	local L, S = SoA.L, SoA.Style
	local h = rdb().history
	-- velocity bars, last 12 sprints
	local list = {}
	for i = math.max(1, #h - 11), #h do list[#list + 1] = h[i] end
	local maxV = 1
	for _, e in ipairs(list) do maxV = math.max(maxV, velocity(e) or 0) end
	local bw = math.floor((536 - 8) / 12) - 4
	for i = 1, math.max(#list, #win.bars) do
		local b = win.bars[i]
		local e = list[i]
		if e then
			if not b then
				b = win.chart:CreateTexture(nil, "ARTWORK")
				b:SetColorTexture(1, 1, 1, 1)
				win.bars[i] = b
			end
			local v = velocity(e) or 0
			local hgt = math.max(1, (v / maxV) * 60)
			b:ClearAllPoints()
			b:SetPoint("BOTTOMLEFT", win.chart, "BOTTOMLEFT", 6 + (i - 1) * (bw + 4), 5)
			b:SetSize(bw, hgt)
			local c = S.colors.accent
			b:SetVertexColor(c[1], c[2], c[3], i == #list and 1 or 0.55)
			b:Show()
		elseif b then
			b:Hide()
		end
	end
	win.chartLabel:SetText(L["Velocity: delivered estimated minutes per hour played (last %d sprints)"]:format(#list))
	local ratio = self:DeliveryRatio()
	win.ratio:SetText(ratio and L["Your sprints usually deliver %d%% of what was planned."]:format(ratio * 100 + 0.5) or L["No finished sprints yet."])
	local cur = SoA.Sprint:IsActive() and self:Summarize(SoA.Sprint.Data()) or nil
	win.current:SetText(line(cur, "|cff69ccf0" .. L["Current sprint"] .. "|r"))
	local last
	for i = #h, 1, -1 do if h[i].final then last = h[i] break end end
	win.last:SetText(line(last, "|cff69ccf0" .. L["Last finished sprint"] .. "|r"))
	local life = rdb().lifetime or {}
	local parts = {}
	for _, k in ipairs({ "quests", "kills", "deaths", "gold" }) do
		local v = life[k]
		if v then parts[#parts + 1] = (v.name or k) .. ": " .. v.text end
	end
	if life.kills and life.quests and life.kills.value and life.quests.value and life.quests.value > 0 then
		parts[#parts + 1] = L["%.1f kills per quest"]:format(life.kills.value / life.quests.value)
	end
	win.life:SetText(#parts > 0 and table.concat(parts, "\n") or L["Not imported yet (Settings: Re-import history)."])
	-- roadmap: completion dates of zone stories as milestones, then stories in progress
	local St = SoA.Stories
	local lines = {}
	if St then
		local done, open = St:Milestones()
		for i = 1, math.min(5, #done) do
			local s = done[i]
			lines[#lines + 1] = ("|cff4ce64c%s|r  %s"):format(date("%d/%m/%Y", s.date), s.name or "?")
		end
		for i = 1, math.min(4, #open) do
			local s = open[i]
			lines[#lines + 1] = ("|cff69ccf0%d/%d|r  %s"):format(s.done, s.total, s.name or "?")
		end
	end
	win.road:SetText(#lines > 0 and table.concat(lines, "\n") or L["No zone stories found yet."])
end

function R:Show(auto)
	win = win or build()
	if auto and InCombatLockdown() then return end
	win:Show()
	self:Refresh()
end

function R:Toggle()
	if win and win:IsShown() then win:Hide() else self:Show() end
end

function R:OnEnable()
	rdb()
	lastXP, lastMax = readXP()
	SoA:On("PLAYER_XP_UPDATE", onXP)
	SoA:On("TIME_PLAYED_MSG", onPlayed)
	SoA:On("PLAYER_LOGOUT", function()
		-- keep the pace of this session and a snapshot of the running sprint
		local r = rdb()
		local hours = session.active / 3600
		if hours > 0.05 then
			local h0 = num(r.pace.hours, 0)
			local x0 = num(r.pace.xph)
			r.pace.xph = x0 and ((x0 * h0 + session.xp) / (h0 + hours)) or (session.xp / hours)
			r.pace.hours = math.min(200, h0 + hours)
		end
		if SoA.Sprint:IsActive() then R:Store(SoA.Sprint.Data(), false) end
		if session.active > 60 then storeSession() end
	end)
	C_Timer.NewTicker(60, function() if session.active > 60 then SoA.guard("session", storeSession) end end)
	SoA:Listen("SPRINT", function() R:Refresh() end)
	C_Timer.NewTicker(1, function() SoA.guard("review-tick", tick) end)
	C_Timer.After(5, function()
		SoA.Log:ImportCompleted()
		if not rdb().imported then SoA.guard("import", R.Import, R, false) end
		SoA:Fire("EPICS")
	end)
end
