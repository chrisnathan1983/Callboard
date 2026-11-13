# Callboard TODO

The Part 1 Callboard rename is implemented on branch `callboard-rename`. The remaining backlog follows.

## Completed follow-ups verified

- [x] Player input uses InputMap actions; overlapping stuns keep the longest duration; interaction chooses the nearest eligible area. Covered by `tests/smoke.gd`.
- [x] `BumpProp` uses the public `Stage.fire_relay_once()` API and an exported Area reference.
- [x] Renaming a rule preserves its one-shot latch across save and reload. Covered by `tests/editor_smoke.gd`.
- [x] Calls and relays can be renamed and deleted in Callboard. Covered by `tests/editor_smoke.gd`.
- [x] No unused `item_id` delivery payload remains in the current source.

# Remaining backlog

Priorities: **P1** correctness or things that block other work, **P2** worthwhile, **P3** nice to have.

## Data model and architecture

- [ ] **P1: Replace dictionaries with typed resources.** Rules, steps, variables, and groups are untyped dictionaries with magic string keys. Introduce `RuleData`, `StepData`, `VariableData`, and `GroupData` resources for inspector support, cleaner `.tres` diffs, fewer runtime typos, and cheaper schema changes. Undo snapshots can keep using `duplicate(true)`. Preserve `StageDefinition.format_version` and `_migrate()` during the conversion.
- [ ] **P2: Break the circular layering.** `core/` currently depends on `model/` (`StageDefinition` uses `step_text` and `VerbCatalog`), and the runtime HUD instantiates the editor's `Callboard`. Split the addon into runtime (`Stage`, `Blackboard`, `RuleEngine`, `Rule`, `Step`, verbs, definition) and editor (`Callboard`, graph view, inspector, plugin), so exports can strip editor code.
- [ ] **P2: Make the F1 live overlay debug-only.** It is now guarded with `OS.is_debug_build()`; confirm editor addon code is excluded from release exports as part of the runtime/editor split.
- [ ] **P2: Split `Callboard` (~900 lines).** Extract the undo/redo history, the connections panel, the context menu, and overlay layout into their own classes. History in particular can be unit tested in isolation.

## Runtime behavior

- [x] **P1: Define re-entry for rules.** Per-rule `Ignore` (default), `Restart`, and `Queue` policies are implemented and covered by unit and editor smoke tests. `Parallel` remains unsupported.
- [x] **P1: Define one-shot behavior on cancellation.** A one-shot latches at rule start and stays latched if `cancel_if` cancels the run. This is documented and unit tested.
- [x] **P1: Resolve one-shot rules with Restart or Queue.** The inspector disables both policies for one-shot rules, coerces a changed one-shot rule to Ignore, and validation rejects incompatible authored data.
- [x] **P1: Fix `Blackboard.write` undeclared-key behavior.** Undeclared writes now always report an error and return without changing local state or emitting `changed`.
- [x] **P1: Make `StagingVerbs.light()` respect cancellation and Restart.** Its delayed callback captures the owning rule and generation and checks `engine.alive()` before changing the light.
- [x] **P1: Validate scene-placed Stage props.** Analysis now instantiates the sibling Stage scene when available, so exported and `@onready` scene references resolve. Covered by a fixture in `tests/fixtures/assigned_prop_stage.tscn`.
- [x] **P2: Make `flash` re-entrant.** The original material color is retained and an existing tint tween is stopped before another flash starts.
- [x] **P2: Fix or document `jump`.** Jump now restores the original material color after the effect.
- [x] **P2: Handle non-`StandardMaterial3D` materials** in `flash` and `jump`. Both effects accept `BaseMaterial3D` and skip unsupported overrides with a warning.
- [x] **P2: Prevent overlapping speech labels.** `say()` reuses one named label and replaces its active timeout.
- [x] **P3: Cache the owning stage in `TriggerArea` and `BumpProp`.** Each resolves its stage once on ready and reuses the reference.
- [x] **P3: Define collision layers and masks.** Project layer names and player, trigger, and companion masks are explicit.

## Validation

- [x] **P2: Allow intentional overlap.** A per-rule "Allow simultaneous rules" option suppresses shared-trigger warnings when concurrent runs are intentional.
- [x] **P3: Click a note in the status bar or inspector to select the offending rule.** Clicking the status line cycles through rules named by current validation notes.

## Editor experience

- [ ] **P2: Debounce `analyze()` and update the graph incrementally.** Every edit instantiates the whole stage (including `_build_props()`) and `show_data()` recreates every graph node. Fine now, but it will lag with heavier props. Cache the built stage between edits where possible.
- [x] **P2: Avoid rebuilding the graph during a numeric drag.** Numeric changes record undo snapshots during the gesture; analysis and graph refresh happen on release.
- [x] **P2: Cache regexes used by compilation and renaming.** The step string, literal, and connection-name patterns now compile once per script class.
- [ ] **P2: Live debugging tools.** In live mode, add a "fire this call" button, a rule-fired history with step-level trace, and a list of pending delays and loops.
- [x] **P3: Expose a public `is_dirty()`** on `Callboard`; the plugin uses the public method.

## Code quality

- [x] **P3: Add static types where they are missing**, including `GameHud.manager` as `GameManager` and `Props.trigger_box`'s context as `Dictionary`.
- [ ] **P3: Restructure `editor_smoke.gd`.** One very long `_initialize` with shared mutable state makes failures hard to localize. Split it into independent test functions with their own fixtures, or adopt GdUnit4 or GUT if the suite keeps growing.
- [x] **P3: Add tests for the new behaviors above** (re-entrancy policy, cancellation and one-shot, `flash` re-entry, undeclared-key writes, migration).

## Docs

- [x] **P2: Document runtime semantics in the README:** one-shot latching, cancellation, re-entry, and the relay/Call distinction.
- [ ] **P3: Add an architecture section** (runtime vs. editor split, data flow from `.tres` to engine) once the layering work is done.
