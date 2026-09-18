## PBPaintController — Interactive controller for Texture Splatting and Decals.
##
## Paint Mode drags a brush over splat layers (blend weights) or over the decal
## layer (paints the selected image), Stamp Mode pastes an image as a decal in
## one click (live preview, wheel rotation, ctrl+wheel scaling). Stamps are
## PIXELS in the surface's decal layer, not scene nodes: a stamp may span
## several faces, and parts of it can be erased or repainted with the brush.
@tool
class_name PBPaintController
extends RefCounted

enum Mode { NONE, PAINT, STAMP }

## What the paint brush writes into: a splat layer's blend weight, or the
## decal layer's pixels (the same layer stamps paste into).
enum PaintTarget { SPLAT, DECAL }

# Constants
const RAY_MISS := Vector3(INF, INF, INF)
const PREVIEW_NODE_NAME := "PBSplatPreviewNode"

# Active mode
var mode: Mode = Mode.NONE

# Paint brush properties
var brush_radius: float = 0.5:
	set(v):
		brush_radius = maxf(0.01, v)
		_update_preview_mesh()
		brush_changed.emit()
var brush_softness: float = 0.5:
	set(v):
		brush_softness = clampf(v, 0.0, 1.0)
		brush_changed.emit()
var brush_opacity: float = 1.0:
	set(v):
		brush_opacity = clampf(v, 0.01, 1.0)
		brush_changed.emit()
var erase_mode: bool = false:
	set(v):
		erase_mode = v
		_update_preview_material()
		brush_changed.emit()
var paint_target: PaintTarget = PaintTarget.SPLAT:
	set(v):
		paint_target = v
		brush_changed.emit()
var active_layer_idx: int = 1:
	set(v):
		active_layer_idx = clampi(v, 1, PBSplat.MAX_LAYERS)
		brush_changed.emit()
var paint_texture: Texture2D = null:
	set(v):
		paint_texture = v
		_cached_paint_image = null
		brush_changed.emit()

var _texture_layer_map: Dictionary = {}

func set_paint_texture_and_update_layer(tex: Texture2D) -> void:
	paint_texture = tex
	if tex == null:
		return

	var mesh: PBMesh = target_mesh
	if mesh == null and plugin != null and plugin.editor != null:
		mesh = plugin.editor.active_mesh

	if mesh != null and mesh.pb_mesh_data != null:
		var data := mesh.pb_mesh_data
		var face: PBFace = null
		if target_face_idx >= 0 and target_face_idx < data.faces.size():
			face = data.faces[target_face_idx]
		elif plugin != null and plugin.editor != null and plugin.editor.selection != null:
			var sel_faces = plugin.editor.selection.selected_faces
			if not sel_faces.is_empty() and sel_faces[0] >= 0 and sel_faces[0] < data.faces.size():
				face = data.faces[sel_faces[0]]

		if face != null:
			var splat_mat = data.get_face_material(face)
			if PBSplat.is_splat_material(splat_mat):
				var sm := splat_mat as ShaderMaterial
				var existing := -1
				for i in range(1, PBSplat.MAX_LAYERS + 1):
					if sm.get_shader_parameter("layer_%d_enabled" % i) == true:
						if sm.get_shader_parameter("layer_%d_texture" % i) == tex:
							existing = i
							break
				if existing > 0:
					active_layer_idx = existing
					return
				else:
					var target_res := PBSplat.calculate_uniform_face_resolution(data, face)
					var new_slot := PBSplat.add_layer(sm, tex, Color.WHITE, 0.8, target_res.x)
					if new_slot > 0:
						active_layer_idx = new_slot
						return

	# If not yet assigned on this material, map to next layer index
	if _texture_layer_map.has(tex):
		active_layer_idx = _texture_layer_map[tex]
	else:
		var next_idx := clampi(_texture_layer_map.size() + 1, 1, PBSplat.MAX_LAYERS)
		_texture_layer_map[tex] = next_idx
		active_layer_idx = next_idx
# Stamp properties
var stamp_texture: Texture2D = null:
	set(v):
		stamp_texture = v
		_cached_stamp_image = null
		_update_stamp_preview_texture()
		stamp_changed.emit()
