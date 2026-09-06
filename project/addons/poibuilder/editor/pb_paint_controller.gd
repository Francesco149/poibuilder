## PBPaintController — Interactive controller for Texture Splatting and Stamping.
##
## Manages Paint Mode (brush painting with radius and softness over splat layers)
## and Stamp Mode (paste any texture/image anywhere on meshes with live preview,
## wheel rotation, and ctrl+wheel scaling).
@tool
class_name PBPaintController
extends RefCounted

enum Mode { NONE, PAINT, STAMP }

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
var active_layer_idx: int = 1:
	set(v):
		active_layer_idx = clampi(v, 1, PBSplat.MAX_LAYERS)
		brush_changed.emit()
var paint_texture: Texture2D = null:
	set(v):
		paint_texture = v
		brush_changed.emit()

# Stamp properties
var stamp_texture: Texture2D = null:
	set(v):
		stamp_texture = v
		_cached_stamp_image = null
		_update_stamp_preview_texture()
		stamp_changed.emit()
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

# Cached CPU Image of the stamp texture
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

	var stamp_mat := StandardMaterial3D.new()
	stamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	stamp_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	stamp_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	stamp_mat.no_depth_test = true
	stamp_mat.render_priority = 100
	stamp_mesh_instance.material_override = stamp_mat

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
		else:
			mat.albedo_color = Color(0.2, 0.85, 1.0, 0.9) # Cyan for paint

	if stamp_mesh_instance != null and stamp_mesh_instance.material_override != null:
		var mat := stamp_mesh_instance.material_override as StandardMaterial3D
		mat.albedo_color = Color(1.0, 1.0, 1.0, stamp_opacity)

func _update_stamp_preview_texture() -> void:
	if stamp_mesh_instance != null and stamp_mesh_instance.material_override != null:
		var mat := stamp_mesh_instance.material_override as StandardMaterial3D
		mat.albedo_texture = stamp_texture

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
	var im := ImmediateMesh.new()
	var half_s := stamp_scale * 0.5

	# 2D Quad in XZ plane with UVs
	var p0 := Vector3(-half_s, 0.0, -half_s)
	var p1 := Vector3(half_s, 0.0, -half_s)
	var p2 := Vector3(half_s, 0.0, half_s)
	var p3 := Vector3(-half_s, 0.0, half_s)

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	# Tri 1: p0, p1, p2
	im.surface_set_uv(Vector2(0, 0))
	im.surface_add_vertex(p0)
	im.surface_set_uv(Vector2(1, 0))
	im.surface_add_vertex(p1)
	im.surface_set_uv(Vector2(1, 1))
	im.surface_add_vertex(p2)
	# Tri 2: p0, p2, p3
	im.surface_set_uv(Vector2(0, 0))
	im.surface_add_vertex(p0)
	im.surface_set_uv(Vector2(1, 1))
	im.surface_add_vertex(p2)
	im.surface_set_uv(Vector2(0, 1))
	im.surface_add_vertex(p3)
	im.surface_end()

	# Border outline
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(p0)
	im.surface_add_vertex(p1)
	im.surface_add_vertex(p1)
	im.surface_add_vertex(p2)
	im.surface_add_vertex(p2)
	im.surface_add_vertex(p3)
	im.surface_add_vertex(p3)
	im.surface_add_vertex(p0)
	im.surface_end()

	stamp_mesh_instance.mesh = im

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

	# Construct orientation basis: Y aligned with surface normal
	var n := cursor_normal
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var tangent := n.cross(up).normalized()
	var bitangent := n.cross(tangent).normalized()

	# Normal offset to eliminate z-fighting
	var offset_point := cursor_point + n * 0.005

	if mode == Mode.PAINT and brush_mesh_instance != null:
		var xf := Transform3D(Basis(tangent, n, bitangent), offset_point)
		brush_mesh_instance.global_transform = xf
		brush_mesh_instance.visible = true
		if stamp_mesh_instance != null:
			stamp_mesh_instance.visible = false

	elif mode == Mode.STAMP and stamp_mesh_instance != null:
		# Apply stamp rotation around normal
		var rot_rad := deg_to_rad(stamp_rotation)
		var rot_tangent := cos(rot_rad) * tangent - sin(rot_rad) * bitangent
		var rot_bitangent := sin(rot_rad) * tangent + cos(rot_rad) * bitangent
		var xf := Transform3D(Basis(rot_tangent, n, rot_bitangent), offset_point)
		stamp_mesh_instance.global_transform = xf
		stamp_mesh_instance.visible = true
		if brush_mesh_instance != null:
			brush_mesh_instance.visible = false

func clear_cursor() -> void:
	has_hit = false
	target_mesh = null
	target_face_idx = -1
	_update_preview_visibility()

# ==============================================================================
# Paint Stroke Execution
# ==============================================================================

func begin_stroke() -> void:
	if mode != Mode.PAINT or target_mesh == null or target_mesh.pb_mesh_data == null:
		return
	is_stroke_active = true
	stroke_dirty = false
	stroke_snapshot_before = PBCommand.copy_mesh_data(target_mesh.pb_mesh_data)
	apply_paint_stroke()

