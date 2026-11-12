# TODO

We are renaming the project to Callboard. Classes and files should be renamed to match the new terminology.
Do all of this on a GitHub branch (e.g. `callboard-rename`), not on `main`.

After the rename lands, there is a backlog of correctness, architecture, and editor improvements (Part 2).

---

# Part 1: Rename to Callboard

## Rename map

| Today | New | Kind |
|---|---|---|
| `RuleBoard` | `Callboard` | class |
| `rule_board.gd` | `callboard.gd` | file |
| `Zone` | `Stage` | class |
| `ZoneDefinition` | `StageDefinition` | class + `.tres` header |
| `ZoneSource` | removed (see below) | class |
| `ZonePreview` | `StagePreview` (or removed with the legacy path) | class |
| `Zone01` | `Stage01` | class + node name |
| `zone_script` | `stage_script` | **serialized field** |
| `external_events` | `external_calls` | **serialized field** |
| `once` | `one_shot` | **serialized key** (`Rule.once`, rule dicts) |
| `problems` / `validate()` | `notes` / `check()` | code + dict keys |
| `zone_scene` (GameManager) | `stage_scene` | **serialized** in `game.tscn` |
| `zones/zone_01/` | `stages/stage_01/` | paths |
| `addons/director_blackboard/` | `addons/callboard/` | path |
| `verbs.gd` (declares `StagingVerbs`) | `staging_verbs.gd` | file (name never matched its class) |
| `ZONES_DIR` (`plugin.gd`, `rule_board.gd`) | `STAGES_DIR` | constant |
| `_collect_zone_definition_paths` | `_collect_stage_definition_paths` | method |
| `_validate_zone_name`, `_create_zone_files` | `_validate_stage_name`, `_create_stage_files` | methods |
| `add_event` | `add_call_name` | method |
| "Rule Board" tab | "Callboard" | label |
| CI job "Rule Board smoke test" | "Callboard smoke test" | `.github/workflows/test.yml` |

Unchanged: `Rule`, `RuleEngine`, `RuleValidator`, `RuleGraphView`, `RuleGraphReader`, `RuleInspector` (they all still describe rules), `Group`, `requires`/`forbids`/`cancel_if`, `Blackboard`, `relay`, `trigger`, and `fire()`. `trigger` and `fire()` cover both calls and relays, so they shouldn't take the "call" name.

## Gotchas to settle first

- **Don't use a bare identifier `call`.** It shadows `Object.call()`. Use `external_calls`, `add_call_name()`, `_call_nodes`, and so on.
- **`Stage` has no Godot ClassDB conflict** that we know of, but `plugin.gd` hardcodes `cls == "Zone"` in `_validate_zone_name`. Update that to `"Stage"`, and update the generated template text (`extends Zone`).
- **`ZoneSource` is more than the legacy parser.** Deleting the legacy path is still the right call (it avoids maintaining two grammars through the rename, and FEEDBACK.md already recommends it), but the class also holds helpers the board, inspector, and blackboard panel use. Split it first:
  - `ExprText`: `parse_literal`, `format_literal`, `split_args`, `step_text`.
  - `AuthoredData` (or a new `GraphModel` helper): `unique_name`, `rule_ids`, `new_state_key`, `rename_key`, `names_expr`, `GUARDS`.
  - Delete: `parse`, `generate`, `body_range`, `_parse_*`, `_gen_*`, `FN_VARS`, `FN_RULES`.
- **Deleting the legacy path touches more than `ZoneSource`.** Also remove or rework:
  - `Zone`'s `_legacy_verb` wrappers (`show_node`, `pop`, `light`, ...) and `rule()`/`_build_rules()`.
  - `RuleGraphReader.inspect_script` and the non-`.tres` branch of `read()`.
  - `ZonePreview` (only the legacy path uses it).
  - The non-`.tres` branch of `RuleBoard.save()` and `open_script`'s script branch.
  - `VerbCatalog.from_zone`.
  - The legacy tests: the `ZoneSource` round-trip block in `unit.gd`, the `legacy` fixture in `_test_factory`, and `zone.rule(...)` in `smoke.gd` (replace it with a `Step`-based rule appended to `engine.rules`).
