-- Scrum of Azeroth by DinX: zone stories (Loremaster-style achievements) as epics.
-- Found at runtime: achievement categories are scanned in small steps out of
-- combat for achievements whose criteria are quests (criteria type 27, asset =
-- questID). Criteria that are not a quest stay visible as initiative rows.
-- Every call is guarded; without the achievement API this module does nothing.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local St = SoA:NewModule("Stories")
local CRITERIA_QUEST = 27   -- "complete quest" criteria
local CRITERIA_ACHIEVEMENT = 8
local QUEST_ROOT_HINT = 96  -- usual "Quests" category; only used when it really exists
local STEP = 0.15           -- s between two scanned categories
local REFRESH = 30          -- s before a story's criteria are read again

local byQuest = {}  -- questID -> achievementID
local names = {}    -- achievementID -> name
local cache = {}    -- achievementID -> story (with criteria), read lazily
local scanning = false

local function enabled()
	return SoA.char and SoA.char.stories and SoA.char.stories.enabled
		and GetCategoryList and GetCategoryNumAchievements and GetAchievementInfo
		and GetAchievementNumCriteria and GetAchievementCriteriaInfo
end

local function buildKey()
	local v, b = try(GetBuildInfo)
	return tostring(v or "?") .. ":" .. tostring(b or "?") .. ":" .. tostring(GetLocale and GetLocale() or "?")
end

-- Account cache: ScrumOfAzerothDB.stories = { build, quests = { [questID] = achID }, names = { [achID] = name } }
local function load()
	local s = SoA.db and SoA.db.stories
	if type(s) == "table" and s.build == buildKey() and type(s.quests) == "table" and type(s.names) == "table" then
		for q, a in pairs(s.quests) do byQuest[q] = a end
		for a, n in pairs(s.names) do names[a] = n end
		return true
	end
end

local function save()
	if not SoA.db then return end
	local q, n = {}, {}
	for k, v in pairs(byQuest) do q[k] = v end
	for k, v in pairs(names) do n[k] = v end
	SoA.db.stories = { build = buildKey(), quests = q, names = n }
end

