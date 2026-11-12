# Callboard

Callboard is a Godot addon for authoring event driven gameplay rules in a visual graph. Gameplay runs in **Stages**. Each Stage has a typed Blackboard, external Calls, rules, and internal relays.

> Formerly Director Blackboard / Rule Board.

## Requirements and demo

- Godot 4.7 (the project declares the `4.7` feature version).
- Open `project.godot`, let Godot import the project, then press **F5** to run the demo.
- Move with **WASD** or the arrow keys. Press **E** near an interaction area.

In the sample Stage, interact at the shelter to offer a decoy, deliver at the doorway, and bump the blue pad to release a treat.

| Key | Action |
| --- | --- |
| **F1** | Toggle the read only live Callboard overlay. |
| **R** | Reload the Stage. Saved Blackboard values and one-shot latches persist; local values reset. |
| **X** | Clear saved values and one-shot latches, reset the score, and reload the Stage. |

## Authoring

The **Callboard** tab is enabled in the Godot editor. Use it to edit a Stage definition stored in one `.tres` resource.

- Add typed Blackboard variables and choose whether each value is saved or local.
- Add Calls, rules, and groups. Connect rule outputs to triggers; the graph wires are derived from rule triggers and emitted relays.
- Rename Calls and relays across authored connections. Deleting a relay removes its emitting steps and disconnects its listeners. Update gameplay code and scene triggers when renaming an external Call or relay.
- Edit each rule's trigger, guards, cancellation conditions, one-shot setting, re-entry policy, emitted relay, group, and ordered steps.
- Save validates step expressions. Reload picks up edits made outside the Callboard.
- Undo and redo are available from the toolbar and **Ctrl/Cmd+Z**, **Ctrl/Cmd+Shift+Z**, or **Ctrl/Cmd+Y**. A held numeric field creates one undo entry per gesture.
- Create a Stage with **Project > Tools > Create New Stage...**.

## Glossary

| Term | Meaning |
| --- | --- |
| **Stage** | A gameplay scene host with its script, props, Blackboard, and authored rules. |
| **Call** | A named external event sent by gameplay code to activate rules. The Stage starts with the built in `arrive` Call. |
| **Rule** | A response to a trigger. Its guards are checked when the trigger arrives; its steps run in order. |
| **Relay** | An internal event emitted by a rule or step. Relays can trigger other rules. |
| **One-shot** | A rule that latches when it starts. Its latch is stored in the manager's `fired` dictionary and survives Stage reloads; cancelling it mid run does not clear the latch. |
| **Re-entry policy** | What happens when a trigger reaches a rule that is already running: Ignore (default), Restart with the latest payload at the next cancellation check, or Queue payloads in arrival order. |
| **Notes** | Validation messages shown for authored rules and steps. |

Calls and relays both enter the rule engine through `fire()`. Their distinction is where they come from: gameplay code sends Calls; rules and steps emit relays.

## Project layout

- `addons/callboard/` — runtime classes, Stage definition model, editor graph and plugin.
- `scripts/` — demo harness, HUD, world setup, player, and prop scripts.
- `stages/stage_01/` — sample Stage script, scene, and definition.
- `game.tscn` — main scene; `project.godot` — project and plugin configuration.
- `tests/unit.gd` — deterministic validator, rule engine, re-entry, clock, and migration checks.
- `tests/editor_smoke.gd` — Callboard authoring and save integration checks.
- `tests/smoke.gd` — runtime checks for the sample Stage and player interactions.

Run the suites from the project directory:

```sh
godot --headless --path . --editor --import
godot --headless --path . --script res://tests/unit.gd
godot --headless --path . --script res://tests/editor_smoke.gd
godot --headless --path . --script res://tests/smoke.gd
```

GitHub Actions runs each suite as a separate check on pushes and pull requests, using Godot 4.7.2.

## Make a Stage

1. Create one from **Project > Tools > Create New Stage...**, or write a `@tool` script extending `Stage`. Keep `_build_props()` safe to call on an unparented instance so the editor can inspect it.
2. Assign the script to a `StageDefinition` resource. List Blackboard keys written by gameplay code under **External Vars**.
3. Add Calls, Blackboard variables, rules, and graph layout in Callboard.
4. Assign the definition to the Stage scene. Before adding a Stage to the SceneTree, inject existing `saved_vars` and `fired` dictionaries if they should persist across reloads, then call `activate()`. Call `deactivate()` when unloading it.

The Stage builds props, applies definition defaults, calls the optional `_build_blackboard()` hook, and builds its rules. Use `get_var()`, `write_var()`, and `fire()` in gameplay code. Saved keys retain injected values when defaults are applied; initialize local keys consistently when they should reset on reload.

Resource step arguments use Godot Expression syntax. Typed Stage props and script constants are available by name, along with literals such as `&"lamp_on"`. Expressions are trusted project data and can call GDScript methods.

## Custom verbs

Resource backed Stages use `StagingVerbs` by default. Extend it to add verbs, or extend `CoreVerbs` for a factory with Blackboard writes, scoring, and repeating relays. Override `_make_verbs(context: StepContext) -> CoreVerbs` in the Stage script to use a custom factory. Give public verbs typed parameters and a `Step` return type to make them appear in Callboard. Declare Blackboard keys the step writes in `sets` and any relay it emits in `emits`.

If a step emits a relay named by one of its arguments, set `Step.emit_arg` to that argument's zero based index so Callboard can update it during a relay rename. Edit fixed relay names in the verb code. For a step that waits internally, capture `engine.token()` on entry and check `engine.alive(payload["_rule"], token)` after each await before applying more effects.

## Runtime components

`Stage` owns scene setup and lifecycle. `Blackboard` stores local and saved values. `RuleEngine` evaluates guards and runs steps and relays. `RuleValidator` checks the same built rules for the editor and runtime, including relay cycles and shared triggers with overlapping guards. The engine accepts an injected wait callable so tests can advance delays and repeating relays without real time passing.
