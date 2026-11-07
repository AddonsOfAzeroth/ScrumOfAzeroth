# Scrum of Azeroth

Agile questing for World of Warcraft (WoW Forever client, interface 16001). By DinX.

- **Epics**: questlines (`C_QuestLine`) and campaigns (`C_CampaignInfo`, shown as initiatives). Quests without a line are "Loose tasks".
- **Quest board** (`/soa`): Kanban (To do, In progress, Ready, Done) or Scrum (a sprint with a backlog of "In your log", "Available" and "Upcoming").
- **Sprints**: sprint goal, committed and delivered effort, capacity, "Plan sprint" (a proposal you accept or cancel), burndown, sprint review and velocity.
- **Estimates**: minutes per quest from walking, kills, drops, clicks and progress bars, learned from your own play (no combat log). Shown as a range.
- **Priorities**: Jira-style, automatic (XP per minute, chain value, difficulty, upgrades, blockers) or set by hand.
- **Blockers, On hold, custom tickets, upgrade labels, level forecast.**

Display only: it never accepts, turns in, casts, moves or equips anything.

## With CasterKit

Optional. With CasterKit loaded, CasterKit's locked quest route **is** the sprint, the tracker groups quests by epic, shows a sprint line and priority markers, and board clicks use CasterKit's arrow and GPS. Settings appear as a page in CasterKit's settings. All of this goes through `Bridge_CasterKit.lua`.

## Commands

- `/soa` or `/soa board`: quest board
- `/soa config`: settings
- `/soa sprint`: start a new sprint

## API for other add-ons

`ScrumOfAzeroth.API` (with a `version` field). Callbacks via CallbackHandler-1.0: `SOA_SPRINT_CHANGED`, `SOA_TICKET_STATUS`, `SOA_PRIORITY_CHANGED`.

Languages: English and Dutch (follows the game client, CasterKit's language, or the setting).