## Width of the pasted decal in metres; the height follows the image's aspect.
var stamp_scale: float = 1.0:
	set(v):
		stamp_scale = clampf(v, 0.05, 50.0)
		_update_preview_mesh()
		stamp_changed.emit()
var stamp_rotation: float = 0.0:
	set(v):
		stamp_rotation = wrapf(v, 0.0, 360.0)
		_update_preview_mesh()
		stamp_changed.emit()
var stamp_opacity: float = 1.0:
	set(v):
		stamp_opacity = clampf(v, 0.01, 1.0)
		_update_preview_material()
		stamp_changed.emit()

## What the decal brush writes: a solid brush colour, or the palette image.
enum BrushSource { COLOR, IMAGE }

## Source the decal brush paints with (see BrushSource).
var brush_source: BrushSource = BrushSource.COLOR:
	set(v):
		brush_source = v
		brush_changed.emit()
## Colour the decal brush paints (used when brush_source == COLOR).
var brush_color: Color = Color(0.85, 0.32, 0.24, 1.0):
	set(v):
		brush_color = Color(v.r, v.g, v.b, v.a)
		_update_preview_material()
		brush_changed.emit()

# Cached CPU Images of the paint / stamp textures (decoded once, sampled per dab)
var _cached_paint_image: Image = null
var _cached_stamp_image: Image = null

# Hit tracking
var has_hit: bool = false
var cursor_point: Vector3 = Vector3.ZERO
var cursor_normal: Vector3 = Vector3.UP
var target_mesh: PBMesh = null
var target_face_idx: int = -1

# Stroke tracking for Paint mode
var is_stroke_active: bool = false
var stroke_dirty: bool = false
var stroke_snapshot_before: PBMeshData = null
var _stroke_meshes: Dictionary = {} # PBMesh -> {"before": PBMeshData, "dirty": bool}
# semantics for paint, once-per-pixel for erase). Fresh per stroke.
var _stroke_ctx: Dictionary = {}
# Dab spacing: the stroke only re-paints after the cursor traveled at least
# this fraction of the brush radius from the last dab. Painting per raw mouse
# motion event re-walks thousands of mask pixels per event at 256 texels/m —
# spacing dabs keeps strokes continuous while capping the CPU cost per second.
const DAB_SPACING_FRACTION := 0.2
var _stroke_last_dab_local: Vector3 = Vector3.INF
var _stroke_last_dab_mesh: PBMesh = null

# Visual preview nodes
var preview_root: Node3D = null
var brush_mesh_instance: MeshInstance3D = null
var stamp_mesh_instance: MeshInstance3D = null

# Callback references
var plugin: EditorPlugin = null

# Signals
signal mode_changed(new_mode: Mode)
signal brush_changed()
signal stamp_changed()
signal stroke_committed()

# ==============================================================================
# Lifecycle & Activation
# ==============================================================================

func is_active() -> bool:
	return mode != Mode.NONE

func set_mode(new_mode: Mode) -> void:
	if mode == new_mode:
		return
	if is_stroke_active:
		end_stroke()
	mode = new_mode
	if mode == Mode.STAMP:
		_update_stamp_preview_texture()
		_build_stamp_mesh()
	_update_preview_visibility()
	mode_changed.emit(mode)

func reset() -> void:
	if is_stroke_active:
		end_stroke()
	mode = Mode.NONE
	target_mesh = null
	target_face_idx = -1
	has_hit = false
	_update_preview_visibility()
	mode_changed.emit(mode)

