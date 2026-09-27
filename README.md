# QuestHaste

## Intro:

QuestHaste is a small Addon for World of Warcraft (vanilla 1.12), it allows fast turn in of quests, especially useful for repeatable quests (e.g. Alterac Valley quests). It can now also fully auto-repeat a quest hands-off.

## Usage:

### Quest (active and available) opening/progress modifiers

| Modifier          | Action
| :---:             | ---
| Control           | auto complete/accept and save
| Control+Shift     | auto complete/accept, save, **and auto-repeat** — keeps accepting/turning the quest back in with zero further key presses, until cleared with Alt or `/qhaste repeat`
| Alt               | forget (clears save AND repeat)
| Shift             | complete/accept if not saved, hold if saved
| None              | complete/accept if saved

### Gossip / greeting list modifiers (multi-quest NPC popups)

| Modifier                        | Action
| :---:                           | ---
| Shift+Click a quest's name      | toggle auto-repeat for that quest
| Alt+Click a saved quest's name  | forget it (save + repeat)
| Shift (held, not clicking)      | auto complete/accept a quest in the list<br>(priority: repeat-flagged, completed, available saved, active saved, available, active)

Repeat-flagged quests get a gold highlight in these lists; merely-saved quests get a green-yellow highlight.

### Chat commands (/qhaste, /questhaste)
| Command   | Action
| :---:     |   ---
| usage     | display usage instructions
| add       | saves current quest
| repeat    | toggles auto-repeat on the current quest
| list      | list all saved quests, with accept/complete/repeat state
| pause     | disable QuestHaste
| resume    | activate QuestHaste
| complete  | complete/accept current quest
| reset     | clears all saved quests

### A note on auto-repeat

Auto-repeat automates the accept → hand-in → get-reward cycle for a flagged
quest completely, with no modifier keys needed once it's on. It relies on the
game re-showing the quest dialog for that NPC (which happens automatically
for many repeatable quest hubs); for NPCs that require a fresh click to
re-open dialog each time, you'll still need that one click, but everything
after it — accept, turn in, choose the reward if there's no choice — happens
on its own. There's no way for an addon to script "click on this NPC" itself;
that part is a client (not scriptable) action.

## Change Log:

### Version 0.2
* **New:** auto-repeat — flag a quest (Control+Shift, Shift+Click its name
  in a gossip/greeting list, or `/qhaste repeat`) and QuestHaste will keep
  accepting and turning it back in on its own until you clear the flag.
* **Fix:** `QUEST_GREETING` (the simple multi-quest popup, as opposed to
  full gossip menus) was silently broken — `table.insert` was being called
  with the multiple return values of `GetActiveTitle`/`GetAvailableTitle`
  spread across several arguments, which errors on stock `table.insert`.
  Even set aside the error, the list held bare strings instead of records,
  so none of the saved/priority logic ever actually applied to these NPCs.
* **Fix:** `contained()` compared a whole quest record table to a plain
  title string and was never true, so Alt-clicking a saved *available*
  quest in a gossip list silently failed to forget it.
* **Fix:** `QuestHaste_RemoveAutoAccept` called a function that doesn't
  exist (`QuestHaste_IsComplete`), throwing a Lua error on every Alt-click
  removal of a quest that also had auto-complete saved.
* **Fix:** quest-title matching against the saved list used a Lua pattern
  match, which could mis-match or error on titles containing pattern
  characters (`-`, `(`, `%`, etc). Now uses a plain-text match.
* Removed a dead/unused quest-log scan in the gossip priority logic.
* Bumped `## Interface` to 11200 to match the 1.12 client mods
  (ClassicAPI/SuperWoW/nampower/UnitXP_SP3) this project targets.

### Version 0.1
* Ported to Classic
