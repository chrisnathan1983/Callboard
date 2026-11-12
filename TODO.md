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
- [ ] **P2: Make the F1 live overlay debug-only.** Guard it with `OS.is_debug_build()` and keep it out of release exports.
- [ ] **P2: Split `Callboard` (~900 lines).** Extract the undo/redo history, the connections panel, the context menu, and overlay layout into their own classes. History in particular can be unit tested in isolation.

## Runtime behavior

- [x] **P1: Define re-entry for rules.** Per-rule `Ignore` (default), `Restart`, and `Queue` policies are implemented and covered by unit and editor smoke tests. `Parallel` remains unsupported.
- [x] **P1: Define one-shot behavior on cancellation.** A one-shot latches at rule start and stays latched if `cancel_if` cancels the run. This is documented and unit tested.
- [ ] **P1: Resolve one-shot rules with Restart or Queue.** A one-shot latch is set on the first start, so later triggers are rejected before the configured re-entry policy can apply. Disable incompatible policies in the inspector or define how active runs should accept those triggers.
- [ ] **P1: Fix `Blackboard.write` undeclared-key behavior.** `assert(schema.has(key) or OS.is_debug_build() == false, ...)` only runs in debug builds, so in release an undeclared key silently writes to `local`. Pick one behavior (always error, or always warn and ignore).
- [ ] **P1: Make `StagingVerbs.light()` respect cancellation and Restart.** Its delayed off callback checks only the engine generation, so a cancelled or restarted run can still turn off a light owned by the newer run. Capture the rule and check `engine.alive(rule, token)` before applying the delayed change.
- [ ] **P1: Validate scene-placed Stage props.** Editor analysis builds a bare script instance outside the SceneTree, so exported or `@onready` props assigned in a `.tscn` may be null. Make Stage definitions available to preview validation or provide safe placeholders for typed props.
- [ ] **P2: Make `flash` re-entrant.** A second call mid-tween captures the red tint as its "base" color and the prop can end up stuck red. Capture the base color once (e.g. in node meta) and kill any existing tween first.
- [ ] **P2: Fix or document `jump`.** It sets the color to yellow and never restores it. Restore it, or rename/describe it as a permanent change.
- [ ] **P2: Handle non-`StandardMaterial3D` materials** in `flash` and `jump` (currently a null dereference). Skip with a warning, or support `BaseMaterial3D`.
- [ ] **P2: Prevent overlapping speech labels.** `StagingVerbs.say()` can leave multiple `Label3D` nodes at the same position when speech steps overlap. Replace or reuse a named label on the actor.
- [ ] **P3: Cache the owning stage in `TriggerArea` and `BumpProp`.** `_fire` and `_find_stage` walk the parent chain on every call.
- [ ] **P3: Define collision layers and masks.** Name layers for player, triggers, and companions instead of relying on defaults.

## Validation

- [ ] **P2: Allow intentional overlap.** The shared-trigger warning treats overlap as a bug. Add an explicit "parallel is OK" flag on a rule (or pair) to silence it when intended. This pairs with the re-entrancy policy above.
- [ ] **P3: Click a note in the status bar or inspector to select the offending rule.**

## Editor experience

- [ ] **P2: Debounce `analyze()` and update the graph incrementally.** Every edit instantiates the whole stage (including `_build_props()`) and `show_data()` recreates every graph node. Fine now, but it will lag with heavier props. Cache the built stage between edits where possible.
- [ ] **P2: Avoid rebuilding the graph during a numeric drag.** Each `SpinBox` tick currently reanalyzes the Stage and recreates every graph node and wire. Update the selected node row during the gesture, then validate and refresh when it ends.
- [ ] **P2: Cache regexes used by compilation and renaming.** `StageDefinition._build_step()`, `ExprText.parse_literal()`, and `RuleConnections.rename()` compile regular expressions repeatedly in editor hot paths.
- [ ] **P2: Live debugging tools.** In live mode, add a "fire this call" button, a rule-fired history with step-level trace, and a list of pending delays and loops.
- [ ] **P3: Expose a public `is_dirty()`** on `Callboard`. `plugin.gd` currently reads the private `_dirty`.

## Code quality

- [ ] **P3: Add static types where they are missing**, such as `GameHud.manager` (type it as `GameManager`) and `Props.trigger_box`'s `ctx := {}` (type it as `Dictionary`).
- [ ] **P3: Restructure `editor_smoke.gd`.** One very long `_initialize` with shared mutable state makes failures hard to localize. Split it into independent test functions with their own fixtures, or adopt GdUnit4 or GUT if the suite keeps growing.
- [ ] **P3: Add tests for the new behaviors above** (re-entrancy policy, cancellation and one-shot, `flash` re-entry, undeclared-key writes, migration).

## Docs

- [x] **P2: Document runtime semantics in the README:** one-shot latching, cancellation, re-entry, and the relay/Call distinction.
- [ ] **P3: Add an architecture section** (runtime vs. editor split, data flow from `.tres` to engine) once the layering work is done.
