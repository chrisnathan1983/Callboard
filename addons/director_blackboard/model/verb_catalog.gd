@tool
class_name VerbCatalog extends RefCounted
## Discovers verb signatures and zone props for the Rule Board.

## [{name, args: [{name, type, class, default: expr text or ""}]}], sorted by name.
static func from_factory(factory: CoreVerbs) -> Array:
	return _from_object(factory)

## Script-authored rules still call methods on the Zone.
static func from_zone(zone: Zone) -> Array:
	return _from_object(zone)

static func _from_object(source: Object) -> Array:
	var out: Array = []
	for m in source.get_method_list():
		var verb: String = m["name"]
		if verb.begins_with("_"):
			continue
		var ret: Dictionary = m.get("return", {})
		if ret.get("class_name", "") != "Step":
			continue
		var margs: Array = m["args"]
		var defs: Array = m["default_args"]
		var first_def := margs.size() - defs.size()
		var args: Array = []
		for i in margs.size():
			var a: Dictionary = margs[i]
			args.append({"name": String(a["name"]), "type": a["type"], "class": String(a.get("class_name", "")),
				"default": ZoneSource.format_literal(defs[i - first_def]) if i >= first_def else ""})
		out.append({"name": verb, "args": args})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	return out

## [{name, class}] for every typed object variable the zone script declares (its props).
static func props_of(zone: Zone) -> Array:
	var out: Array = []
	for p in zone.get_property_list():
		if p["name"] in [&"definition", &"bb", &"engine", &"verbs"]:
			continue
		if (p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE) and p["type"] == TYPE_OBJECT and String(p.get("class_name", "")) != "":
			out.append({"name": String(p["name"]), "class": String(p["class_name"])})
	return out

static func find(catalog: Array, verb: String) -> Dictionary:
	for v in catalog:
		if v["name"] == verb:
			return v
	return {}

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
	return {"verb": verb, "args": args, "delay": "", "emits": "", "sets": []}
