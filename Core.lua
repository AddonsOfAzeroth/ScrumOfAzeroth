-- Scrum of Azeroth by DinX: core (saved data, helpers, events, slash command)
-- Display only: it never accepts, turns in, casts or moves anything.
local ADDON, ns = ...

local SoA = CreateFrame("Frame", "ScrumOfAzerothCore")
ns.SoA = SoA
_G.ScrumOfAzeroth = SoA

local meta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
SoA.version = (meta and meta(ADDON, "Version")) or "?"
SoA.modules = {}
SoA.Actions = {}      -- click actions; the CasterKit bridge replaces some of them
SoA.sessionDone = {}  -- quests turned in this session (newest first)
SoA.loginTime = time()

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
local charDefaults = {
	board = {
		mode = "kanban",      -- "kanban" or "scrum"
		filter = "all",       -- "all", "zone", "loose" or an epic key
		showLoose = true,     -- quests without a questline ("Loose tasks")
		showDone = true,      -- Done column
		sprint = true,        -- sprint strip and burndown
		autoDone = false,     -- custom tickets: Ready -> Done by themselves
		showHold = false,     -- On hold as a column (otherwise a group under the backlog / To do)
		fold = { log = false, avail = true, upcoming = true, hold = true }, -- backlog groups
	},
	tracker = { groupEpics = true }, -- epic groups in CasterKit's quest tracker
	priority = {
		weighting = "balanced", -- "balanced", "xp" (XP/min focused) or "story" (chain first)
		manual = {},            -- [questID] = 1..5 set by the player
	},
	capacity = {
		kind = "time",  -- "time" (minutes) or "xp"
		minutes = 60,
		xp = 5000,
	},
	review = { popup = true },  -- sprint review window when a sprint ends
	blockers = { margin = 4, manual = {} }, -- level margin for "level too high"; manual blockers
	activity = { enabled = true },          -- fights, walking and downtime per ticket (Activity.lua)
	toasts = { enabled = true, holdHint = 30 }, -- holdHint: minutes without progress before "Put on hold?" (0 = off)
	stories = { enabled = true },           -- zone-story achievements as epics (Stories.lua)
	detail = { docked = true, trackerClick = "board" }, -- docked at the board or a window; tracker click: "board" or "details"
	tracker2 = {                            -- SoA's own compact tracker (only without a partner tracker)
		enabled = true, content = "auto",   -- "auto" (sprint in Scrum, in progress + ready in Kanban), "sprint", "doing", "all"
		scale = 1, maxRows = 12, locked = false, hideBlizzard = false, folded = false, collapsed = {},
		width = 250, height = 320, sort = "priority", point = nil,
	},
	list = { sort = "priority", desc = false, group = "epic", fold = {} }, -- the board's List view
	flow = { showLearned = true, showDone = true, dir = "lr", nodeSize = 1, width = 900, height = 520 }, -- Flow view (EpicFlow.lua); dir "lr" or "tb"
	sprint = nil, -- created on first use (Sprint.lua)
	point = nil,  -- board window position
}

local accountDefaults = {
	language = "auto", -- "auto", "enUS" or "nlNL"
	characters = {},   -- ["Name-Realm"] = { class, level, lastSeen } (for external tools)
	flow = { edges = {}, rejected = {} }, -- learned follow-up links: edges[fromQuestID][toQuestID] = count (EpicFlow.lua)
}

-- Bumped when the layout of the saved data changes (external tools read it).
SoA.SCHEMA = 2