- **Old `.tres` files will crash, not silently drop values.** `ZoneDefinition.apply_graph` indexes `entry["once"]` and `entry["emit"]` directly, so a missing key throws. See the migration step in Commit 2.
- **Don't word-boundary replace `once` or `problems`.** Both appear in prose, test labels, comments, and locals ("Run once", `var problems`). Replace by pattern instead (`"once"`, `.once`, `r.once`, `d["problems"]`, `["problems"]`), then let the tests and a manual grep catch the rest.
- **Tests assert on message fragments and dict keys.** If `problems` becomes `notes`, `editor_smoke.gd` needs its `d["problems"]` updates and `unit.gd` its fragments, and it's better to change those in the same commit. Keep the quoted-id format (`'rule_id'`) in messages, since the inspector filters on it.
- **Constants and locals to watch for in find/replace:** `ZONES_DIR`, `ZONE_PATH`, `ZONE_SCENE_PATH`, `_collect_zone_definition_paths`, locals named `zone`, `zone_tools`, `bind_zone`/`bind_live(zone)`, and `Zone01` in the `.tscn` node name.

## Order of work

**Commit 0: Remove the legacy script backend (before any renaming).**
1. Split `ZoneSource` into `ExprText` and the model helpers as described above.
2. Delete the legacy parser/generator and its callers and tests.
3. Run all three test suites. This is a pure refactor with no renames, so a failure here is easy to bisect.

**Commit 1: Identity.** `project.godot` name, `plugin.cfg`, `_get_plugin_name()` returning "Callboard", and the README title. No behavior change.

**Commit 2: Data migration, done by hand first.**
1. In `zone_01.tres`, rename `zone_script` → `stage_script`, `external_events` → `external_calls`, and every `"once":` → `"one_shot":`.
2. In `game.tscn`, rename `zone_scene` → `stage_scene`.
3. Do this in the same commit as the matching code, or the load will drop values (properties) or throw (dict keys).
4. Add a `StageDefinition._migrate()` that runs before anything reads the data. It should:
   - Copy old property values to the new ones if the new ones are empty. Serialized properties need a `_set` fallback or a `_get_property_list` shim for the old names.
   - Rewrite `"once"` → `"one_shot"` in each rule dict.
   - Fill in missing optional keys (`emit`, `state_key`, `requires`, `forbids`, `cancel_if`) with defaults.
5. Add a `format_version` field to `StageDefinition` and stamp it on save, so future migrations key off a number instead of probing for old names.
6. Add a unit test that loads a fixture `.tres` in the old format and asserts it migrates and validates cleanly.

**Commit 3: Class and file renames.**
1. Close Godot and commit.
2. `git mv` each script together with its `.uid` sidecar, and rename the directories (`zones/` → `stages/`, `zone_01` → `stage_01`, `director_blackboard` → `callboard`, `rule_board.gd` → `callboard.gd`, `verbs.gd` → `staging_verbs.gd`, `zone*.gd` → `stage*.gd`). Moving the `.uid` files keeps references resolving, because Godot looks up by uid first and path second.
3. Find/replace the class names from the map, case-sensitively and with word boundaries. Watch for the constants and locals listed under Gotchas.
4. Update `[editor_plugins]` in `project.godot`, the `preload("res://addons/director_blackboard/...")` paths, and the `class_name` lines.
5. Update `.github/workflows/test.yml` job names.
6. Reopen Godot, let it reimport, and open `stage_01.tres` and the `.tscn` files once so they resave with the new `script_class` header.

**Commit 4: Terms in the UI and API.** "Stage:" picker label, "+ Call", "One-shot (latched, persists)", "Notes" in the inspector and status bar, "Create New Stage...", the HUD hints ("R: reset the stage", "X: strike the show"), the "Latched once-rules" label in `BlackboardPanel`, and renames like `add_event` → `add_call_name`. Then update the tests and run all three.

**Commit 5: Docs.** Rewrite the README around Callboard, Stage, Call, One-shot, and Notes, with a short glossary and a "Formerly Director Blackboard / Rule Board" line. Update FEEDBACK.md and this file, where the `Zone` split is now the `Stage` split.

## Verification

After each commit, run the headless import and all three test scripts from the README. After commit 3, also check that:
- the live F1 overlay shows the stage's rules,
- "Create New Stage..." generates a stage that loads,
- the old-format fixture from Commit 2 still migrates.

---

# Part 2: Improvements backlog (after the rename)

Priorities: **P1** correctness or things that block other work, **P2** worthwhile, **P3** nice to have.

## Data model and architecture