func setup_previews(parent_node: Node) -> void:
	if parent_node == null:
		return
	if preview_root != null and is_instance_valid(preview_root):
		return

	preview_root = Node3D.new()
	preview_root.name = PREVIEW_NODE_NAME
	# Marks the subtree for PBMapExporter's tooling skip (it lives in the live
	# scene, so a name-only guard is one rename away from leaking into maps).
	preview_root.set_meta("poi_editor_preview", true)
	parent_node.add_child(preview_root)

	# 1. Brush Ring Preview (Immediate/Torus/Cylinder wireframe)
	brush_mesh_instance = MeshInstance3D.new()
	brush_mesh_instance.name = "BrushRing"
	preview_root.add_child(brush_mesh_instance)

	var brush_mat := StandardMaterial3D.new()
	brush_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	brush_mat.albedo_color = Color(0.2, 0.85, 1.0, 0.9)
	brush_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	brush_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	brush_mat.no_depth_test = true
	brush_mat.render_priority = 100
	brush_mesh_instance.material_override = brush_mat

	# 2. Stamp Decal Preview (Textured Quad)
	stamp_mesh_instance = MeshInstance3D.new()
	stamp_mesh_instance.name = "StampQuad"
	preview_root.add_child(stamp_mesh_instance)

	# Unshaded, unclipped preview: the decal is painted as PIXELS across every
	# face it touches, so what you see is where it will land — including the
	# part that overhangs an edge.
	var stamp_mat := StandardMaterial3D.new()
	stamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	stamp_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	stamp_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	stamp_mat.no_depth_test = true
	stamp_mat.render_priority = 100
	stamp_mat.albedo_texture = stamp_texture
	stamp_mesh_instance.material_override = stamp_mat

	_update_stamp_preview_texture()
	_update_preview_mesh()
	_update_preview_visibility()

func cleanup_previews() -> void:
	if preview_root != null and is_instance_valid(preview_root):
		preview_root.queue_free()
		preview_root = null
		brush_mesh_instance = null
		stamp_mesh_instance = null

# ==============================================================================
# Preview Mesh Updates
# ==============================================================================

func _update_preview_visibility() -> void:
	if preview_root == null or not is_instance_valid(preview_root):
		return
	preview_root.visible = (mode != Mode.NONE and has_hit)
	if brush_mesh_instance != null:
		brush_mesh_instance.visible = (mode == Mode.PAINT and has_hit)
	if stamp_mesh_instance != null:
		stamp_mesh_instance.visible = (mode == Mode.STAMP and has_hit)

func _update_preview_mesh() -> void:
	if mode == Mode.PAINT and brush_mesh_instance != null:
		_build_brush_mesh()
	elif mode == Mode.STAMP and stamp_mesh_instance != null:
		_build_stamp_mesh()

func _update_preview_material() -> void:
	if brush_mesh_instance != null and brush_mesh_instance.material_override != null:
		var mat := brush_mesh_instance.material_override as StandardMaterial3D
		if erase_mode:
			mat.albedo_color = Color(1.0, 0.35, 0.3, 0.9) # Reddish for erase
		elif paint_target == PaintTarget.DECAL and brush_source == BrushSource.COLOR:
			# The ring wears the colour it paints.
			mat.albedo_color = Color(brush_color.r, brush_color.g, brush_color.b, 0.9)
		else:
			mat.albedo_color = Color(0.2, 0.85, 1.0, 0.9) # Cyan for paint

	if stamp_mesh_instance != null and stamp_mesh_instance.material_override != null:
		var tint := Color(1.0, 1.0, 1.0, stamp_opacity)
		var mat := stamp_mesh_instance.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = tint

func _update_stamp_preview_texture() -> void:
	var mat := stamp_mesh_instance.material_override as StandardMaterial3D if stamp_mesh_instance != null else null
	if mat != null:
		mat.albedo_texture = stamp_texture
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 1.0, 1.0, stamp_opacity)

func _build_brush_mesh() -> void:
	if brush_mesh_instance == null:
		return
	var im := ImmediateMesh.new()
	var segments := 48
	var r := brush_radius

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(segments):
		var theta1 := (float(i) / float(segments)) * TAU
		var theta2 := (float(i + 1) / float(segments)) * TAU
		var p1 := Vector3(cos(theta1) * r, 0.0, sin(theta1) * r)
		var p2 := Vector3(cos(theta2) * r, 0.0, sin(theta2) * r)
		im.surface_add_vertex(p1)
		im.surface_add_vertex(p2)
	# Crosshair at center
	var cr := r * 0.15
	im.surface_add_vertex(Vector3(-cr, 0.0, 0.0))
	im.surface_add_vertex(Vector3(cr, 0.0, 0.0))
	im.surface_add_vertex(Vector3(0.0, 0.0, -cr))
	im.surface_add_vertex(Vector3(0.0, 0.0, cr))
	im.surface_end()

	brush_mesh_instance.mesh = im

