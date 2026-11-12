# Director Blackboard Demo

A small Godot project demonstrating event-driven gameplay choreography with a typed Blackboard and a visual Rule Board. Gameplay events and relays activate authored rules, while Blackboard conditions control which steps run.

## Requirements

- Godot **4.7** (the project declares the `4.7` feature version in `project.godot`).

## Run the demo

1. Open `project.godot` in Godot and let the project finish importing.
2. Press **F6** to run the current scene or **F5** to run the project.
3. Use **WASD** or the arrow keys to move, and **E** to interact near an interaction area.

In the sample zone, interact at the shelter to offer a decoy, deliver at the doorway, and bump the blue pad to release a treat. The guard, warning lamp, and delivery outcome are driven by rules in the zone definition.

| Key | Action |
| --- | --- |
| **F1** | Toggle the live Rule Board overlay. It shows rule activity and Blackboard values; it is read-only during gameplay. |
| **R** | Reload the zone. Saved Blackboard values and once-rule state persist; local values reset. |
| **X** | Clear saved values and once-rule state, reset the score, and reload the zone. |

## Rule Board

The editor plugin is enabled in `project.godot`. Open the **Rule Board** tab in the Godot editor to inspect and edit a zone definition.

- **Blackboard:** add typed variables, choose saved or local scope, set defaults, and inspect variable usage.
- **Events and graph:** add event cards, rules, and groups. Connect rule outputs to triggers; wires are derived from rule triggers and emitted relays.
- **Rule inspector:** edit triggers, requirements, forbidden/cancellation conditions, once behavior, emitted relays, groups, and ordered steps. Step arguments use verb-specific controls where available.
- **Save:** validates step expressions and saves the selected `.tres` zone definition. Use **Reload** to pick up zone edits made outside the Rule Board.
- **Undo/redo:** use the toolbar or **Ctrl/Cmd+Z** and **Ctrl/Cmd+Shift+Z** (**Ctrl/Cmd+Y** also redoes).
- **Create a zone:** in the Godot editor, use **Project > Tools > Create New Zone...** to generate a zone setup more quickly.

## Project layout

- `addons/director_blackboard/` — reusable runtime, zone/definition models, editor UI, and plugin entry point.
- `scripts/` — demo harness, HUD, world setup, player, and reusable prop scripts.
- `zones/zone_01/` — sample zone script, scene, and authored zone definitions (`zone_01.tres` and `zone_02.tres`).
- `game.tscn` — main scene; `project.godot` — project and plugin configuration.
- `tests/smoke.gd` — headless smoke test.

Run the smoke test from the project directory with:

```sh
godot --headless --max-fps 60 --fixed-fps 60 --quit-after 2000 --path . --script res://tests/smoke.gd
```

## Author a zone

1. Use **Project > Tools > Create New Zone...** to generate a starting zone, or create a `@tool` GDScript extending `Zone` yourself. Use `_build_props()` for scene setup, typed fields for props, and methods returning `Step` for custom rule verbs. Keep build hooks safe to run on an unparented instance so the editor can preview the zone.
2. Create or edit a `ZoneDefinition` resource, assign the zone script, and list Blackboard keys written by gameplay code under **External Vars**.
3. Add events, Blackboard variables, rules, and graph layout to the definition in the Rule Board. These are stored together in the `.tres` resource.
4. Instantiate the definition, inject any existing `saved_vars` and `fired` dictionaries before adding the zone to the scene tree, then call `activate()` when it is ready to receive events.

The zone builds props, applies resource defaults, calls the optional `_build_blackboard()` hook, and then builds its rules. Override the hook for values that depend on built props. Use `get_var()`, `write_var()`, and `fire()` in gameplay code. Saved keys retain injected values when defaults are applied; initialize local keys consistently when they should reset on reload.

Rule arguments use Godot Expression syntax with the zone as the base instance. Typed prop fields, script constants, and `StringName` literals such as `&"lamp_on"` are supported; put more complex logic in a custom verb.
