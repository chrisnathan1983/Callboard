@tool
class_name GroupData extends Resource
## Serializable visual grouping for rule cards.

@export var name := "Group"
@export var rect := Rect2(40, 40, 400, 300)

static func from_dictionary(source: Dictionary) -> GroupData:
	var data := GroupData.new()
	data.name = String(source.get("name", "Group"))
	data.rect = source.get("rect", Rect2(40, 40, 400, 300))
	return data

func to_dictionary() -> Dictionary:
	return {"name": name, "rect": rect}