func _build_stamp_mesh() -> void:
	if stamp_mesh_instance == null:
		return
	# The preview matches the paste: `stamp_scale` is the stamp's WIDTH in
	# metres and the height follows the image's aspect ratio (a 4:1 banner must
	# preview — and land — 4:1, not squished into a square).
	var qm := QuadMesh.new()
	var aspect := 1.0
	if stamp_texture != null and stamp_texture.get_width() > 0:
		aspect = float(stamp_texture.get_height()) / float(stamp_texture.get_width())
	qm.size = Vector2(stamp_scale, stamp_scale * aspect)
	stamp_mesh_instance.mesh = qm

# ==============================================================================
# Cursor Updates & Transform
# ==============================================================================

func update_cursor(point: Vector3, normal: Vector3, mesh_node: PBMesh, face_idx: int) -> void:
	has_hit = true
	cursor_point = point
	cursor_normal = normal.normalized()
	target_mesh = mesh_node
	target_face_idx = face_idx

	if preview_root == null or not is_instance_valid(preview_root):
		return

	preview_root.visible = true
	# Canonical stamp basis matching PBSplat.get_stamp_basis
	var sbasis := PBSplat.get_stamp_basis(cursor_normal)
	var u_right: Vector3 = sbasis["right"]
	var v_up: Vector3 = sbasis["up"]
	var n_axis: Vector3 = sbasis["normal"]

	# Normal offset to eliminate z-fighting
	var offset_point := cursor_point + n_axis * 0.005

	if mode == Mode.PAINT and brush_mesh_instance != null:
		var xf := Transform3D(Basis(u_right, n_axis, v_up), offset_point)
		brush_mesh_instance.global_transform = xf
		brush_mesh_instance.visible = true
		if stamp_mesh_instance != null:
			stamp_mesh_instance.visible = false

	elif mode == Mode.STAMP and stamp_mesh_instance != null:
		# Apply stamp rotation in the surface plane around normal
		var rot_rad := deg_to_rad(stamp_rotation)
		var rot_right := cos(rot_rad) * u_right + sin(rot_rad) * v_up
		var rot_up := -sin(rot_rad) * u_right + cos(rot_rad) * v_up
		var xf := Transform3D(Basis(rot_right, rot_up, n_axis), offset_point)
		stamp_mesh_instance.global_transform = xf
		stamp_mesh_instance.visible = true
		if brush_mesh_instance != null:
			brush_mesh_instance.visible = false

func clear_cursor() -> void:
	has_hit = false
	target_mesh = null
	target_face_idx = -1
	_update_preview_visibility()

## The mesh's own scale as "world metres per local metre" (1.0 for the usual
## unscaled mesh). Brush and stamp sizes are metres the user reads on screen,
## and the decal layer's texel density is per WORLD metre too, so both convert
## through this: a mesh scaled 4x used to paint a quarter-density decal.
static func decal_world_density(mesh: Node3D) -> float:
	if mesh == null:
		return 1.0
	var s := mesh.global_transform.basis.get_scale()
	var avg := (s.x + s.y + s.z) / 3.0
	if avg <= 0.000001:
		return 1.0
	return clampf(avg, 0.05, 16.0)

## `cursor_normal` arrives in WORLD space (the pick ray works on the scene) but
## a decal write happens in the mesh's local space.
func local_normal(mesh: Node3D) -> Vector3:
	if mesh == null:
		return cursor_normal
	var n := mesh.global_transform.basis.inverse() * cursor_normal
	if n.length_squared() < 0.000001:
		return cursor_normal
	return n.normalized()

# ==============================================================================
# Paint Stroke Execution
# ==============================================================================

func _register_stroke_mesh(mesh: PBMesh) -> void:
	if mesh == null or not is_instance_valid(mesh) or mesh.pb_mesh_data == null:
		return
	if not _stroke_meshes.has(mesh):
		_stroke_meshes[mesh] = {
			"before": PBCommand.copy_mesh_data(mesh.pb_mesh_data),
			"dirty": false
		}
		PBSplat.ensure_mesh_splat_uv(mesh.pb_mesh_data)

func begin_stroke() -> void:
	if mode != Mode.PAINT or target_mesh == null or target_mesh.pb_mesh_data == null:
		return
	is_stroke_active = true
	stroke_dirty = false
	_stroke_meshes.clear()
	_register_stroke_mesh(target_mesh)
	stroke_snapshot_before = _stroke_meshes[target_mesh]["before"] if _stroke_meshes.has(target_mesh) else null
	_stroke_ctx = {}
	_stroke_last_dab_local = Vector3.INF
	_stroke_last_dab_mesh = null
	apply_paint_stroke()