local function scanAchievement(id, name)
	local nc = num((try(GetAchievementNumCriteria, id)), 0)
	if nc < 2 or nc > 60 then return end
	local quests, metas = {}, 0
	for c = 1, nc do
		local _, ctype, _, _, _, _, _, asset = try(GetAchievementCriteriaInfo, id, c)
		ctype, asset = num(ctype), num(asset)
		if ctype == CRITERIA_QUEST and asset and asset > 0 then quests[#quests + 1] = asset
		elseif ctype == CRITERIA_ACHIEVEMENT then metas = metas + 1 end
	end
	if #quests == 0 or metas == nc then return end
	names[id] = name
	for _, q in ipairs(quests) do if not byQuest[q] then byQuest[q] = id end end
end

-- Categories to scan: the quest root and its children when the hint is real, else all.
local function categories()
	local all = try(GetCategoryList)
	if type(all) ~= "table" then return {} end
	local root
	if GetCategoryInfo then
		local title = str((try(GetCategoryInfo, QUEST_ROOT_HINT)))
		if title then root = QUEST_ROOT_HINT end
	end
	if not root then return all end
	local out = { root }
	for _, cat in ipairs(all) do
		local _, parent = try(GetCategoryInfo, cat)
		if num(parent) == root then out[#out + 1] = cat end
	end
	return out
end

function St:Scan(manual)
	if scanning or not enabled() then return end
	scanning = true
	wipe(byQuest) wipe(names) wipe(cache)
	local cats = categories()
	local i = 0
	local function step()
		if InCombatLockdown() then C_Timer.After(2, function() SoA.guard("stories", step) end) return end
		i = i + 1
		local cat = cats[i]
		if not cat then
			scanning = false
			save()
			if manual then SoA:Print(SoA.L["Zone stories found: %d."]:format(St:Count())) end
			SoA:Fire("EPICS")
			return
		end
		local n = num((try(GetCategoryNumAchievements, cat, true)), 0)
		for k = 1, math.min(n, 300) do
			local id, name, _, _, _, _, _, _, _, _, _, isGuild = try(GetAchievementInfo, cat, k)
			id, name = num(id), str(name)
			if id and name and not flag(isGuild) then scanAchievement(id, name) end
		end
		C_Timer.After(STEP, function() SoA.guard("stories", step) end)
	end
	step()
end

function St:Count()
	local n = 0
	for _ in pairs(names) do n = n + 1 end
	return n
end

-- Story with live criteria: { key, id, name, color, done, total, completed, date, steps = { { text, done, questID } } }
function St:Get(id)
	id = num(id)
	if not (id and names[id] and enabled()) then return end
	local s = cache[id]
	if s and GetTime() - s.at < REFRESH then return s end
	local _, name, _, completed, month, day, year = try(GetAchievementInfo, id)
	s = { key = "st:" .. id, id = id, name = str(name) or names[id], color = SoA.Epics:ColorFor(id + 7),
		story = true, steps = {}, done = 0, total = 0, at = GetTime() }
	s.completed = flag(completed)
	month, day, year = num(month), num(day), num(year)
	if s.completed and month and day and year then
		s.date = time({ year = year < 100 and 2000 + year or year, month = month, day = day, hour = 12 })
	end
	local nc = num((try(GetAchievementNumCriteria, id)), 0)
	for c = 1, math.min(nc, 60) do
		local text, ctype, cdone, _, _, _, _, asset = try(GetAchievementCriteriaInfo, id, c)
		ctype, asset = num(ctype), num(asset)
		local step = { text = str(text) or "?", done = flag(cdone) }
		if ctype == CRITERIA_QUEST and asset then step.questID = asset end
		s.steps[#s.steps + 1] = step
		s.total = s.total + 1
		if step.done then s.done = s.done + 1 end
	end
	s.tag = SoA.L["Zone story"]
	cache[id] = s
	return s
end

function St:ForQuest(questID)
	local id = byQuest[questID]
	if id then return self:Get(id) end
end

function St:ByKey(key)
	local id = type(key) == "string" and tonumber(key:match("^st:(%d+)$") or "")
	if id then return self:Get(id) end
end

-- Roadmap: completed stories with their dates (newest first) and stories in progress.
function St:Milestones()
	local done, open = {}, {}
	if not enabled() then return done, open end
	for id in pairs(names) do
		local s = self:Get(id)
		if s then
			if s.completed and s.date then done[#done + 1] = s
			elseif s.done > 0 then open[#open + 1] = s end
		end
	end
	table.sort(done, function(a, b) return a.date > b.date end)
	table.sort(open, function(a, b) return a.done / math.max(1, a.total) > b.done / math.max(1, b.total) end)
	return done, open
end

function St:Tooltip(tt, s)
	if not (tt and s) then return false end
	local L = SoA.L
	local c = s.color
	tt:SetText(s.name or "?", c[1], c[2], c[3])
	tt:AddLine(L["Zone story"] .. "  " .. L["%d of %d steps done"]:format(s.done, s.total), 0.6, 0.65, 0.71)
	for i, step in ipairs(s.steps) do
		if i > 25 then
			tt:AddLine(L["... and %d more"]:format(#s.steps - 25), 0.6, 0.65, 0.71)
			break
		end
		local title = step.questID and (SoA.Log:Title(step.questID) or step.text) or step.text
		local r = step.done and 0.45 or (step.questID and 1 or 0.7)
		local right = step.done and L["Done"] or (step.questID and (SoA.Log:InLog(step.questID) and L["In your log"] or "") or L["Initiative"])
		tt:AddDoubleLine((step.done and "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t " or "  ") .. title, right, r, step.done and 0.85 or r, step.done and 0.45 or r, 0.6, 0.65, 0.71)
	end
	return true
end

function St:OnEnable()
	if not enabled() then return end
	if not load() then
		C_Timer.After(20, function() SoA.guard("stories", St.Scan, St) end)
	end
	local function bump(_, id)
		id = num(id)
		if id then cache[id] = nil else wipe(cache) end
		SoA:Throttle("stories-bump", 5, function() SoA:Fire("EPICS") end)
	end
	SoA:On("ACHIEVEMENT_EARNED", bump)
	SoA:On("QUEST_TURNED_IN", function() wipe(cache) end)
end
