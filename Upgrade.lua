-- Scrum of Azeroth by DinX: "Upgrade" label for quest reward items.
-- Compares item level and the class's main stat with what is equipped in that
-- slot. Display only: nothing is ever equipped or chosen.
local _, ns = ...
local SoA = ns.SoA
local num, str, flag, try = SoA.num, SoA.str, SoA.flag, SoA.try

local U = SoA:NewModule("Upgrade")

local ILVL_MARGIN = 3

local SLOTS = {
	INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
	INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
	INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
	INVTYPE_WEAPON = { 16 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
	INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_SHIELD = { 17 },
	INVTYPE_RANGED = { 16 }, INVTYPE_RANGEDRIGHT = { 16 },
}

local STAT_KEYS = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", nil, "ITEM_MOD_INTELLECT_SHORT" }
local STAT_NAMES = { "Strength", "Agility", nil, "Intellect" }

-- Main stat of the character: the highest of Strength, Agility, Intellect.
local function mainStat()
	local best, bestV = 4, -1
	if UnitStat then
		for _, i in ipairs({ 1, 2, 4 }) do
			local _, v = try(UnitStat, "player", i)
			v = num(v)
			if v and v > bestV then best, bestV = i, v end
		end
	end
	return best
end

local function itemLevel(link)
	if C_Item and C_Item.GetDetailedItemLevelInfo then
		local v = num((try(C_Item.GetDetailedItemLevelInfo, link)))
		if v then return v end
	end
	if GetDetailedItemLevelInfo then return num((try(GetDetailedItemLevelInfo, link))) end
end

local function stats(link)
	local fn = (C_Item and C_Item.GetItemStats) or GetItemStats
	local t = fn and try(fn, link)
	return type(t) == "table" and t or nil
end

local function equipLoc(link)
	local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if not fn then return end
	local _, _, _, loc = try(fn, link)
	return str(loc)
end

-- Compare one reward link; returns a result table when it is clearly better.
local function compare(link)
	local loc = equipLoc(link)
	local slots = loc and SLOTS[loc]
	if not slots then return end
	local newIlvl = itemLevel(link)
	if not newIlvl then return end
	local stat = mainStat()
	local key = STAT_KEYS[stat]
	local ns2 = stats(link)
	local newStat = ns2 and key and num(ns2[key], 0) or nil
	-- against the weaker of two ring / trinket slots
	local worst
	for _, slot in ipairs(slots) do
		local cur = GetInventoryItemLink and str(try(GetInventoryItemLink, "player", slot))
		local curIlvl = cur and itemLevel(cur) or 0
		local cs = cur and stats(cur)
		local curStat
		if not cur then curStat = 0 elseif cs and key then curStat = num(cs[key], 0) end
		if not worst or curIlvl < worst.ilvl then worst = { ilvl = curIlvl, stat = curStat, link = cur, slot = slot } end
	end
	if not worst then return end
	if newIlvl < worst.ilvl + ILVL_MARGIN and worst.link then return end
	if newStat and worst.stat and newStat < worst.stat then return end
	if newStat == 0 and (worst.stat or 0) > 0 then return end
	return { link = link, ilvl = newIlvl, oldIlvl = worst.ilvl, stat = newStat, oldStat = worst.stat,
		statName = STAT_NAMES[stat], oldLink = worst.link }
end

local cache = {} -- questID -> result or false (per refresh)
local gen = 0

-- Best upgrade among a quest's reward and choice items, or nil.
function U:ForQuest(questID)
	local c = cache[questID]
	if c ~= nil and c.gen == gen then return c.res or nil end
	local best
	local function check(kind, n)
		local infoFn = kind == "choice" and GetQuestLogChoiceInfo or GetQuestLogRewardInfo
		for i = 1, n do
			-- the info call takes the questID; skip items the character cannot use
			local _, _, _, _, usable, itemID
			if infoFn then _, _, _, _, usable, itemID = try(infoFn, i, questID) end
			itemID = num(itemID)
			local link = GetQuestLogItemLink and str(try(GetQuestLogItemLink, kind, i, questID))
			-- older builds read the selected quest: only trust a link of the same item
			if link and itemID and not link:find("item:" .. itemID .. ":", 1, true) then link = nil end
			if not link and itemID then link = "item:" .. itemID end
			if usable ~= nil and not SoA.IsSecret(usable) and not usable then link = nil end
			if link then
				local r = compare(link)
				if r and (not best or r.ilvl > best.ilvl) then best = r end
			end
		end
	end
	if GetNumQuestLogChoices then check("choice", num((try(GetNumQuestLogChoices, questID, true))) or 0) end
	if GetNumQuestLogRewards then check("reward", num((try(GetNumQuestLogRewards, questID))) or 0) end
	cache[questID] = { gen = gen, res = best or false }
	return best
end

function U:Tooltip(tt, r)
	if not (tt and r) then return end
	local L = SoA.L
	tt:AddLine(L["Upgrade: %s"]:format(r.link), 0.3, 0.9, 0.3)
	tt:AddLine(L["Item level %d (now %d)"]:format(r.ilvl, r.oldIlvl or 0), 1, 1, 1)
	if r.statName and r.stat then
		tt:AddLine(L["%s %d (now %d)"]:format(L[r.statName], r.stat, r.oldStat or 0), 1, 1, 1)
	end
end

function U:OnEnable()
	local function bump() gen = gen + 1 SoA:Fire("MODEL_DIRTY") end
	SoA:On("PLAYER_EQUIPMENT_CHANGED", bump)
	SoA:On("GET_ITEM_INFO_RECEIVED", function() SoA:Throttle("upgrade-items", 2, bump) end)
	SoA:On("QUEST_LOG_UPDATE", function() SoA:Throttle("upgrade-log", 5, function() gen = gen + 1 end) end)
end
