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
- **Compact tracker**: only when no partner tracker (CasterKit) is shown; with quest item buttons.

Display only: it never accepts, turns in, abandons, casts, moves or equips anything, and never moves a card by itself.

## With CasterKit

Optional. With CasterKit loaded, CasterKit's locked quest route **is** the sprint, the tracker groups quests by epic, shows a sprint line, priority markers and shared-mob links, and board clicks use CasterKit's arrow and GPS. All SoA settings are on the "Scrum of Azeroth" page of CasterKit's settings. All of this goes through `Bridge_CasterKit.lua`.

## Commands

- `/soa` or `/soa board`: quest board
- `/soa config`: settings
- `/soa sprint`: start a new sprint

## API for other add-ons

`ScrumOfAzeroth.API` (with a `version` field). Callbacks via CallbackHandler-1.0: `SOA_SPRINT_CHANGED`, `SOA_TICKET_STATUS`, `SOA_PRIORITY_CHANGED`.

## Saved data

`ScrumOfAzerothDB` and `ScrumOfAzerothCharDB` carry a `schemaVersion`; timestamps are `time()` seconds; fights, walks, sprints (`review.history`), sessions (`review.sessions`) and tickets (`tickets.list`) are arrays of records.

Languages: English and Dutch (follows the game client, CasterKit's language, or the setting).
