extends SceneTree
## Headless authoring integration test: godot --headless --path . --script res://tests/editor_smoke.gd

const ZONE_PATH := "res://zones/zone_01/zone_01.gd"
const DEFINITION_PATH := "res://zones/zone_01/zone_01.tres"
const TMP_PATH := "user://zone_tmp.tres"

func _initialize() -> void:
	var ok := _test_factory()
	ok = _test_rename_saved_state() and ok

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

	await process_frame
	ok = _test_numeric_undo() and ok
	ok = _test_event_and_relay_edits() and ok
	print("EDITOR: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _test_event_and_relay_edits() -> bool:
	var definition := load(DEFINITION_PATH) as ZoneDefinition
	if not _check("connection fixture saved", ResourceSaver.save(definition, TMP_PATH) == OK):
		return false
	var board := RuleBoard.new()
	root.add_child(board)
	board.open_script(TMP_PATH)
	board._connections_button.pressed.emit()
	var picker := board._connection_picker
	for i in picker.item_count:
		if picker.get_item_text(i) == "offer:decoy":
			picker.select(i)
			picker.item_selected.emit(i)
			break
	var ok := _check("connection dialog lists affected rules and external callers",
		board._connections_dialog.visible and "z1_decoy — trigger" in board._connection_impact.text
		and "gameplay code" in board._connection_impact.text)
	board._connection_name.text = "offer:parcel"
	board._connections_dialog.confirmed.emit()
	ok = _check("event rename updates its card and rule trigger",
		board.view._event_nodes.has("offer:parcel")
		and not board.view._event_nodes.has("offer:decoy")
		and _rule(board._data, "z1_decoy")["trigger"] == "offer:parcel") and ok
	ok = _check("event name collision leaves connections alone",
		not board.rename_connection("offer:parcel", "deliver").is_empty()
		and _rule(board._data, "z1_decoy")["trigger"] == "offer:parcel") and ok
	board._connections_button.pressed.emit()
	for i in picker.item_count:
		if picker.get_item_text(i) == "offer:parcel":
			picker.select(i)
			picker.item_selected.emit(i)
			break
	board._delete_connection_button.pressed.emit()
	ok = _check("delete confirmation names the affected trigger",
		board._delete_connection_dialog.visible
		and "z1_decoy — trigger" in board._delete_connection_dialog.dialog_text) and ok
	board._delete_connection_dialog.confirmed.emit()
	ok = _check("deleting an event clears its dependent trigger",
		not board.view._event_nodes.has("offer:parcel")
		and _rule(board._data, "z1_decoy")["trigger"] == "") and ok
	board.undo()
	ok = _check("undo restores the event and its wire",
		board.view._event_nodes.has("offer:parcel")
		and _rule(board._data, "z1_decoy")["trigger"] == "offer:parcel") and ok

	ok = _check("relay rename updates every rule emitter and the listener",
		board.rename_connection("relay:calm_guard", "guard_calm").is_empty()
		and _rule(board._data, "z1_treat")["emit"] == "guard_calm"
		and _rule(board._data, "z1_decoy")["emit"] == "guard_calm"
		and _rule(board._data, "z1_calm")["trigger"] == "relay:guard_calm") and ok
	ok = _check("relay rename updates the authored argument of a step emitter",
		board.rename_connection("relay:standoff_tick", "guard_tick").is_empty()
		and _rule(board._data, "z1_standoff")["steps"][0]["args"] == ["3.5", '&"guard_tick"']
		and _rule(board._data, "z1_bark")["trigger"] == "relay:guard_tick") and ok
	ok = _check("an external relay rename updates its declaration and listener",
		board.rename_connection("relay:treat_out", "treat_ready").is_empty()
		and board._data["external_events"].has("relay:treat_ready")
		and _rule(board._data, "z1_treat")["trigger"] == "relay:treat_ready") and ok

	board.save()
	var reloaded := RuleGraphReader.inspect_definition(TMP_PATH)
	var tick: Dictionary = _rule(reloaded, "z1_standoff")["steps"][0]
	var saved: ZoneDefinition = reloaded["definition"]
	ok = _check("save and reload preserve relay edits and rederive step metadata",
		reloaded["compiles"] and tick["emits"] == "guard_tick" and tick["emit_arg"] == 1
		and not saved.rules[0]["steps"][0].has("emit_arg")) and ok

	var affected := RuleConnections.impact(board._data, "relay:guard_tick")
	ok = _check("relay deletion lists its emitting step and receiving trigger",
		affected.has("z1_standoff — step 1 (repeat_emit)") and affected.has("z1_bark — trigger")) and ok
	ok = _check("deleting a step relay removes the emitting step and disconnects its listener",
		board.delete_connection("relay:guard_tick").is_empty()
		and _rule(board._data, "z1_standoff")["steps"].is_empty()
		and _rule(board._data, "z1_bark")["trigger"] == "") and ok
	board.undo()
	ok = _check("undo restores the emitting step and relay connection",
		_rule(board._data, "z1_standoff")["steps"][0]["emits"] == "guard_tick"
		and _rule(board._data, "z1_bark")["trigger"] == "relay:guard_tick") and ok
	ok = _check("deleting a rule relay clears all its outputs and listeners",
		board.delete_connection("relay:guard_calm").is_empty()
		and _rule(board._data, "z1_treat")["emit"] == ""
		and _rule(board._data, "z1_decoy")["emit"] == ""
		and _rule(board._data, "z1_calm")["trigger"] == "") and ok
	board.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	return ok

func _test_rename_saved_state() -> bool:
	var definition := load(DEFINITION_PATH) as ZoneDefinition
	if not _check("rename fixture saved", ResourceSaver.save(definition, TMP_PATH) == OK):
		return false
	var board := RuleBoard.new()
	root.add_child(board)
	board.open_script(TMP_PATH)
	board._on_rule_selected("z1_delivered")
	board.inspector._set_id("delivered")
	board.undo()
	var ok := _check("undo restores the rule ID", not _rule(board._data, "z1_delivered").is_empty())
	board.redo()
	board._on_rule_selected("delivered")
	board.inspector._set_id("parcel_delivered")
	var key_edit := board.blackboard._rows.get_child(0).get_child(0) as LineEdit
	key_edit.text = "guard_relaxed"
	key_edit.text_submitted.emit(key_edit.text)
	board.save()

	var data := RuleGraphReader.inspect_definition(TMP_PATH)
	var renamed: ZoneDefinition = data["definition"]
	var zone := renamed.instantiate()
	zone.fired = {&"z1_delivered": true}
	zone.saved_vars = {&"guard_calmed": true}
	zone.build()
	var delivered: Rule
	for rule in zone.engine.rules:
		if rule.id == &"parcel_delivered":
			delivered = rule
			break
	ok = _check("an existing latch survives repeated rule renames and reload",
		delivered != null and delivered.latch_key() == &"z1_delivered"
		and not zone.engine.passes(delivered)) and ok
	ok = _check("the renamed Blackboard key reads an existing saved value",
		zone.get_var(&"guard_relaxed") == true and zone.get_var(&"guard_calmed") == true
		and not zone.saved_vars.has(&"guard_relaxed")) and ok
	zone.write_var(&"guard_relaxed", false)
	ok = _check("writes still use the original saved storage key",
		zone.saved_vars == {&"guard_calmed": false}) and ok
	zone.free()

	board.duplicate_rule("parcel_delivered")
	board.inspector._set_id("z1_delivered")
	var original := _rule(board._data, "parcel_delivered")
	var copy := _rule(board._data, "z1_delivered")
	ok = _check("a duplicate can reuse the old rule name without inheriting its latch",
		original["state_key"] != copy["state_key"]) and ok
	board.blackboard._on_add(0)
	var rows := board.blackboard._rows
	var reused_key := rows.get_child(rows.get_child_count() - 1).get_child(0) as LineEdit
	reused_key.text = "guard_calmed"
	reused_key.text_submitted.emit(reused_key.text)
	board._data["vars"].back()["scope"] = "saved"
	var reused_zone := RuleGraphReader.make_definition(board._data).instantiate()
	reused_zone.saved_vars = {&"guard_calmed": true}
	reused_zone.build()
	ok = _check("a new saved variable can reuse the old name with its own default",
		reused_zone.get_var(&"guard_relaxed") == true and reused_zone.get_var(&"guard_calmed") == false) and ok
	reused_zone.free()
	board.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	return ok

func _test_numeric_undo() -> bool:
	var board := RuleBoard.new()
	root.add_child(board)
	board.open_script(DEFINITION_PATH)
	board.blackboard._on_add(1)
	var row := board.blackboard._rows.get_child(board.blackboard._rows.get_child_count() - 1)
	var spin := row.get_child(2) as SpinBox
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	board._input(mouse)
	spin.value = 1.0
	spin.value = 2.0
	mouse.pressed = false
	board._input(mouse)
	mouse.pressed = true
	board._input(mouse)
	spin.value = 3.0
	spin.value = 4.0
	mouse.pressed = false
	board._input(mouse)
	board.undo()
	var ok := _check("a second SpinBox gesture undoes independently",
		board._data["vars"].back()["default"] == 2)
	board.undo()
	ok = _check("one undo restores the value before the first SpinBox gesture",
		board._data["vars"].back()["default"] == 0) and ok
	board.redo()
	board.redo()
	ok = _check("redo restores the final value of each gesture",
		board._data["vars"].back()["default"] == 4) and ok

	board._on_rule_selected("z1_standoff")
	var interval := board.inspector.find_children("*", "SpinBox", true, false).front() as SpinBox
	mouse.pressed = true
	board._input(mouse)
	interval.value = 4.0
	interval.value = 5.0
	mouse.pressed = false
	board._input(mouse)
	ok = _check("the numeric step field stays active throughout a gesture",
		_rule(board._data, "z1_standoff")["steps"][0]["args"][0] == "5.0") and ok
	board.undo()
	ok = _check("one undo restores the step argument before the drag",
		_rule(board._data, "z1_standoff")["steps"][0]["args"][0] == "3.5") and ok
	board.queue_free()
	return ok

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