- [ ] **P1: Replace dictionaries with typed resources.** Rules, steps, variables, and groups are untyped dicts with magic string keys. Introduce `RuleData`, `StepData`, `VariableData`, and `GroupData` resources. Benefits: inspector support, cleaner `.tres` diffs, fewer runtime typos, and cheaper schema changes (this rename would have been mostly mechanical). Undo snapshots can keep using `duplicate(true)`. Do this right after the rename, and bring `format_version` and `_migrate()` along.
- [ ] **P2: Break the circular layering.** `core/` currently depends on `model/` (`StageDefinition` uses `step_text` and `VerbCatalog`), and the runtime HUD instantiates the editor's `Callboard`. Split the addon into runtime (`Stage`, `Blackboard`, `RuleEngine`, `Rule`, `Step`, verbs, definition) and editor (`Callboard`, graph view, inspector, plugin), so exports can strip editor code.
- [ ] **P2: Make the F1 live overlay debug-only.** Guard it with `OS.is_debug_build()` and keep it out of release exports.
- [ ] **P2: Split `Callboard` (~900 lines).** Extract the undo/redo history, the connections panel, the context menu, and overlay layout into their own classes. History in particular can be unit tested in isolation.

## Runtime behavior

- [ ] **P1: Define re-entrancy for rules.** Nothing stops one rule from running concurrently with itself. `repeat_emit` started by two `arrive` fires gives two tick loops (and `smoke.gd` calls `activate()` twice). Add a per-rule policy (`ignore`, `restart`, `queue`, `parallel`) with a documented default, and test it.
- [ ] **P1: Decide what one-shot means on cancellation.** The latch is set at rule start, so a rule cancelled mid-flight by `cancel_if` stays latched. Document this as intended, or add a "latch on completion" option, and test the chosen behavior.
- [ ] **P1: Fix `Blackboard.write` undeclared-key behavior.** `assert(schema.has(key) or OS.is_debug_build() == false, ...)` only runs in debug builds, so in release an undeclared key silently writes to `local`. Pick one behavior (always error, or always warn and ignore).
- [ ] **P2: Make `flash` re-entrant.** A second call mid-tween captures the red tint as its "base" color and the prop can end up stuck red. Capture the base color once (e.g. in node meta) and kill any existing tween first.
- [ ] **P2: Fix or document `jump`.** It sets the color to yellow and never restores it. Restore it, or rename/describe it as a permanent change.
- [ ] **P2: Handle non-`StandardMaterial3D` materials** in `flash` and `jump` (currently a null dereference). Skip with a warning, or support `BaseMaterial3D`.
- [ ] **P3: Cache the owning stage in `TriggerArea` and `BumpProp`.** `_fire` and `_find_zone` walk the parent chain on every call.
- [ ] **P3: Define collision layers and masks.** Name layers for player, triggers, and companions instead of relying on defaults.

## Validation

- [ ] **P2: Allow intentional overlap.** The shared-trigger warning treats overlap as a bug. Add an explicit "parallel is OK" flag on a rule (or pair) to silence it when intended. This pairs with the re-entrancy policy above.
- [ ] **P3: Click a note in the status bar or inspector to select the offending rule.**

## Editor experience

- [ ] **P2: Debounce `analyze()` and update the graph incrementally.** Every edit instantiates the whole stage (including `_build_props()`) and `show_data()` recreates every graph node. Fine now, but it will lag with heavier props. Cache the built stage between edits where possible.
- [ ] **P2: Live debugging tools.** In live mode, add a "fire this call" button, a rule-fired history with step-level trace, and a list of pending delays and loops.
- [ ] **P3: Expose a public `is_dirty()`** on `Callboard`. `plugin.gd` currently reads the private `_dirty`.

## Code quality

- [ ] **P3: Add static types where they are missing**, such as `GameHud.manager` (type it as `GameManager`) and `Props.trigger_box`'s `ctx := {}` (type it as `Dictionary`).
- [ ] **P3: Restructure `editor_smoke.gd`.** One very long `_initialize` with shared mutable state makes failures hard to localize. Split it into independent test functions with their own fixtures, or adopt GdUnit4 or GUT if the suite keeps growing.
- [ ] **P3: Add tests for the new behaviors above** (re-entrancy policy, cancellation and one-shot, `flash` re-entry, undeclared-key writes, migration).

## Docs

- [ ] **P2: Document runtime semantics in the README:** one-shot latching, cancellation, re-entrancy, and the relay/call distinction.
- [ ] **P3: Add an architecture section** (runtime vs. editor split, data flow from `.tres` to engine) once the layering work is done.