func apply_paint_stroke() -> void:
	if not is_stroke_active or target_mesh == null or target_mesh.pb_mesh_data == null or not has_hit:
		return

	_register_stroke_mesh(target_mesh)

	var data := target_mesh.pb_mesh_data
	if target_face_idx < 0 or target_face_idx >= data.faces.size():
		return

	var face := data.faces[target_face_idx]
	if face == null:
		return

	# Dab spacing: skip motion events that did not travel far enough from the
	# last dab (a dab covering the brush footprint re-walks its pixels; at high
	# motion-event rates that is pure redundant CPU on every event).
	if _stroke_last_dab_mesh == target_mesh:
		var spacing := maxf(brush_radius * DAB_SPACING_FRACTION, 0.01)
		var local_now: Vector3 = target_mesh.global_transform.affine_inverse() * cursor_point
		if _stroke_last_dab_local.distance_squared_to(local_now) < spacing * spacing:
			return

	# Convert world hit point to node local coordinates
	var local_hit: Vector3 = target_mesh.global_transform.affine_inverse() * cursor_point

	var modified := false
	if paint_target == PaintTarget.DECAL:
		# Decal dabs write PIXELS into the layer: either the basic brush's
		# solid colour or the palette image; erase fades the layer's alpha.
		var decal_img := get_paint_image() if brush_source == BrushSource.IMAGE else null
		if decal_img != null or erase_mode or brush_color.a > 0.0:
			var dens := decal_world_density(target_mesh)
			modified = PBSplat.paint_decal_dab(data, local_hit, local_normal(target_mesh),
					stamp_rotation, brush_radius / dens, brush_softness, brush_opacity,
					erase_mode, decal_img, brush_color,
					PBSplat.DECAL_TEXELS_PER_M * dens) > 0
	else:
		var splat_mat := _ensure_face_splat_material(target_mesh, face)
		if splat_mat == null:
			return
		# Ensure a layer exists for paint_texture on splat_mat
		if paint_texture != null:
			var layer := PBSplat.ensure_layer_for_texture(splat_mat, paint_texture)
			if layer > 0:
				active_layer_idx = layer
		# Paint on target face under cursor
		modified = PBSplat.paint_face_splat(
			data, face, splat_mat, active_layer_idx,
			local_hit, brush_radius, brush_softness, brush_opacity, erase_mode,
			_stroke_ctx
		)

	_stroke_last_dab_local = local_hit
	_stroke_last_dab_mesh = target_mesh

	if modified:
		stroke_dirty = true
		if _stroke_meshes.has(target_mesh):
			_stroke_meshes[target_mesh]["dirty"] = true

func end_stroke() -> void:
	if not is_stroke_active:
		return
	is_stroke_active = false

	var to_commit: Dictionary = {}
	for mesh in _stroke_meshes:
		if mesh != null and is_instance_valid(mesh) and _stroke_meshes[mesh]["dirty"]:
			to_commit[mesh] = {
				"before": _stroke_meshes[mesh]["before"],
				"after": PBCommand.copy_mesh_data(mesh.pb_mesh_data)
			}

	_stroke_meshes.clear()

	if not to_commit.is_empty():
		_commit_multi_mesh_action("Paint Texture Splat", to_commit)
		stroke_committed.emit()

	stroke_snapshot_before = null
	stroke_dirty = false
# ==============================================================================
# Stamp Execution
# ==============================================================================

func apply_stamp() -> void:
	if mode != Mode.STAMP or target_mesh == null or not is_instance_valid(target_mesh) or not has_hit:
		return
	if stamp_texture == null:
		return
	var data := target_mesh.pb_mesh_data
	if data == null:
		return
	var img := get_stamp_image()
	if img == null:
		return

	var before := PBCommand.copy_mesh_data(data)
	var local_hit: Vector3 = target_mesh.global_transform.affine_inverse() * cursor_point
	# Paste as pixels: every face the oriented footprint reaches receives its
	# part of the image, so a stamp can cross an edge and continue on the
	# neighbour. Sizes are given in WORLD metres, the decal density follows the
	# node's own scale, and the normal is converted to the mesh's space — a
	# world normal against a local point smeared the decal on any moved or
	# rotated mesh.
	var dens := decal_world_density(target_mesh)
	var painted := PBSplat.paste_decal(data, local_hit, local_normal(target_mesh), stamp_rotation,
			stamp_scale / dens, stamp_opacity, img, PBSplat.DECAL_TEXELS_PER_M * dens)
	if painted <= 0:
		return

	_commit_multi_mesh_action("Paste Decal", {target_mesh: {
		"before": before,
		"after": PBCommand.copy_mesh_data(data),
	}})
	stroke_committed.emit()

