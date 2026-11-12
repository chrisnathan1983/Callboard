@tool
class_name ZonePreview extends RefCounted
## Compiles generated zone source in memory, builds it on an unparented instance, and runs
## Zone.validate(). This is the authority on whether an edit is safe to save: if the source
## does not compile it never reaches disk, and the same runtime validator the game uses
## reports wiring problems.

## Returns {ok, problems: Array[String], zone: Zone or null, script}. Call dispose() when done:
## the steps' lambdas must be released while the script that compiled them is still alive.
static func run(source: String) -> Dictionary:
	var script := GDScript.new()
	# class_name would collide with the already-registered zone class.
	script.source_code = RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*").sub(source, "", true)
	if script.reload() != OK:
		return {"ok": false, "zone": null, "problems": ["Script does not compile. See the Output panel for the error."]}
	var zone = script.new()
	if not zone is Zone:
		if zone is Node:
			zone.free()
		return {"ok": false, "zone": null, "problems": ["Script does not extend Zone."]}
	zone.build()
	var problems: Array = []
	for p in zone.validate():
		problems.append(p)
	return {"ok": true, "zone": zone, "problems": problems, "script": script}

static func dispose(result: Dictionary) -> void:
	var zone: Zone = result.get("zone")
	if zone:
		zone.engine.rules.clear()   # drops every Step and its lambda first
		zone.free()
	result.erase("zone")
	result.erase("script")
