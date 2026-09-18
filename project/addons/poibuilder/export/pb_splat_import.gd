## PBSplatImport — rebuilds live splat materials from a modern "include" export.
##
## A modern .glb export in INCLUDE mode keeps the splat stack as data: the
## geometry carries its mask coordinates (ARRAY_CUSTOM0, which glTF stores as
## TEXCOORD_2 and Godot restores as CUSTOM0 on import), each painted face's
## material carries a `poi_splat` record in its glTF extras, and every mask,
## layer texture and decal channel rides as a PNG beside the .glb
## (`<name>.splat/`).
##
## This is the Godot half of that contract — it walks an imported scene, reads
## each material's extras, loads the sidecar PNGs and installs a splat
## ShaderMaterial on the matching surface, so the imported mesh is paint-editable
## again. Other engines implement the same recipe by hand; the blend maths is
## documented in `docs/modern_glb_splat.md` (with a reference shader).
##
## Usage:
##     var root: Node = load("res://exported.glb").instantiate()
##     PBSplatImport.rebuild_from_extras(root)          # sidecars sit next to the .glb
##     # or, when the scene was moved away from its .glb:
##     PBSplatImport.rebuild_from_extras(root, "res://maps/exported.glb")
@tool
class_name PBSplatImport
extends RefCounted


## Restores splat materials wherever a `poi_splat` record is found.
## `glb_path` overrides the sidecar directory (defaults to the imported scene's
## own file path). Returns the number of surfaces rebuilt.
static func rebuild_from_extras(root: Node, glb_path: String = "") -> int:
	if root == null:
		return 0
	var base_dir := _resolve_base_dir(root, glb_path)
	var rebuilt := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var mat := mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			var records := _records_of(mat)
			if records.is_empty():
				continue
			var built := _build_material(records[0], base_dir)
			if built == null:
				continue
			mi.set_surface_override_material(s, built)
			rebuilt += 1
	return rebuilt


static func _resolve_base_dir(root: Node, glb_path: String) -> String:
	if not glb_path.is_empty():
		return glb_path.get_base_dir()
	var path := ""
	if root is Node and not (root as Node).scene_file_path.is_empty():
		path = (root as Node).scene_file_path
	elif root != null and root.owner != null and not root.owner.scene_file_path.is_empty():
		path = root.owner.scene_file_path
	if path.is_empty():
		return ""
	# Imported scenes live at res://x.glb.imported/... — the sidecars sit beside
	# the SOURCE file, which is what the exporter recorded relative to.
	var src := _imported_source_of(path)
	return src.get_base_dir() if not src.is_empty() else path.get_base_dir()


## Maps an imported resource path back to its source file when it points into
## the `.godot/imported` cache (`res://x.glb.imported/....scn` -> `res://x.glb`).
static func _imported_source_of(path: String) -> String:
	var marker := path.find(".imported/")
	if marker < 0:
		return path
	var base := path.substr(0, marker)
	if ResourceLoader.exists(base):
		return base
	return path


static func _records_of(mat: Material) -> Array:
	if mat == null or not mat.has_meta("extras"):
		return []
	var extras = mat.get_meta("extras")
	if not (extras is Dictionary):
		return []
	var records = (extras as Dictionary).get("poi_splat", [])
	return records if records is Array else []


## Builds one splat material from a record: base look from the material the
## record was attached to is not needed (the record's layers use their own
## sidecar textures), so the material comes out white-base unless the record
## names a base texture.
static func _build_material(record: Dictionary, base_dir: String) -> ShaderMaterial:
	if not (record is Dictionary):
		return null
	var mat := PBSplat.create_splat_material()
	if mat == null:
		return null
	for layer in record.get("layers", []):
		if not (layer is Dictionary):
			continue
		var tex_path := _sidecar_path(base_dir, String(layer.get("texture", "")))
		var mask_path := _sidecar_path(base_dir, String(layer.get("mask", "")))
		if tex_path.is_empty() or mask_path.is_empty():
			continue
		var tex_img := _load_sidecar_image(tex_path)
		var mask_img := _load_sidecar_image(mask_path)
		if tex_img == null or mask_img == null:
			continue
		if mask_img.get_format() != Image.FORMAT_R8:
			mask_img.convert(Image.FORMAT_R8)
		var color := Color.WHITE
		var c = layer.get("color", null)
		if c is Array and (c as Array).size() >= 4:
			color = Color(c[0], c[1], c[2], c[3])
		var slot := PBSplat.add_layer(mat, ImageTexture.create_from_image(tex_img), color,
				float(layer.get("roughness", 0.8)), mask_img.get_width())
		if slot <= 0:
			continue
		# The mask travels as an image; keep it in the CPU cache so painting,
		# undo snapshots and the bakers see it exactly like a live mask.
		mat.set_shader_parameter("layer_%d_mask" % slot, ImageTexture.create_from_image(mask_img))
		PBSplat._set_cached_image(mat, "layer_%d" % slot, mask_img)
	var decal_path := _sidecar_path(base_dir, String(record.get("decal", "")))
	var decal_img := _load_sidecar_image(decal_path)
	if decal_img != null:
		if decal_img.get_format() != Image.FORMAT_RGBA8:
			decal_img.convert(Image.FORMAT_RGBA8)
		mat.set_shader_parameter("stamp_layer_enabled", true)
		mat.set_shader_parameter("stamp_layer_texture", ImageTexture.create_from_image(decal_img))
		PBSplat._set_cached_image(mat, "stamp", decal_img)
	return mat


## Sidecars sit next to the .glb and are usually NOT imported resources (an
## export folder is often .gdignore'd), so they load as raw images when the
## resource loader cannot see them.
static func _load_sidecar_image(path: String) -> Image:
	if path.is_empty():
		return null
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex != null:
			var img := tex.get_image()
			if img != null:
				if img.is_compressed():
					img.decompress()
				return img
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			return img
	return null


static func _sidecar_path(base_dir: String, rel: String) -> String:
	if rel.is_empty():
		return ""
	if rel.begins_with("res://") or rel.begins_with("user://"):
		return rel
	return base_dir.path_join(rel) if not base_dir.is_empty() else rel
