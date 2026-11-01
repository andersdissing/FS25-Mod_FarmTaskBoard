# FS25_FarmTaskBoard

A task board per farm for Farming Simulator 25, in the in-game menu (Esc) > **Tasks** ("Opgaver").
It has three columns: Not started, To do and Done. The farm manager can create, edit, drag and
delete tasks. Everyone else on the farm can see the board but not change it. In multiplayer the
server decides every change, and the board is saved with the savegame.

The spec is in [HANDOFF.md](HANDOFF.md) and the approved mockups are in [mockups/](mockups/).

## Layout

| Path | What |
|---|---|
| `Build/` | The mod. `tools/deploy.ps1` zips the contents of this folder |
| `Build/scripts/FarmTaskBoard.lua` | Main file: load and save hooks, local player, farm and role |
| `Build/scripts/FarmTaskBoardData.lua` | Boards and the rules for changing them, the `taskBoard.xml` file, network streams |
| `Build/scripts/FarmTaskBoardSync.lua` | Server-side checks and the events `TaskBoardCreate/Update/Move/Delete/SyncEvent` |
| `Build/scripts/FarmTaskBoardFrame.lua` | The menu tab: board, drag and drop, dialog |
| `Build/scripts/FarmTaskBoardUI.lua` | Small drawing toolkit (rectangles, text, buttons, tooltip) |
| `Build/gui/FarmTaskBoardFrame.xml` | Base game header, plus the game's own text input used in the dialog |
| `Build/translations/l10n_{en,de,fr,da}.xml` | UI texts |
| `tests/check_static.py` | Checks XML, Lua 5.1 syntax, l10n keys in all languages, TestRunner rules (no pcall, lines under 200 characters, icon format) |
| `tests/smoke_test.py` | Runs the mod against a stubbed FS25: single player, multiplayer with a server and two clients, spectator |
| `tools/preview.py` | Draws the board as the stubs see it, to `Docs/preview/*.png` |
| `tools/make_icons.py` | Makes the mod icon and the tab icon as DDS (DXT1) |
| `tools/deploy.ps1` | Builds the zip, copies it to the mods folder and starts the game |
| `tools/release.ps1` | Sets the version, tags the commit and pushes. The GitHub workflow then builds the release |

## Checks

```
pip install luaparser lupa pillow
python tests/check_static.py Build
python tests/smoke_test.py
```
