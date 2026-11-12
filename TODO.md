# TODO

We are renaming the project to Callboard. Additionally, classes and files should be renamed to match the new terminology.
Create a github branch to do this.

## Rename map

| Today | New | Kind |
|---|---|---|
| `RuleBoard` | `Callboard` | class |
| `Zone` | `Stage` | class |
| `ZoneDefinition` | `StageDefinition` | class + `.tres` header |
| `ZoneSource` | `StageSource` | class |
| `ZonePreview` | `StagePreview` | class |
| `Zone01` | `Stage01` | class + node name |
| `zone_script` | `stage_script` | **serialized field** |
| `external_events` | `external_calls` | **serialized field** |
| `once` | `one_shot` | **serialized key** (`Rule.once`, rule dicts) |
| `problems` / `validate()` | `notes` / `check()` | code + dict keys |
| `zone_scene` (GameManager) | `stage_scene` | **serialized** in `game.tscn` |
| `zones/zone_01/` | `stages/stage_01/` | paths |
| "Rule Board" tab | "Callboard" | label |

Unchanged: `Rule`, `RuleEngine`, `RuleValidator`, `RuleGraphView`, `RuleGraphReader`, `RuleInspector` (they all still describe rules), `Group`, `requires`/`forbids`/`cancel_if`, `Blackboard`, `relay`, `trigger`, and `fire()`. `trigger` and `fire()` cover both calls and relays, so they shouldn't take the "call" name.

## Gotchas to settle first

- **Don't use a bare identifier `call`.** It shadows `Object.call()`. Use `external_calls`, `add_call_name()`, `_call_nodes`, and so on.
- **`Stage` has no Godot ClassDB conflict** that I know of, but `plugin.gd` hardcodes `cls == "Zone"` in `_validate_zone_name`. Update that to `"Stage"`, and update the generated template text (`extends Zone`).
- **The legacy script backend** (`ZoneSource` grammar) parses `r.once = true` literally. Renaming `once` to `one_shot` changes that grammar. Since FEEDBACK.md already recommends dropping the legacy path, I'd delete it now and move `parse_literal`, `format_literal`, and `step_text` into a small `ExprText` utility. That avoids maintaining two grammars through a rename.
- **Tests assert on message fragments and dict keys.** If `problems` becomes `notes`, `editor_smoke.gd` needs its `d["problems"]` updates and `unit.gd` its fragments, and it's better to change those in the same commit. Keep the quoted-id format (`'rule_id'`) in messages, since the inspector filters on it.

## Order of work

**Commit 1: Identity.** `project.godot` name, `plugin.cfg`, `_get_plugin_name()` returning "Callboard", and the README title. No behavior change.

**Commit 2: Data migration, done by hand first.** In `zone_01.tres`, rename `zone_script` → `stage_script`, `external_events` → `external_calls`, and every `"once":` → `"one_shot":`. In `game.tscn`, rename `zone_scene` → `stage_scene`. Do this in the same commit as the matching code, or the load will drop values without an error. Also add a one-time fallback in `StageDefinition` (read the old key if the new one is missing) if you expect other people to have existing `.tres` files.

**Commit 3: Class and file renames.**
1. Close Godot and commit.
2. `git mv` each script together with its `.uid` sidecar, and rename the directories (`zones/` → `stages/`, `zone_01` → `stage_01`, `director_blackboard` → `callboard`, `rule_board.gd` → `callboard.gd`, `zone*.gd` → `stage*.gd`). Moving the `.uid` files keeps references resolving, because Godot looks up by uid first and path second.
3. Find/replace the class names from the map, case-sensitively and with word boundaries. Watch out for `ZONES_DIR`, `_collect_zone_definition_paths`, locals named `zone`, and `Zone01` in the `.tscn` node name.
4. Update `[editor_plugins]` in `project.godot` and the `class_name` lines.
5. Reopen Godot, let it reimport, and open `stage_01.tres` and the `.tscn` files once so they resave with the new `script_class` header.

**Commit 4: Terms in the UI and API.** "Stage:" picker label, "+ Call", "One-shot (latched, persists)", "Notes" in the inspector and status bar, "Create New Stage...", the HUD hints ("R: reset the stage", "X: strike the show"), and renames like `add_event` → `add_call_name`. Then update the tests and run all three.

**Commit 5: Docs.** Rewrite the README around Callboard, Stage, Call, One-shot, and Notes, with a short glossary and a "Formerly Director Blackboard / Rule Board" line. Update FEEDBACK.md and TODO.md, where the `Zone` split is now the `Stage` split.

## Verification

After each commit, run the headless import and all three test scripts from the README. After commit 3, also check that the live F1 overlay shows the stage's rules and that "Create New Stage..." generates a stage that loads.