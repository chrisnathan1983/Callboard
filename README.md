# Director Blackboard Demo (Godot 4.3+)

Event-driven choreography with a typed Blackboard and an editable Rule Graph.

## Run it
1. Open `project.godot` in Godot 4.3+ (let it import once so the class cache builds).
2. **Game:** F5. WASD move, E interact, bump the blue pad. **F1** toggles the live Rule Board
   (read-only; cards pulse as rules fire, Blackboard shows live values). R reloads the zone,
   X wipes saved state.
3. **Editor:** the plugin is pre-enabled. Open the **Rule Board** tab next to 2D / 3D / Script.
4. **Tests:** `godot --headless --path . --script res://tests/smoke.gd` (ignore the
   headless renderer diagnostics, if any).

## Layout
- `addons/director_blackboard/` everything reusable
  - `core/` `Zone`, `ZoneDefinition`, `Rule`, `Step`, `TriggerArea`
  - `model/` `ZoneSource` (parse/generate), `VerbCatalog`, `ZonePreview`, `RuleGraphReader`
  - `editor/` `RuleBoard`, `RuleGraphView`, `BlackboardPanel`, `RuleInspector`
  - `plugin.gd`
- `scripts/` demo only: `main.gd`, `actors/player.gd`, `props/` (placeholder props, `BumpProp`),
  `zones/zone_01.gd` (scene behavior), `zones/zone_01.tres` (authored zone data)
- `tests/smoke.gd`

## Using the Rule Board
- **Blackboard (left):** `+ Variable` (bool/int/float/String), rename (guards and `key`
  arguments follow, including implicit defaults like `light`'s), saved/local scope, typed
  default editors, delete (rules that still use it get a warning).
- **+ Event:** enter an event ID to add a graph card and a trigger option. Gameplay code
  can fire the event with `fire(&"event_id")`.
- **Graph (centre):** `+ Rule`, `+ Group`. Drag an output port onto a rule's input to make it
  listen to that relay or event; dragging from a rule's unnamed `emits` port names the relay
  `<rule>_done`. Drag a wire off an input to unwire. Delete key removes selected rules.
  Wires are derived from triggers and emits; they are never stored separately.
- **Inspector (right):** id, trigger (with picker), requires/forbids/cancel_if (checkable
  Blackboard keys), once, emits, group, and steps. Each step has a verb dropdown, typed argument
  widgets built from the verb's signature (prop dropdowns filtered by class, key dropdowns,
  spin boxes, check boxes, raw expression for anything else), `after`, reorder and delete.
  Duplicate / Delete rule. Selecting a group lets you rename or delete it.
- **Undo / Redo:** use the toolbar or Ctrl/Cmd+Z and Ctrl/Cmd+Shift+Z (Ctrl/Cmd+Y also
  redoes). History survives Save and switching editor tabs. Reload or opening a different
  zone starts a fresh history.
- **Save:** validates step expressions and writes the selected `.tres` resource. The zone
  picker searches `res://zones/` and all of its subfolders.

## Authoring a zone

1. Write a normal `@tool` GDScript that extends `Zone`. Use `_build_props()` for setup,
   typed fields for props, and methods returning `Step` for custom graph verbs. Keep
   build hooks safe to call on an unparented instance so the Rule Board can preview them.
2. Create a `ZoneDefinition` resource in `res://scripts/zones/` and assign the script to
   **Zone Script**. In the resource Inspector, list Blackboard keys written by gameplay
   code under **External Vars**. Save the
   resource and press **Reload** on the Rule Board to pick up Inspector edits.
3. Select the resource in the Rule Board, add events and Blackboard variables with their starting
   values, then wire rules. Events, variable definitions, rules, and graph layout all
   live in that one resource.
4. Use `definition.instantiate()` to create a fresh zone. Inject any existing
   `saved_vars` and `fired` dictionaries before adding it to the tree. Call
   `activate()` when the zone is ready to receive events.

The zone builds its props, applies resource defaults, calls the optional
`_build_blackboard()` hook, then builds graph rules. Override the hook when a value
depends on code. For example, if the resource declares a local bool named
`lamp_on`, initialize it from a prop you built earlier:

```gdscript
func _build_blackboard() -> void:
	write_var(&"lamp_on", lamp.visible)
```

Use `get_var()`, `write_var()`, and `fire()` in ordinary gameplay code. Saved keys
keep their injected values when applying defaults. Keep unconditional initializers
for local keys when a saved value should survive a reload.

Graph arguments accept Godot Expression syntax with the zone as the base instance.
Typed prop fields, script constants, and StringName literals such as `&"lamp_on"`
are supported. Put more involved GDScript logic in a custom verb.

## Known limits
- Reload discards unsaved edits. Save or reload before switching zones.
- Moving a card between frames by dragging is handled, but there is no drag-out gesture;
  use the inspector's group dropdown to ungroup.
- This revision was tested headlessly with Godot 4.6.3.
