@tool
class_name RuntimeVerbCatalog extends RefCounted
## Runtime-safe verb signatures and Stage prop discovery.

static func from_factory(factory: CoreVerbs) -> Array:
	var out: Array = []
	for method in factory.get_method_list():
		var verb: String = method["name"]
		if verb.begins_with("_"):
			continue
		var ret: Dictionary = method.get("return", {})
		if ret.get("class_name", "") != "Step":
			continue
		var method_args: Array = method["args"]
		var defaults: Array = method["default_args"]
		var first_default := method_args.size() - defaults.size()
		var args: Array = []
		for i in method_args.size():
			var argument: Dictionary = method_args[i]
			args.append({
				"name": String(argument["name"]), "type": argument["type"],
				"class": String(argument.get("class_name", "")),
				"default": ExprText.format_literal(defaults[i - first_default]) if i >= first_default else "",
			})
		out.append({"name": verb, "args": args})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	return out

static func props_of(stage: Stage) -> Array:
	var out: Array = []
	for property in stage.get_property_list():
		if property["name"] in [&"definition", &"bb", &"engine", &"verbs"]:
			continue
		if ((property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE)
				and property["type"] == TYPE_OBJECT
				and String(property.get("class_name", "")) != ""):
			out.append({"name": String(property["name"]), "class": String(property["class_name"])})
	return out

static func find(catalog: Array, verb: String) -> Dictionary:
	for entry in catalog:
		if entry["name"] == verb:
			return entry
	return {}
