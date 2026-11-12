@tool
class_name Blackboard extends RefCounted

signal changed(key: StringName, value: Variant)

var schema := {}
var local := {}
var saved: Dictionary          # injected by the manager

func _init(p_saved := {}) -> void:
	saved = p_saved

func define(key: StringName, scope: StringName, default: Variant) -> void:
	schema[key] = {"scope": scope, "default": default}
	if scope == &"saved":
		if not saved.has(key): saved[key] = default
	else:
		local[key] = default

func get_var(key: StringName) -> Variant:
	return saved.get(key) if schema.get(key, {}).get("scope") == &"saved" else local.get(key)

func write(key: StringName, value: Variant) -> void:
	assert(schema.has(key) or OS.is_debug_build() == false, "Undeclared key '%s'" % key)
	(saved if schema.get(key, {}).get("scope") == &"saved" else local)[key] = value
	changed.emit(key, value)

func is_set(key: StringName) -> bool:
	return bool(get_var(key))

func has(key: StringName) -> bool:
	return schema.has(key)
