@tool
class_name VerbCatalog extends RefCounted
## Discovers verb signatures and stage props for the Callboard.

## [{name, args: [{name, type, class, default: expr text or ""}]}], sorted by name.
static func from_factory(factory: CoreVerbs) -> Array:
	return RuntimeVerbCatalog.from_factory(factory)

## [{name, class}] for every typed object variable the stage script declares (its props).
static func props_of(stage: Stage) -> Array:
	return RuntimeVerbCatalog.props_of(stage)

static func find(catalog: Array, verb: String) -> Dictionary:
	return RuntimeVerbCatalog.find(catalog, verb)

## Replace an argument expression, keeping any intervening optional defaults.
static func set_arg(data: Dictionary, step: Dictionary, index: int, expression: String) -> void:
	var params: Array = find(data["catalog"], step["verb"])["args"]
	var args: Array = step["args"]
	while args.size() < index:
		var param: Dictionary = params[args.size()]
		args.append(param["default"] if param["default"] != "" else fallback(param, data))
	if args.size() == index:
		args.append(expression)
	else:
		args[index] = expression

static func prop_fits(prop_class: String, param_class: String) -> bool:
	return param_class == "" or prop_class == param_class or ClassDB.is_parent_class(prop_class, param_class)

## A reasonable starting expression for a parameter that has no default.
static func fallback(param: Dictionary, data: Dictionary) -> String:
	match param["type"]:
		TYPE_OBJECT:
			for p in data["props"]:
				if prop_fits(p["class"], param["class"]):
					return p["name"]
			return "null"
		TYPE_BOOL:
			return "true"
		TYPE_INT:
			return "0"
		TYPE_FLOAT:
			return "1.0"
		TYPE_STRING:
			return '"text"'
		TYPE_STRING_NAME:
			if param["name"] == "key" and not data["vars"].is_empty():
				return '&"%s"' % data["vars"][0]["key"]
			return '&""'
		TYPE_VECTOR3:
			return "Vector3.ZERO"
	return "true"

## A new step for `verb` with every required argument filled in and optional ones omitted.
static func new_step(data: Dictionary, verb: String) -> Dictionary:
	var entry := find(data["catalog"], verb)
	var params: Array = entry.get("args", [])
	var last_required := -1
	for i in params.size():
		if params[i]["default"] == "":
			last_required = i
	var args: Array = []
	for i in last_required + 1:
		args.append(params[i]["default"] if params[i]["default"] != "" else fallback(params[i], data))
	return AuthoredData.new_step(verb, args)