local function merge(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			merge(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

---------------------------------------------------------------------------
-- Secret-safe helpers (in combat some values are hidden from add-ons)
---------------------------------------------------------------------------
local issecret = issecretvalue or function() return false end
SoA.IsSecret = issecret

function SoA.num(v, default)
	if v == nil or issecret(v) or type(v) ~= "number" or v ~= v then return default end
	return v
end

function SoA.str(v)
	if v == nil or issecret(v) or type(v) ~= "string" or v == "" then return nil end
	return v
end

function SoA.flag(v)
	if v == nil or issecret(v) then return false end
	return v ~= false and v ~= 0
end

function SoA.try(fn, ...)
	if type(fn) ~= "function" then return end
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then return a, b, c, d end
end

-- Report each kind of error once, then stay quiet.
local reported = {}
function SoA.guard(tag, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		if SoA.debug then SoA:Print(tostring(tag) .. ": " .. tostring(err)) end
		if not reported[tag] then
			reported[tag] = true
			local h = geterrorhandler and geterrorhandler()
			if h then pcall(h, err) end
		end
	end
	return ok
end

function SoA:Print(...)
	print("|cff69ccf0Scrum of Azeroth|r:", ...)
end

-- CasterKit when it is loaded and initialised, else nil.
function SoA:CK()
	local CK = _G.CasterKit
	if type(CK) == "table" and type(CK.char) == "table" then return CK end
end

function SoA:PlayerMap()
	return C_Map and C_Map.GetBestMapForUnit and SoA.num(SoA.try(C_Map.GetBestMapForUnit, "player"))
end

-- "Name-Realm" of this character (nil while the names are not known yet).
function SoA:CharKey()
	local name = SoA.str((SoA.try(UnitName, "player")))
	local realm = GetNormalizedRealmName and SoA.str((SoA.try(GetNormalizedRealmName)))
		or (GetRealmName and SoA.str((SoA.try(GetRealmName))))
	if name and realm then return name .. "-" .. realm end
	return name
end

-- Run fn now when out of combat, else once combat ends (latest call per key wins).
local combatQueue = {}
function SoA:OutOfCombat(key, fn)
	if not InCombatLockdown() then SoA.guard(key, fn) return end
	combatQueue[key] = fn
end

-- Hide a Blizzard (Edit Mode) frame without tainting it (same approach as
-- CasterKit): HideBase skips Edit Mode's replaced Hide(), and a key we may have
-- written is purged so the table slot is secure again. Out of combat only.
function SoA.PurgeKey(t, k)
	t[k] = nil
	local c = 42
	repeat
		if t[c] == nil then t[c] = nil end
		c = c + 1
	until not issecurevariable or issecurevariable(t, k)
end

function SoA.HideBlizzardFrame(frame)
	if not frame or InCombatLockdown() then return end
	if frame.system then pcall(SoA.PurgeKey, frame, "isShownExternal") end
	if frame.HideBase then frame:HideBase() else frame:Hide() end
end

---------------------------------------------------------------------------
-- Events and a small message bus
---------------------------------------------------------------------------
local handlers = {}
function SoA:On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		local ok = pcall(self.RegisterEvent, self, event) -- unknown events on this client are skipped
		if not ok then handlers[event] = nil return end
	end
	table.insert(handlers[event], fn)
end

SoA:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do SoA.guard(event, list[i], event, ...) end
end)

local callbacks = {}
function SoA:Listen(msg, fn)
	callbacks[msg] = callbacks[msg] or {}
	table.insert(callbacks[msg], fn)
end

function SoA:Fire(msg, ...)
	for _, fn in ipairs(callbacks[msg] or {}) do SoA.guard("msg " .. msg, fn, ...) end
end

-- Run fn at most once per `wait` seconds (later calls within the window are merged).
local pendingKeys = {}
function SoA:Throttle(key, wait, fn)
	if pendingKeys[key] then return end
	pendingKeys[key] = true
	C_Timer.After(wait, function()
		pendingKeys[key] = nil
		SoA.guard(key, fn)
	end)
end

function SoA:NewModule(name)
	local m = { name = name }
	self.modules[#self.modules + 1] = m
	self[name] = m
	return m
end

---------------------------------------------------------------------------
-- Default click actions (standalone). Bridge_CasterKit.lua swaps in
-- CasterKit's selection, quest log and GPS when CasterKit is loaded.
---------------------------------------------------------------------------
local A = SoA.Actions
local num, try = SoA.num, SoA.try

-- Select/track a quest: Blizzard's super-track (the objective arrow on the map).
function A.Select(questID)
	questID = num(questID)
	if not questID then return end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
		try(C_SuperTrack.SetSuperTrackedQuestID, questID)
	end
end

function A.Selected()
	if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
		return num(try(C_SuperTrack.GetSuperTrackedQuestID))
	end
end

-- Open the quest in the quest log (not in combat: the map is a protected panel there).
function A.Open(questID, logIndex)
	if InCombatLockdown() then return end
	if QuestMapFrame_OpenToQuestDetails then
		try(QuestMapFrame_OpenToQuestDetails, questID)
	elseif QuestLog_OpenToQuest and logIndex then
		try(QuestLog_OpenToQuest, logIndex)
	elseif ToggleQuestLog then
		try(ToggleQuestLog)
	end
end

-- "GPS stop": without CasterKit this is the same as tracking the quest.
function A.AddStop(questID)
	A.Select(questID)
end

-- Point at a spot (quest giver of an available questline): Blizzard's map pin.
function A.PointTo(mapID, x, y)
	mapID, x, y = num(mapID), num(x), num(y)
	if not (mapID and x and y and C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then return end
	local point = try(UiMapPoint.CreateFromCoordinates, mapID, x, y)
	if not point then return end
	try(C_Map.SetUserWaypoint, point)
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		try(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end
end

function A.AddPointStop(mapID, x, y)
	A.PointTo(mapID, x, y)
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------
SoA:On("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	ScrumOfAzerothDB = type(ScrumOfAzerothDB) == "table" and ScrumOfAzerothDB or {}
	ScrumOfAzerothCharDB = type(ScrumOfAzerothCharDB) == "table" and ScrumOfAzerothCharDB or {}
	merge(ScrumOfAzerothDB, accountDefaults)
	merge(ScrumOfAzerothCharDB, charDefaults)
	SoA.db = ScrumOfAzerothDB
	SoA.char = ScrumOfAzerothCharDB
	SoA.charDefaults = charDefaults
	SoA.db.schemaVersion = SoA.SCHEMA
	SoA.char.schemaVersion = SoA.SCHEMA
	for _, m in ipairs(SoA.modules) do
		if m.OnInit then SoA.guard("init " .. m.name, m.OnInit, m) end
	end
end)

SoA:On("PLAYER_REGEN_ENABLED", function()
	for key, fn in pairs(combatQueue) do
		combatQueue[key] = nil
		SoA.guard(key, fn)
	end
end)

SoA:On("PLAYER_LOGIN", function()
	-- character key for external tools ("Name-Realm")
	local key = SoA:CharKey()
	if key and SoA.char then
		SoA.char.character = key
		local _, class = SoA.try(UnitClass, "player")
		SoA.db.characters = type(SoA.db.characters) == "table" and SoA.db.characters or {}
		SoA.db.characters[key] = { class = SoA.str(class), level = SoA.num(UnitLevel("player")), lastSeen = time() }
	end
	for _, m in ipairs(SoA.modules) do
		if m.OnEnable then SoA.guard("enable " .. m.name, m.OnEnable, m) end
	end
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
SLASH_SCRUMOFAZEROTH1 = "/soa"
SlashCmdList.SCRUMOFAZEROTH = function(msg)
	msg = strtrim(msg or ""):lower()
	local L = SoA.L
	if msg == "config" or msg == "settings" or msg == "options" then
		SoA:ToggleConfig()
	elseif msg == "flow" then
		SoA:ToggleFlow()
	elseif msg == "sprint" then
		if SoA.Sprint then SoA.Sprint:NewSprint() end
	elseif msg == "debug" then
		SoA.debug = not SoA.debug
		SoA:Print("debug", tostring(SoA.debug))
	elseif msg == "" or msg == "board" then
		SoA:ToggleBoard()
	else
		SoA:Print(L["/soa board: quest board. /soa flow: flow view. /soa config: settings. /soa sprint: start a new sprint."])
	end
end
