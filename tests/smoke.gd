extends SceneTree
## Short runtime smoke test with no wall-clock waits.

const ZONE_SCENE_PATH := "res://zones/zone_01/zone_01.tscn"

func _initialize() -> void:
	var packed := load(ZONE_SCENE_PATH) as PackedScene
	var zone := packed.instantiate() as Zone
	root.add_child(zone)
	await process_frame

	var ok := _check("zone loads and validates", zone.validate().is_empty())
	zone.activate() # leaves a repeating relay pending during unload
	var fired: Array[StringName] = []
	zone.rule_fired.connect(func(id: StringName, _event: StringName) -> void: fired.append(id))
	zone.fire(&"deliver")
	zone.fire(&"deliver")
	await process_frame

	var delivered_count := 0
	for id in fired:
		if id == &"z1_delivered":
			delivered_count += 1
	ok = _check("deliver fires the eligible rule once",
		delivered_count == 1 and zone.fired.has(&"z1_delivered")) and ok
	ok = _check("deliver guard prevents the caught rule", not fired.has(&"z1_caught")) and ok

	var changes: Array = []
	zone.var_changed.connect(func(key: StringName, value: Variant) -> void:
		changes.append([key, value]))
	zone.write_var(&"guard_calmed", true)
	ok = _check("zone forwards Blackboard writes to gameplay listeners",
		changes == [[&"guard_calmed", true]] and zone.saved_vars[&"guard_calmed"]) and ok
	zone.deactivate()
	zone.queue_free()
	await process_frame
	print("SMOKE: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _check(label: String, condition: bool) -> bool:
	print(("  ok   " if condition else "  FAIL ") + label)
	return condition
