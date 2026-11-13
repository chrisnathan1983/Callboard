@tool
class_name Blackboard extends RefCounted

signal changed(key: StringName, value: Variant)

var schema := {}
var local := {}
var saved: Dictionary          # injected by the manager
var _saved_names := {}        # saved storage key -> current Blackboard name

func _init(p_saved := {}) -> void:
	saved = p_saved

func define(key: StringName, scope: StringName, default: Variant, state_key: StringName = &"") -> void:
	var previous: Dictionary = schema.get(key, {})
	var storage_key: StringName = previous.get("state_key", key) if state_key.is_empty() else state_key
	if previous.get("scope") == &"saved":
		_saved_names.erase(previous["state_key"])
	schema[key] = {"scope": scope, "default": default, "state_key": storage_key}
	if scope == &"saved":
		_saved_names[storage_key] = key
		if not saved.has(storage_key): saved[storage_key] = default
	else:
		local[key] = default

func get_var(key: StringName) -> Variant:
	key = resolve_key(key)
	var entry: Dictionary = schema.get(key, {})
	return saved.get(entry["state_key"]) if entry.get("scope") == &"saved" else local.get(key)

func write(key: StringName, value: Variant) -> void:
	key = resolve_key(key)
	if not schema.has(key):
		push_error("Undeclared Blackboard key '%s'" % key)
		return
	var entry: Dictionary = schema.get(key, {})
	if entry.get("scope") == &"saved":
		saved[entry["state_key"]] = value
	else:
		local[key] = value
	changed.emit(key, value)

## Let gameplay code using an original saved name continue to access a renamed key.
func resolve_key(key: StringName) -> StringName:
	return key if schema.has(key) else _saved_names.get(key, key)

func is_set(key: StringName) -> bool:
	return bool(get_var(key))

func has(key: StringName) -> bool:
	return schema.has(resolve_key(key))
