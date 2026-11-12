extends SceneTree
## Headless smoke test: godot --headless --path . --script res://tests/smoke.gd

const ZONE_PATH := "res://scripts/zones/zone_01.gd"
const DEFINITION_PATH := "res://scripts/zones/zone_01.tres"
const TMP_PATH := "user://zone_tmp.tres"

func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(0.5).timeout
	var zone: Zone = main.zone
	var ok := true

	# --- A. Runtime validator ------------------------------------------------------
	ok = _check("zone validates clean", zone.validate().is_empty()) and ok
	var bad := Zone.new()
	var br := bad.rule(&"typo", &"relay:ghost")
	br.forbids = [&"nope"]
	var problems := bad.validate()
	ok = _check("validator: unknown relay", problems.any(func(p): return "relay:ghost" in p)) and ok
	ok = _check("validator: undeclared key", problems.any(func(p): return "'nope'" in p and "not declared" in p)) and ok
	ok = _check("validator: empty rule", problems.any(func(p): return "does nothing" in p)) and ok
	bad.free()

	# --- B. Blackboard schema --------------------------------------------------------
	ok = _check("saved key routes to saved_vars", zone.saved_vars.has(&"guard_calmed") and not zone.local_vars.has(&"guard_calmed")) and ok
	ok = _check("local key routes to local_vars", zone.local_vars.has(&"lamp_on") and not zone.saved_vars.has(&"lamp_on")) and ok

	# --- C. Authored resource -------------------------------------------------------
	var src := FileAccess.get_file_as_string(ZONE_PATH)
	var definition := load(DEFINITION_PATH) as ZoneDefinition
	ok = _check("resource stores events, variables, rules and groups",
		definition.external_events.size() == 4 and definition.variables.size() == 3
		and definition.rules.size() == 7 and definition.groups.size() == 3) and ok
	var data := RuleGraphReader.inspect_definition(DEFINITION_PATH)
	ok = _check("reader: no parse error, compiles, no problems", data["parse_error"] == "" and data["compiles"] and data["problems"].is_empty()) and ok
	ok = _check("reader: every rule has a saved position", data["rules"].all(func(r): return r["has_pos"])) and ok
	ok = _check("reader: step text keeps source expressions", ZoneSource.step_text(data["rules"][1]["steps"][1]) == "light(lamp, true, 3.0).after(0.25)") and ok
	ok = _check("reader: step emits come from runtime Steps", data["rules"][0]["steps"][0]["emits"] == "standoff_tick") and ok
	ok = _check("catalog: 12 verbs incl. typed params", data["catalog"].size() == 12 and VerbCatalog.find(data["catalog"], "move_to")["args"][2]["type"] == TYPE_VECTOR3) and ok
	ok = _check("props discovered (7)", data["props"].size() == 7) and ok

	var gv := RuleGraphView.new()
	root.add_child(gv)
	gv.show_data(data)
	ok = _check("graph: 8 wires (%d)" % gv.get_connection_list().size(), gv.get_connection_list().size() == 8) and ok
	gv.pulse("z1_bark")
	gv.queue_free()

	# --- D. Editing through the board ------------------------------------------------
	var board := RuleBoard.new()
	root.add_child(board)
	var zone_paths := board._collect_zone_definition_paths()
	ok = _check("board: discovers nested zone resources",
		zone_paths.has("res://zones/testing/testing.tres")
		and zone_paths.has("res://zones/testing_02/testing_02.tres")) and ok
	board.open_script(DEFINITION_PATH)
	var d: Dictionary = board._data
	board.view._rule_nodes["z1_bark"].position_offset = Vector2(555, 77)

	var nr: Dictionary = board.add_rule()
	ok = _check("add rule: 8 rules, id unique, flagged as doing nothing", d["rules"].size() == 8 and d["problems"].any(func(p): return "'new_rule' does nothing" in p)) and ok
	ok = _check("card move synced into model", d["rules"][1]["pos"] == Vector2(555, 77)) and ok
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
	ok = _check("delete: 7 rules; the now-unheard relay is flagged", d["rules"].size() == 7 and d["problems"].size() == 1 and "z1_bark_done" in d["problems"][0]) and ok
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
	b2._event_button.pressed.emit()
	b2._event_name.text = "  doorbell  "
	b2._event_name.text_submitted.emit(b2._event_name.text)
	ok = _check("event dialog creates a wireable event card", b2.view._event_nodes.has("doorbell")) and ok
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
	frame.resize_request.emit(frame_size + Vector2(30, 30))
	b2.undo()
	ok = _check("undo restores frame size", b2.view.get_group_rects()["Delivery"].size == frame_size) and ok
	b2.redo()
	ok = _check("redo restores frame resize", b2.view.get_group_rects()["Delivery"].size == frame_size + Vector2(30, 30)) and ok
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
	b2.save()
	var re := RuleGraphReader.inspect_definition(TMP_PATH)
	ok = _check("save: script unchanged", FileAccess.get_file_as_string(ZONE_PATH) == src) and ok
	ok = _check("save: rule, relay and interval persisted",
		_rule(re, "new_rule")["trigger"] == "relay:z1_calm_done"
		and _rule(re, "z1_standoff")["steps"][0]["args"][0] == "4.0") and ok
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

	# --- F. Runtime behaviour --------------------------------------------------------
	await create_timer(4.2).timeout
	ok = _check("bark fired", main.log_lines.any(func(l): return l.begins_with("z1_bark"))) and ok
	ok = _check("lamp on after bark", zone.is_set(&"lamp_on")) and ok

	zone.fire(&"deliver")
	await create_timer(0.1).timeout
	ok = _check("caught fired", main.log_lines.any(func(l): return l.begins_with("z1_caught"))) and ok
	ok = _check("player stunned", main.player.stunned) and ok

	var pad: BumpProp = zone.get_node("BumpPad")
	pad._on_bump(main.player)
	zone.fire(&"offer:decoy")
	await create_timer(1.8).timeout
	ok = _check("guard calmed (saved var)", zone.saved_vars.get(&"guard_calmed", false)) and ok
	var calm_count := 0
	for l in main.log_lines:
		if l.begins_with("z1_calm"): calm_count += 1
	ok = _check("calm ran exactly once", calm_count == 1) and ok
	ok = _check("lamp off", not zone.is_set(&"lamp_on")) and ok
	ok = _check("score 100 from decoy", main.score == 100) and ok

	var before: int = main.log_lines.size()
	await create_timer(4.0).timeout
	ok = _check("no new rules fired after calm", main.log_lines.size() == before) and ok

	zone.fire(&"deliver")
	zone.fire(&"deliver")
	await create_timer(0.8).timeout
	ok = _check("delivered once (+200)", main.score == 300) and ok

	# --- G. Reload: saved persists, local resets; live board is read-only -------------
	main._unload_zone()
	main._load_zone()
	zone = main.zone
	var fired_after := []
	zone.rule_fired.connect(func(id, _e): fired_after.append(id))
	await create_timer(4.5).timeout
	ok = _check("saved var persists", zone.saved_vars.get(&"guard_calmed", false)) and ok
	ok = _check("local vars reset", not zone.local_vars.get(&"treat_out", false)) and ok
	ok = _check("no rules fire after reload", fired_after.is_empty()) and ok
	ok = _check("reward prop restored", (zone.get_node("RewardProp") as Node3D).visible) and ok
	ok = _check("live board bound (7 rules)", main.board._data["rules"].size() == 7) and ok
	ok = _check("live board is read-only", main.board.add_rule().is_empty() and main.board._data["rules"].size() == 7) and ok

	print("SMOKE: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _rule(d: Dictionary, id: String) -> Dictionary:
	for r in d["rules"]:
		if r["id"] == id:
			return r
	return {}

func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond
