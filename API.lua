-- Scrum of Azeroth by DinX: public API for other add-ons (CasterKit, Roads of Azeroth, ...).
--   ScrumOfAzeroth.API.version
--   API.RegisterCallback(owner, event, method) / API.UnregisterCallback(owner, event)
--   events: SOA_SPRINT_CHANGED, SOA_TICKET_STATUS (key, status), SOA_PRIORITY_CHANGED
local _, ns = ...
local SoA = ns.SoA

local API = { version = 1 }
SoA.API = API

local CBH = LibStub and LibStub("CallbackHandler-1.0", true)
if CBH then
	SoA.callbacks = CBH:New(API, "RegisterCallback", "UnregisterCallback", "UnregisterAllCallbacks")
else
	-- tiny fallback registry
	local reg = {}
	function API.RegisterCallback(owner, event, method)
		reg[event] = reg[event] or {}
		reg[event][owner] = method or event
	end
	function API.UnregisterCallback(owner, event) if reg[event] then reg[event][owner] = nil end end
	SoA.callbacks = { Fire = function(_, event, ...)
		for owner, m in pairs(reg[event] or {}) do
			if type(m) == 'function' then
				pcall(m, event, ...)
			elseif type(owner) == 'table' and type(owner[m]) == 'function' then
				pcall(owner[m], owner, event, ...)
			end
		end
	end }
end

local function fire(event, ...)
	if SoA.callbacks then pcall(SoA.callbacks.Fire, SoA.callbacks, event, ...) end
end
SoA:Listen("SPRINT", function() fire("SOA_SPRINT_CHANGED") end)
SoA:Listen("PRIORITY", function() fire("SOA_PRIORITY_CHANGED") end)
SoA:Listen("TICKET_STATUS", function(key, status) fire("SOA_TICKET_STATUS", key, status) end)

function API.ToggleBoard() SoA:ToggleBoard() end
function API.ToggleConfig() SoA:ToggleConfig() end

function API.IsSprintActive() return SoA.Sprint:IsActive() end
function API.IsInSprint(key) return SoA.Sprint:Contains(key) end
function API.AddToSprint(key) return SoA.Sprint:Add(key) end
function API.RemoveFromSprint(key) return SoA.Sprint:Remove(key) end
function API.NewSprint() SoA.Sprint:NewSprint() end

-- Sprint status from the last built model: items, doneItems, committed,
-- delivered, remaining (minutes), xpCommitted, xpDelivered, xpRemaining, goal
function API.GetSprintStatus()
	return SoA.Sprint:Status(SoA.Model:Peek() or false)
end

-- Cached values only (safe to call from a route planner).
function API.GetPriority(questID)
	local m = SoA.Model:Peek()
	local it = m and m.byKey[questID]
	return it and it.priority or nil
end

function API.IsOnHold(key) return SoA.char ~= nil and SoA.Hold:Get(key) ~= nil end

function API.GetEpic(questID)
	if not SoA.char then return end
	local e = SoA.Epics:Get(questID)
	if e then return { key = e.key, name = e.name, color = e.color, done = e.done, total = e.total, tag = e.tag } end
end

function API.GetEstimate(questID)
	local m = SoA.Model:Peek()
	local it = m and m.byKey[questID]
	return it and it.est or nil
end