## Clears the decal layer of every material on `mesh` (all stamps and painted
## decal pixels at once). Undoable through the mesh snapshot.
func clear_decal_layer(mesh: PBMesh) -> void:
	if mesh == null or not is_instance_valid(mesh) or mesh.pb_mesh_data == null:
		return
	var data := mesh.pb_mesh_data
	var before := PBCommand.copy_mesh_data(data)
	var cleared := false
	for m in data.materials:
		if PBSplat.is_splat_material(m) and PBSplat.has_decal_layer(m as ShaderMaterial):
			PBSplat.clear_decal_layer(m as ShaderMaterial)
			cleared = true
	if not cleared:
		return
	_commit_multi_mesh_action("Clear Decal Layer", {mesh: {
		"before": before,
		"after": PBCommand.copy_mesh_data(data),
	}})
## CPU image of the paint palette's current texture (the decal brush's source).
func get_paint_image() -> Image:
	if _cached_paint_image != null:
		return _cached_paint_image
	_cached_paint_image = _to_rgba8_image(paint_texture)
	return _cached_paint_image

static func _to_rgba8_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		var err := img.decompress()
		if err != OK:
			var uncompressed := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
			uncompressed.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i.ZERO)
			img = uncompressed
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img

func get_stamp_image() -> Image:
	if _cached_stamp_image != null:
		return _cached_stamp_image
	if stamp_texture == null:
		return null
	var img := stamp_texture.get_image()
	if img != null:
		if img.is_compressed():
			var err := img.decompress()
			if err != OK:
				var uncompressed := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
				uncompressed.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i.ZERO)
				img = uncompressed
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		_cached_stamp_image = img
	return _cached_stamp_image

# ==============================================================================
# Splat Material Assignment Helper
# ==============================================================================

func _ensure_face_splat_material(mesh: PBMesh, face: PBFace) -> ShaderMaterial:
	var current_mat := mesh.pb_mesh_data.get_face_material(face)
	if PBSplat.is_splat_material(current_mat):
		return current_mat as ShaderMaterial

	# Convert to splat material
	var splat_mat := PBSplat.create_splat_material(current_mat)
	# If a paint_texture is selected, configure layer 1 with uniform resolution for this face
	if paint_texture != null:
		var target_res := PBSplat.calculate_uniform_face_resolution(mesh.pb_mesh_data, face)
		PBSplat.add_layer(splat_mat, paint_texture, Color.WHITE, 0.8, target_res.x)

	mesh.pb_mesh_data.set_face_material(face, splat_mat)
	mesh.rebuild()
	mesh.update_gizmos()
	return splat_mat

# ==============================================================================
# Undo / Redo Helper
# ==============================================================================

func _commit_mesh_action(mesh: PBMesh, action_name: String, before: PBMeshData, after: PBMeshData) -> void:
	_commit_multi_mesh_action(action_name, {mesh: {"before": before, "after": after}})

func _commit_multi_mesh_action(action_name: String, mesh_entries: Dictionary) -> void:
	if mesh_entries.is_empty():
		return
	var meshes := mesh_entries.keys()
	for m in meshes:
		if m != null and is_instance_valid(m):
			m.rebuild()
			m.update_gizmos()
	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null:
			undo.create_action(action_name, UndoRedo.MERGE_DISABLE, meshes[0])
			for m in meshes:
				if m != null and is_instance_valid(m):
					var mid: int = m.get_instance_id()
					var entry: Dictionary = mesh_entries[m]
					undo.add_do_method(plugin, "_restore_mesh_snapshot", mid, entry["after"])
					undo.add_undo_method(plugin, "_restore_mesh_snapshot", mid, entry["before"])
			undo.commit_action()
