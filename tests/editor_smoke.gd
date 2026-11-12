extends SceneTree
## Headless authoring integration test: godot --headless --path . --script res://tests/editor_smoke.gd

const ZONE_PATH := "res://zones/zone_01/zone_01.gd"
const DEFINITION_PATH := "res://zones/zone_01/zone_01.tres"
const TMP_PATH := "user://zone_tmp.tres"

func _initialize() -> void:
	var ok := _test_factory()

	# --- Authored resource ----------------------------------------------------------
	var src := FileAccess.get_file_as_string(ZONE_PATH)
	var definition := load(DEFINITION_PATH) as ZoneDefinition
	var data := RuleGraphReader.inspect_definition(DEFINITION_PATH)
	ok = _check("resource stores events, variables, rules and groups",
		definition.external_events.size() == 4 and definition.variables.size() == 3
		and not definition.rules.is_empty() and definition.rules.size() == data["rules"].size()
		and definition.groups.size() == 3) and ok
	ok = _check("reader: no parse error, compiles, no problems", data["parse_error"] == "" and data["compiles"] and data["problems"].is_empty()) and ok
	ok = _check("reader: every rule has a saved position", data["rules"].all(func(r): return r["has_pos"])) and ok
	ok = _check("reader: step text keeps source expressions", ZoneSource.step_text(data["rules"][1]["steps"][1]) == "light(lamp, true, 3.0).after(0.25)") and ok
	ok = _check("reader: step emits come from runtime Steps", data["rules"][0]["steps"][0]["emits"] == "standoff_tick") and ok
	ok = _check("catalog: 12 verbs incl. typed params", data["catalog"].size() == 12 and VerbCatalog.find(data["catalog"], "move_to")["args"][2]["type"] == TYPE_VECTOR3) and ok
	ok = _check("props discovered", data["props"].any(func(p): return p["name"] == "guard")) and ok

	var gv := RuleGraphView.new()
	root.add_child(gv)
	gv.show_data(data)
	ok = _check("graph: rule nodes and wires built",
		gv._rule_nodes.size() == data["rules"].size() and not gv.get_connection_list().is_empty()) and ok
	gv.pulse("z1_bark")
	gv.queue_free()

	# --- D. Editing through the board ------------------------------------------------
	var board := RuleBoard.new()
	root.add_child(board)
	var zone_paths := board._collect_zone_definition_paths()
	ok = _check("board: discovers nested zone resources",
		zone_paths.has(DEFINITION_PATH)) and ok
	board.open_script(DEFINITION_PATH)
	var d: Dictionary = board._data
	board.view._rule_nodes["z1_bark"].position_offset = Vector2(555, 77)

	var nr: Dictionary = board.add_rule()
	ok = _check("add rule: count increments, id unique, flagged as doing nothing",
		d["rules"].size() == definition.rules.size() + 1 and d["problems"].any(func(p): return "'new_rule' does nothing" in p)) and ok
	ok = _check("card move synced into model", d["rules"][1]["pos"] == Vector2(555, 77)) and ok
	nr["requires"] = ["guard_calmed"]
	nr["steps"].append(VerbCatalog.new_step(d, "score"))
	nr["steps"].append(VerbCatalog.new_step(d, "show_node"))
	ok = _check("new_step fills required args with a compatible prop", nr["steps"][1]["args"] == ["guard"]) and ok
	board._changed("new_rule")
	ok = _check("add steps: clean again", d["problems"].is_empty() and d["compiles"]) and ok

	board.connect_wire({"rule": "z1_bark", "port": 0}, "new_rule")
	ok = _check("wire: names the unnamed port and sets trigger", _rule(d, "z1_bark")["emit"] == "z1_bark_done" and nr["trigger"] == "relay:z1_bark_done") and ok
	ok = _check("wire: no problems after wiring", d["problems"].is_empty()) and ok
	board.connect_wire({"event": "deliver"}, "new_rule")
	ok = _check("wire from event node", nr["trigger"] == "deliver") and ok
	board.disconnect_wire("new_rule")
	ok = _check("disconnect: trigger cleared and flagged", nr["trigger"] == "" and d["problems"].any(func(p): return "'new_rule' has no trigger" in p)) and ok

	board.duplicate_rule("new_rule")
	ok = _check("duplicate: unique id", ZoneSource.rule_ids(d).has("new_rule_copy")) and ok
	board.delete_rule("new_rule_copy")
	board.delete_rule("new_rule")
	ok = _check("delete: original count restored; unheard relay is flagged",
		d["rules"].size() == definition.rules.size() and d["problems"].size() == 1 and "z1_bark_done" in d["problems"][0]) and ok
	_rule(d, "z1_bark")["emit"] = ""
	board._changed("")
	ok = _check("clearing the emit makes it clean again", d["problems"].is_empty()) and ok

	# Blackboard editing
	board.blackboard._on_add(0)
	ok = _check("add variable (bool, local)", d["vars"].size() == 4 and d["vars"][3]["key"] == "new_var" and d["vars"][3]["scope"] == "local") and ok
	ok = _check("added variable is generated", RuleGraphReader.make_definition(d).variables[3]["default"] == false) and ok
	ZoneSource.rename_key(d, "lamp_on", "alarm_on")
	board._changed("")
	ok = _check("rename key updates guards", _rule(d, "z1_caught")["requires"] == ["alarm_on"]) and ok
	ok = _check("rename key makes implicit `light` key explicit", _rule(d, "z1_bark")["steps"][1]["args"] == ["lamp", "true", "3.0", '&"alarm_on"']) and ok
	ok = _check("rename key: still compiles with no problems", d["compiles"] and d["problems"].is_empty()) and ok
	d["vars"] = d["vars"].filter(func(v): return v["key"] != "guard_calmed")
	board._changed("")
	ok = _check("delete variable: references are flagged", d["problems"].any(func(p): return "'guard_calmed'" in p and "not declared" in p)) and ok

	# Groups
	board.add_group()
	ok = _check("add group", d["groups"].size() == 4) and ok
	_rule(d, "z1_standoff")["group"] = "Group"
	board._changed("z1_standoff")
	board.delete_group("Group")
	ok = _check("delete group clears membership", d["groups"].size() == 3 and _rule(d, "z1_standoff")["group"] == "") and ok
	board.queue_free()

	# --- E. Save: refuses broken output, writes good output ----------------------------
	ok = _check("temporary resource saved", ResourceSaver.save(definition, TMP_PATH) == OK) and ok
	var original := FileAccess.get_file_as_string(TMP_PATH)
	var b2 := RuleBoard.new()
	root.add_child(b2)
	b2.open_script(TMP_PATH)
	var d2: Dictionary = b2._data
	ok = _check("adding an event creates a wireable event card",
		b2.add_event("  doorbell  ") and b2.view._event_nodes.has("doorbell")) and ok
	ok = _check("duplicate and blank event names rejected", not b2.add_event("doorbell") and not b2.add_event(" ")) and ok
	b2._undo_button.pressed.emit()
	ok = _check("undo event returns to clean state", not b2.view._event_nodes.has("doorbell") and not b2._dirty) and ok
	b2._redo_button.pressed.emit()
	ok = _check("redo restores event", b2.view._event_nodes.has("doorbell") and b2._dirty) and ok

	var old_pos: Vector2 = _rule(d2, "z1_bark")["pos"]
	b2.view._rule_nodes["z1_bark"].position_offset = old_pos + Vector2(42, 0)
	b2.view.end_node_move.emit()
	b2.undo()
	ok = _check("undo restores card position", b2.view.get_positions()["z1_bark"] == old_pos) and ok
	b2.redo()
	ok = _check("redo restores card move", b2.view.get_positions()["z1_bark"] == old_pos + Vector2(42, 0)) and ok
	b2.undo()
	var frame: GraphFrame = b2.view._frames["Delivery"]
	var frame_size := frame.size
	frame.resize_request.emit(frame_size.round() + Vector2(30.0002, 29.9998))
	b2.undo()
	ok = _check("undo restores frame size", b2.view.get_group_rects()["Delivery"].size == frame_size) and ok
	b2.redo()
	ok = _check("redo restores frame resize",
		b2.view.get_group_rects()["Delivery"].size == frame_size.round() + Vector2(30, 30)) and ok
	b2.undo()
	b2.blackboard._on_add(0)
	ok = _check("new edit clears redo", b2._redo_button.disabled and d2["vars"].size() == 4) and ok
	b2.undo()
	ok = _check("undo restores blackboard rows", d2["vars"].size() == 3) and ok

	b2.connect_wire({"event": "doorbell"}, "z1_decoy")
	ok = _check("wire uses new event", _rule(d2, "z1_decoy")["trigger"] == "doorbell") and ok
	b2.undo()
	ok = _check("undo restores previous wire", _rule(d2, "z1_decoy")["trigger"] == "offer:decoy") and ok
	b2.redo()
	ok = _check("redo reconnects event wire", _rule(d2, "z1_decoy")["trigger"] == "doorbell") and ok
	_rule(d2, "z1_standoff")["steps"][0]["args"][0] = "@@"
	b2._changed("z1_standoff")
	ok = _check("broken edit: compile failure detected", not d2["compiles"]) and ok
	b2.save()
	ok = _check("broken edit: save refused, file untouched", FileAccess.get_file_as_string(TMP_PATH) == original) and ok
	_rule(d2, "z1_standoff")["steps"][0]["args"][0] = "4.0"
	var added: Dictionary = b2.add_rule()
	added["steps"].append(VerbCatalog.new_step(d2, "score"))
	b2.connect_wire({"rule": "z1_calm", "port": 0}, added["id"])
	var saved_frame: GraphFrame = b2.view._frames["Delivery"]
	saved_frame.size += Vector2(10.0002, 0)
	var expected_size := saved_frame.size.round()
	b2.save()
	var re := RuleGraphReader.inspect_definition(TMP_PATH)
	ok = _check("save: script unchanged", FileAccess.get_file_as_string(ZONE_PATH) == src) and ok
	ok = _check("save: rule, relay and interval persisted",
		_rule(re, "new_rule")["trigger"] == "relay:z1_calm_done"
		and _rule(re, "z1_standoff")["steps"][0]["args"][0] == "4.0") and ok
	ok = _check("save: frame size is rounded on disk",
		re["groups"].any(func(g): return g["name"] == "Delivery" and g["rect"].size == expected_size)) and ok
	ok = _check("save: position preserved", _rule(re, "new_rule")["has_pos"]) and ok
	ok = _check("save: reloaded zone builds with no problems", re["compiles"] and re["problems"].is_empty()) and ok
	ok = _check("new event and wire persist",
		re["external_events"].has("doorbell") and _rule(re, "z1_decoy")["trigger"] == "doorbell") and ok
	b2.undo()
	ok = _check("undo after saving is an unsaved edit", b2._dirty) and ok
	b2.redo()
	ok = _check("redo to saved state clears unsaved indicator", not b2._dirty) and ok
	b2.open_script(TMP_PATH)
	ok = _check("reopening resource starts a fresh history", b2._undo_button.disabled and b2._redo_button.disabled) and ok
	b2.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))

	print("EDITOR: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_factory() -> bool:
	# Build an unparented resource-backed zone with its own verb factory.
	var script := GDScript.new()
	script.source_code = """@tool
extends Zone

const MESSAGE := 'A, "B"'
var target: Node3D

class CustomVerbs extends StagingVerbs:
	func stamp(prop: Node3D, label: String) -> Step:
		return Step.new(func(_c: Dictionary) -> void: prop.set_meta(&"label", label))

func _make_verbs(ctx: StepContext) -> CoreVerbs:
	return CustomVerbs.new(ctx)

func _build_props() -> void:
	target = Node3D.new()
	add_child(target)

func _build_blackboard() -> void:
	write_var(&"ready", true)
"""
	if not _check("custom factory fixture compiles", script.reload() == OK):
		return false
	var definition := ZoneDefinition.new()
	definition.zone_script = script
	definition.variables = [{"key": "ready", "scope": "local", "default": false}]
	var spec := {"verb": "stamp", "args": ["target", "MESSAGE"], "delay": "0.25"}
	definition.rules = [{
		"id": "custom", "trigger": "arrive", "requires": [], "forbids": [],
		"cancel_if": [], "once": false, "emit": "", "steps": [spec],
	}]
	var zone := definition.instantiate()
	zone.build()
	var ok := _check("factory discovers its custom verb and the inherited verbs",
		VerbCatalog.from_factory(zone.verbs).size() == 13)
	ok = _check("zone runs the blackboard hook after resource defaults", zone.is_set(&"ready")) and ok
	if _check("custom resource compiles", zone.graph_errors.is_empty()):
		var step := zone.engine.rules[0].steps[0]
		ok = _check("resource compiler supplies verb, prop, constant and delay metadata",
			step.verb == &"stamp" and step.args == [zone.get("target"), 'A, "B"']
			and step.delay == 0.25) and ok
		step.fn.call({})
		ok = _check("compiled custom step runs with the supplied arguments",
			zone.get("target").get_meta(&"label") == 'A, "B"') and ok
	else:
		ok = false
	zone.engine.rules.clear()
	zone.free()

	spec["args"] = ["null", "MESSAGE"]
	zone = definition.instantiate()
	zone.build()
	ok = _check("validator still reports null props with compiler-generated metadata",
		zone.validate().any(func(problem): return "'stamp' step with an unset prop" in problem)) and ok
	zone.engine.rules.clear()
	zone.free()

	var legacy := ZonePreview.run("""@tool
extends Zone
func _build_blackboard() -> void:
	define_local(&"ready", false)
func _build_rules() -> void:
	var r := rule(&"legacy", &"arrive")
	r.steps = [set_var(&"ready")]
""")
	ok = _check("script-authored rules still build through Zone's legacy verbs",
		legacy["ok"] and legacy["problems"].is_empty()) and ok
	ZonePreview.dispose(legacy)
	return ok

func _rule(d: Dictionary, id: String) -> Dictionary:
	for r in d["rules"]:
		if r["id"] == id:
			return r
	return {}

func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond

