# Callboard todo

What follows is what I'd still change, most important first. If you only do three things, I'd pick the external-key rename hazard, the single-bad-step metadata wipe, and the `jump` drift. They are the most likely to confuse a user without any visible error.

## Likely bugs

- [_] **`jump` can ratchet a mesh upward.** `StagingVerbs.jump` captures `var y := m.position.y` on every call. If a second jump starts mid-air (Restart policy, or two rules on the same mesh), it captures the raised height as the new "rest" position, and the first tween is still running on the same property. Store the base Y in node meta, as `flash` does for color, and kill the previous tween. `move_to` has the same concurrent-tween problem.
- [_] **Renaming a local Blackboard variable silently breaks external writers.** `_saved_names` is only populated for `saved` scope. `treat_out` is local and listed in `external_vars`. If a designer renames it, `BumpProp` calls `fire_relay_once`, `bb.has(latch)` fails, and it returns `false` with no message. `rename_key` also never updates `external_vars`. Either alias every scope, or block or warn on renaming externally written keys.
- [_] **Renaming an external Call or relay has the same problem.** `BumpProp.relay` and `TriggerArea.event` keep the old name and nothing listens. The README warns about this, but you can catch it cheaply. In debug builds, make `Stage.fire()` and `fire_relay_once()` `push_warning` when the event is neither declared nor emitted by any rule, or when the latch key is missing.
- [_] **One invalid step blanks the relay metadata for every rule.** `apply_graph` only appends rules to the engine if `problems` is empty. `_read_results` then clears every `emits`/`sets` entry and refills them from `engine.rules`, which is now empty. A typo in one argument makes all step-emitted relay ports and wires vanish until it's fixed, and `edit_error` then blocks relay edits. Build valid rules into the analysis result regardless, and report the invalid ones separately.

## Design hazards

- [_] **Cancelled timed lights stay on.** `light()` skips its delayed off if `engine.alive()` is false, and a unit test locks that behavior in. `LIGHT_ACTIVATION_META` already handles stale timers from retriggers, so only the deactivation-generation check seems necessary. As written, `cancel_if` during a timed light leaves `lamp_on` true until something else clears it. In Stage 01, `z1_calm` happens to turn the lamp off, so the sample hides this. Decide whether cancellation should revert, complete, or abandon the effect, and document that.
- [_] **No runtime guard against relay recursion.** The validator flags cycles, but `activate()` only logs them. With Queue re-entry, a synchronous cycle could hang. Add a depth cap in `fire()`, or refuse to activate when cycles exist.
- [_] **Blackboard writes aren't type-checked.** Writing a String to a bool key is accepted. Changing a saved variable's default type in Callboard also leaves stale values of the old type in save data. Consider storing the declared type and coercing or discarding on mismatch.
- [_] **`light()` assumes `_rule` is in the context.** `rule.id` fails if the step is called with `{}`, as the smoke tests do for `flash`. Guard against null.
- [_] **`cancel_all` calls `is_connected` on tracked signals.** Add `not tracked_signal.is_null()` in case the emitter was freed.

## Editor and tooling

- [_] **Possibly mangled characters in `callboard_connections.gd`.** The delete button text is `"?"` and the overflow message reads `".and %d more"`. These look like a mangled `✕` and `…and`, and the `?` suggests literal corruption in the source rather than an export artifact. `blackboard_panel.gd` and `rule_inspector.gd` still have `✕`, so a project-wide search for stray `?` is worthwhile.
- [_] **The stage picker lists every `.tres` under `res://stages`.** A material or any other resource there produces "Cannot load StageDefinition". Filter by loaded type or script class.
- [_] **Callboard edits aren't connected to the editor's save and quit flow.** `plugin.gd` doesn't implement `_save_external_data()` or `_get_unsaved_status()`, so Ctrl+S in the editor won't save Callboard, and closing the editor drops unsaved graph edits without a prompt. It only has its own Ctrl+S handler.
- [_] **`ExprText.format_literal` escapes `"` but not `\` or newlines.** Text like `C:\x` produces an invalid expression.
- [_] **Trace rows are built even when the debug panel is hidden.** Store entries in a ring buffer and render only when the panel is visible.
- [_] **Resource caching after `ResourceSaver.save`.** Saving a fresh `draft` over an existing `.tres` is worth verifying for two things: that the UID is preserved, and that scenes already open in the editor don't keep the stale cached resource.

## Code quality

- [_] `VerbCatalog.from_factory`, `props_of` and `find` are line-for-line copies of `RuntimeVerbCatalog`. Delegate so they can't drift.
- [_] `StepContext.wait` is never used.
- [_] `StageDefinition.rules` has a getter/setter pair that does nothing. Remove it.
- [_] The collision layer constants are duplicated in `player.gd` and `trigger_area.gd`, and `bump_prop.gd` uses raw shifts. Use one shared constants class.
- [_] Reset (R) and strike (X) use raw keycodes, while movement uses InputMap actions. Add actions for them, and consider using `physical_keycode` for `interact`, which is currently the only logical-keycode binding.
- [_] `Stage01._restore_state` reads `fired` by raw rule id. A `Stage.has_fired(rule_id)` helper that resolves through `latch_key()` would survive renames in a more principled way.
- [_] The tests reach into many private members (`board._data`, `view._rule_nodes`). That's fine for now but couples them to internals.
- [_] The addon's edit model is still stringly-typed dictionaries (`"one_shot"`, `"has_pos"`). Constants for the keys would reduce typo risk.

## CI

- [_] Add `timeout 120` to the suite step. A coroutine that never reaches `quit()` currently hangs until the 10-minute job limit.
- [_] Grep the suite output for `SCRIPT ERROR` as you already do for import. Runtime script errors inside callbacks don't change the exit code.
- [_] Add a check that `core/` never references `VerbCatalog`, `AuthoredData`, `RuleGraph*` or `Callboard*`, ideally by running the smoke suite with `editor/` and `model/` removed. That verifies the export-filter promise instead of trusting it.

## Housekeeping

- [_] `FEEDBACK.md` still uses the old Zone/`director_blackboard` names and describes issues that are now fixed. Delete it or move it to `docs/history/`.
- [_] `TODO.md` has every item checked but is titled "Remaining backlog". Archive it or reset it.
- [_] `plugin.cfg` still says `author="demo"`. Add a LICENSE if there isn't one.
- [_] Consider adding `.gitattributes` with `* text=auto eol=lf`, since your notes suggest a Windows workflow.
- [_] `world_manager.gd` has an untyped `var player = Player.new()`. Use `:=`.