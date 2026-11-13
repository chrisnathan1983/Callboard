@tool
class_name Blackboard extends RefCounted

signal changed(key: StringName, value: Variant)

var schema := {}
var local := {}
var saved: Dictionary          # injected by the manager
var _saved_names := {}        # saved storage key -> current Blackboard name
var _aliases: Dictionary = {} # original Blackboard name -> current name

func _init(p_saved := {}) -> void:
	saved = p_saved

func define(key: StringName, scope: StringName, default: Variant, state_key: StringName = &"") -> void:
	var previous: Dictionary = schema.get(key, {})
	var storage_key: StringName = previous.get("state_key", key) if state_key.is_empty() else state_key
	if previous.get("scope") == &"saved":
		_saved_names.erase(previous["state_key"])
	schema[key] = {"scope": scope, "default": default, "state_key": storage_key, "type": typeof(default)}
	if scope == &"saved":
		_saved_names[storage_key] = key
		if not saved.has(storage_key):
			saved[storage_key] = default
		elif typeof(saved[storage_key]) != typeof(default):
			push_warning("Saved Blackboard value '%s' changed type; restoring its declared default." % storage_key)
			saved[storage_key] = default
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
	if typeof(value) != entry["type"]:
		push_warning("Blackboard write to '%s' rejected: expected type %d, got %d." % [key, entry["type"], typeof(value)])
		return
	if entry.get("scope") == &"saved":
		saved[entry["state_key"]] = value
	else:
		local[key] = value
	changed.emit(key, value)

## Let gameplay code using an original saved name continue to access a renamed key.
func resolve_key(key: StringName) -> StringName:
	if schema.has(key):
		return key
	var resolved: StringName = key
	var visited := {}
	while _aliases.has(resolved) and not visited.has(resolved):
		visited[resolved] = true
		resolved = _aliases[resolved]
	if schema.has(resolved):
		return resolved
	return _saved_names.get(key, key)

## Preserve gameplay references when any authored key is renamed.
func alias(old_key: StringName, new_key: StringName) -> void:
	_aliases[old_key] = new_key

func is_set(key: StringName) -> bool:
	return bool(get_var(key))

func has(key: StringName) -> bool:
	return schema.has(resolve_key(key))
