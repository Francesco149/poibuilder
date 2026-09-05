## pb_material_card_drag.gd — Drag source helper for material cards in PBMaterialDock.
@tool
extends Button

var material_resource: Material = null

func _get_drag_data(_at_position: Vector2) -> Variant:
	if material_resource == null:
		return null

	var preview := TextureRect.new()
	if material_resource is StandardMaterial3D and material_resource.albedo_texture != null:
		preview.texture = material_resource.albedo_texture
	preview.custom_minimum_size = Vector2(48, 48)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	set_drag_preview(preview)

	var path := material_resource.resource_path
	var files := PackedStringArray([path]) if not path.is_empty() else PackedStringArray()
	return {
		"type": "poibuilder_material",
		"material": material_resource,
		"files": files
	}