func apply_paint_stroke() -> void:
	if not is_stroke_active or target_mesh == null or target_mesh.pb_mesh_data == null or not has_hit:
		return

	var data := target_mesh.pb_mesh_data
	if target_face_idx < 0 or target_face_idx >= data.faces.size():
		return

	var face := data.faces[target_face_idx]
	if face == null:
		return

	var splat_mat := _ensure_face_splat_material(target_mesh, face)
	if splat_mat == null:
		return

	# Ensure UV2 channel is present for mask sampling
	PBSplat.ensure_mesh_uv2(data)

	# Convert world hit point to node local coordinates
	var local_hit: Vector3 = target_mesh.global_transform.affine_inverse() * cursor_point

	# Paint on target face
	var modified := PBSplat.paint_face_splat(
		data, face, splat_mat, active_layer_idx,
		local_hit, brush_radius, brush_softness, brush_opacity, erase_mode
	)

	if modified:
		stroke_dirty = true

	# Also paint any adjacent faces within brush radius
	for i in range(data.faces.size()):
		if i == target_face_idx:
			continue
		var other_face := data.faces[i]
		if other_face == null:
			continue
		# Only paint if other face shares the same splat material
		var other_mat = data.get_face_material(other_face)
		if other_mat == splat_mat:
			var other_mod := PBSplat.paint_face_splat(
				data, other_face, splat_mat, active_layer_idx,
				local_hit, brush_radius, brush_softness, brush_opacity, erase_mode
			)
			if other_mod:
				stroke_dirty = true

func end_stroke() -> void:
	if not is_stroke_active:
		return
	is_stroke_active = false

	if stroke_dirty and target_mesh != null and target_mesh.pb_mesh_data != null and stroke_snapshot_before != null:
		var snapshot_after := PBCommand.copy_mesh_data(target_mesh.pb_mesh_data)
		_commit_mesh_action(target_mesh, "Paint Texture Splat", stroke_snapshot_before, snapshot_after)
		stroke_committed.emit()

	stroke_snapshot_before = null
	stroke_dirty = false

# ==============================================================================
# Stamp Execution
# ==============================================================================

func apply_stamp() -> void:
	if mode != Mode.STAMP or target_mesh == null or target_mesh.pb_mesh_data == null or not has_hit:
		return

	var stamp_img := get_stamp_image()
	if stamp_img == null:
		return

	var data := target_mesh.pb_mesh_data
	if target_face_idx < 0 or target_face_idx >= data.faces.size():
		return

	var face := data.faces[target_face_idx]
	if face == null:
		return

	var before := PBCommand.copy_mesh_data(data)

	var splat_mat := _ensure_face_splat_material(target_mesh, face)
	if splat_mat == null:
		return

	PBSplat.ensure_mesh_uv2(data)

	# Ensure a layer exists for the stamp texture
	var layer_idx := PBSplat.ensure_layer_for_texture(splat_mat, stamp_texture)
	if layer_idx < 1:
		return

	var local_hit: Vector3 = target_mesh.global_transform.affine_inverse() * cursor_point

	var stamped := PBSplat.stamp_face(
		data, face, splat_mat, layer_idx,
		stamp_img, local_hit, stamp_scale, stamp_rotation, stamp_opacity
	)

	if stamped:
		var after := PBCommand.copy_mesh_data(data)
		_commit_mesh_action(target_mesh, "Stamp Texture", before, after)
		stroke_committed.emit()

func get_stamp_image() -> Image:
	if _cached_stamp_image != null:
		return _cached_stamp_image
	if stamp_texture == null:
		return null
	var img := stamp_texture.get_image()
	if img != null:
		_cached_stamp_image = img
	return _cached_stamp_image

# ==============================================================================
# Splat Material Assignment Helper
# ==============================================================================

func _ensure_face_splat_material(mesh: PBMesh, face: PBFace) -> ShaderMaterial:
	if mesh == null or mesh.pb_mesh_data == null or face == null:
		return null

	var current_mat := mesh.pb_mesh_data.get_face_material(face)
	if PBSplat.is_splat_material(current_mat):
		return current_mat as ShaderMaterial

	# Convert to splat material
	var splat_mat := PBSplat.create_splat_material(current_mat)

	# If a paint_texture is selected, configure layer 1 with it
	if paint_texture != null:
		PBSplat.add_layer(splat_mat, paint_texture)

	mesh.pb_mesh_data.set_face_material(face, splat_mat)
	mesh.rebuild()
	mesh.update_gizmos()
	return splat_mat

# ==============================================================================
# Undo / Redo Helper
# ==============================================================================

func _commit_mesh_action(mesh: PBMesh, action_name: String, before: PBMeshData, after: PBMeshData) -> void:
	mesh.rebuild()
	mesh.update_gizmos()
	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null:
			undo.create_action(action_name, UndoRedo.MERGE_DISABLE, mesh)
			undo.add_do_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
			undo.add_undo_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
			undo.commit_action()
