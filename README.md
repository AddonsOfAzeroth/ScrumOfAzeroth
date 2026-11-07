# Scrum of Azeroth

Agile questing for World of Warcraft (WoW Forever client, interface 16001). By DinX.

- **Epics**: questlines (`C_QuestLine`), campaigns (`C_CampaignInfo`, shown as initiatives) and zone stories (Loremaster-style achievements, found at runtime). Quests without a line or story are "Loose tasks".
- **Quest board** (`/soa`): Kanban (To do, In progress, Ready, Done), Scrum (a sprint with a backlog of "In your log", "Available" and "Upcoming") or List (a sortable, groupable table).
- **Details**: a click on a card opens the issue view (docked at the board or as a window): Overview (quest text, objectives, rewards, epic steps, where, actions), Stats (fights, DPS, downtime, efficiency tips) and History (a Jira-like timeline). Fights and walks can be moved or split by hand.
- **Activity**: per quest and per epic: fights (from the built-in damage meter, read only), walking, downtime, deaths and XP. No combat log.
- **Sprints**: sprint goal, committed and delivered effort, capacity, "Plan sprint", burndown, sprint review with combat stats, velocity and a zone-story roadmap.
- **Estimates**: minutes per quest from walking, kills, drops, clicks and progress bars, learned from your own play. Shown as a range.
- **Priorities**: Jira-style, automatic (XP per minute, chain value, difficulty, upgrades, blockers) or set by hand.
- **Flow**: manual status moves (afterwards automatic moves only go forward until "Resume automatic"), toasts, "Put on hold?" hints, shared-mob quests linked or grouped.
- **Dungeons & raids**: a dungeon or raid is an epic, a run is a short sprint. Entering an instance starts a run by itself with one card per boss (from the Encounter Journal) plus a Trash card; the next boss is always In progress, a kill moves it to Done with its time and your best. Clearing every boss ends the run with the clear time and a personal-best check; leaving for more than 30 minutes ends it unfinished. Quests whose objectives are inside a dungeon get its name as a badge and also count for the dungeon's epic; the dungeon details show a pick-up list (quests seen there before that are not in your log yet), the bosses with best kill times, last runs, trash share and the raid lockout of this week. Read-only: GetInstanceInfo, ENCOUNTER_START/END, the Encounter Journal and saved instances.
- **Flow view** (`/soa flow`, the board's Flow button, or "Show flow" on a card or in the details): a zoomable, pannable node graph of an epic (questline) or initiative (campaign). The main line runs in questline order; side branches come from quests shared by two questlines, campaign chapters and follow-ups learned from your own play (dashed; right-click to remove). Nodes show status, level, progress and the estimate or actual time; a click opens the details, shift-click adds a GPS stop. Fit, zoom with the mouse wheel, drag to pan, minimap in the corner. Never rebuilt in combat.
- **Compact tracker**: only when no partner tracker (CasterKit) is shown; with quest item buttons.

Display only: it never accepts, turns in, abandons, casts, moves or equips anything, and never moves a card by itself.

## With CasterKit

Optional. With CasterKit loaded, CasterKit's locked quest route **is** the sprint, the tracker groups quests by epic, shows a sprint line, priority markers and shared-mob links, and board clicks use CasterKit's arrow and GPS. All SoA settings are on the "Scrum of Azeroth" page of CasterKit's settings. All of this goes through `Bridge_CasterKit.lua`.

## Commands

- `/soa` or `/soa board`: quest board
- `/soa flow`: flow view of an epic or initiative
- `/soa config`: settings
- `/soa sprint`: start a new sprint

## API for other add-ons

`ScrumOfAzeroth.API` (with a `version` field; 3 adds `ToggleFlow()` and `OpenFlow(epicKey, focusQuestID)`). Callbacks via CallbackHandler-1.0: `SOA_SPRINT_CHANGED`, `SOA_TICKET_STATUS`, `SOA_PRIORITY_CHANGED`.

## Saved data

`ScrumOfAzerothDB` and `ScrumOfAzerothCharDB` carry a `schemaVersion`; timestamps are `time()` seconds; fights, walks, sprints (`review.history`), sessions (`review.sessions`) and tickets (`tickets.list`) are arrays of records.

Dungeon runs are stored per character in `ScrumOfAzerothCharDB.dungeons`: `runs` (array of `{ id, key, instanceID, mapID, name, kind = "party"|"raid", difficultyID, difficultyName, groupSize, start, finish, duration, complete, bosses = { { encounterID, name, duration, success, wipes, dps, hps, deaths } }, trash = { time, pulls }, deaths, xp, money, quests } }`), `best` (`["<key>:<difficultyID>"] = runId`), `lockouts` (`{ name, instanceID, difficultyID, difficultyName, isRaid, reset, bosses = { { name, killed } } }`) and `current`. Boss lists and learned dungeon quests are per account in `ScrumOfAzerothDB.dungeonInfo` and `dungeonQuests`.

Learned flow links are stored per account in `ScrumOfAzerothDB.flow.edges` (`[fromQuestID] = { [toQuestID] = count }`) and `flow.rejected` (links you removed); a link is drawn after 2 observations, or 1 when the questline confirms the order. Flow settings are per character in `ScrumOfAzerothCharDB.flow`.

Languages: English and Dutch (follows the game client, CasterKit's language, or the setting).
