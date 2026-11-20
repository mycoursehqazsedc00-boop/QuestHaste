# QuestHaste (Patched for WoW 1.12 / Turtle WoW)

> Fast quest accept, turn-in, and hands-off or hold-key auto-repeat for repeatable quests, with per-quest reward item selection.

## Client Mods Used
| Mod | Purpose in this addon | Required? |
|---|---|---|
| ClassicAPI | Detects `CLASSIC_API_VERSION` at `PLAYER_LOGIN` to select the 7-field/6-field `GetGossipAvailableQuests`/`GetGossipActiveQuests` signatures and `SetColorTexture` when present, falling back to stock 1.12 APIs when absent. | Optional |

## Features
- **Quest Saving & Auto-Repeat:** Save quests for auto-accept/auto-complete (`Ctrl`), or flag them for full auto-repeat (`Ctrl+Shift`, `Shift+Click` in gossip/greeting lists, or `/qhaste repeat`).
- **Hold-Key + Click NPC Mode (`/qhaste hold`):** Optional mode where repeat-flagged (and saved) quests only auto-finish/auto-repeat while you hold a chosen modifier key (`shift`, `ctrl`, or `alt`) when clicking the NPC, using a short sequence latch so the full dialog chain completes smoothly.
- **Saved Reward Item Selection:** On multi-choice `QUEST_COMPLETE` screens, **Right-Click** any reward item (or use `/qhaste reward <index>`) to mark it with a gold `[AUTO]` badge. Future auto-repeats and Hold-Key turn-ins automatically pick the matching item by item ID / name and refuse to auto-complete if the saved item is not found.
- **Frame-Deferred Action Queue (`/qhaste delay`):** Defers `SelectGossip*`, `AcceptQuest`, `CompleteQuest`, and `GetQuestReward` by `0.05s` (configurable, `0` for instant) with duplicate-event suppression and table reuse to prevent FPS hitches during rapid quest turn-ins.
- **Debug Tracing (`/qhaste trace`):** Timestamped chat trace logging for diagnosing event flow, hold-key state, reward matching, and scheduled actions.

## What Was Added / Improved
- **Added:** Hold-Key + Click NPC auto-finish mode (`/qhaste hold [on|off|shift|ctrl|alt]`) with sequence latching and modifier-conflict protection.
- **Added:** Per-quest reward item marking (`Right-Click` on `QuestRewardItem1..10` with `[AUTO]` badge and tooltip hint, plus `/qhaste reward [index|clear]`), matched by item ID and name across `QUEST_COMPLETE` and `/qhaste complete`.
- **Added:** Frame-deferred `OnUpdate` action scheduler (`/qhaste delay <sec>`) and `QUEST_COMPLETE` duplicate-event guard to mitigate sudden FPS drops on auto-completion.
- **Added:** `/qhaste trace` debug logging and `PLAYER_LOGIN` ClassicAPI feature detection.
- **Improved:** Replaced `32 × N` `strfind` scans in `menuHandler` with O(1) direct table lookup first, reused gossip/greeting arrays instead of allocating per event, and converted code to Lua 5.0-safe syntax (`table.getn`, `arg1`, `this`).
- **Fixed:** Removed the incomplete-active-quest loop in `menuHandler` that previously re-opened incomplete repeat-flagged quests on every `GOSSIP_SHOW` / `QUEST_GREETING`.

## Usage

### Quest Opening / Progress Modifiers
| Modifier | Action |
| :---: | --- |
| Control | Auto complete/accept and save |
| Control+Shift | Auto complete/accept, save, and **auto-repeat** |
| Alt | Forget quest (clears save, repeat, and saved reward) |
| Shift | Complete/accept if not saved, hold if saved |
| None | Complete/accept if saved (or auto-repeat if Hold-Key mode is off) |

*(When Hold-Key mode is enabled, holding the configured `holdKey` prioritizes auto-finishing marked quests instead of triggering its edit/forget action.)*

### Gossip / Greeting List Modifiers
| Modifier | Action |
| :---: | --- |
| Shift+Click quest name | Toggle auto-repeat for that quest |
| Alt+Click saved quest name | Forget quest (save + repeat + reward) |
| Shift (held) | Auto complete/accept a quest in the list |

### Reward Item Selection (`QUEST_COMPLETE`)
| Action | Effect |
| :---: | --- |
| Right-Click reward item | Mark/unmark that item for future auto-repeats (`[AUTO]` badge) |

### Chat Commands (`/qhaste`, `/questhaste`)
| Command | Action |
| --- | --- |
| `/qhaste usage` | Display usage instructions |
| `/qhaste add` | Save current quest |
| `/qhaste repeat` | Toggle auto-repeat on current quest |
| `/qhaste reward [N\|clear]` | Mark reward choice `N` or clear saved reward for current quest |
| `/qhaste hold [on\|off\|shift\|ctrl\|alt]` | Toggle Hold-Key NPC mode or set the hold modifier key |
| `/qhaste delay <sec>` | Set action defer delay in seconds (`0`–`2`, default `0.05`) |
| `/qhaste trace` | Toggle timestamped debug trace logging |
| `/qhaste list` | List all saved quests with accept/complete/repeat/reward state |
| `/qhaste pause` / `resume` | Pause or resume QuestHaste |
| `/qhaste complete` | Complete/accept current quest |
| `/qhaste reset` | Clear all saved quests |

## Credits & License
- Original addon: **WobLight** (QuestHaste)
- Patch / improvements: Hold-Key NPC mode, saved reward item selection, FPS/frame-deferral optimization, Lua 5.0 compatibility, and `/qhaste trace`
- License: Same as original addon unless stated otherwise.
