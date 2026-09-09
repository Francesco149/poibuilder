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

const DECAL_SHADER_PATH := "res://addons/poibuilder/materials/shaders/pb_decal_shader.gdshader"
static var _cached_decal_shader: Shader = null

static func get_decal_shader() -> Shader:
	if _cached_decal_shader == null:
		if ResourceLoader.exists(DECAL_SHADER_PATH):
			_cached_decal_shader = ResourceLoader.load(DECAL_SHADER_PATH) as Shader
	return _cached_decal_shader

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
# Per-stroke touch bookkeeping handed to PBSplat.paint_face_splat (replace
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

	var dshader := get_decal_shader()
	if dshader != null:
		var stamp_mat := ShaderMaterial.new()
		stamp_mat.shader = dshader
		stamp_mat.set_shader_parameter("albedo_texture", stamp_texture)
		stamp_mat.set_shader_parameter("albedo_color", Color(1.0, 1.0, 1.0, stamp_opacity))
		stamp_mat.set_shader_parameter("clip_to_face", false)
		stamp_mat.render_priority = 100
		stamp_mesh_instance.material_override = stamp_mat
	else:
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
		else:
			mat.albedo_color = Color(0.2, 0.85, 1.0, 0.9) # Cyan for paint

	if stamp_mesh_instance != null and stamp_mesh_instance.material_override != null:
		var mat := stamp_mesh_instance.material_override as StandardMaterial3D
		mat.albedo_color = Color(1.0, 1.0, 1.0, stamp_opacity)

func _update_stamp_preview_texture() -> void:
	if stamp_mesh_instance != null and stamp_mesh_instance.material_override != null:
		if stamp_mesh_instance.material_override is ShaderMaterial:
			var smat := stamp_mesh_instance.material_override as ShaderMaterial
			smat.set_shader_parameter("albedo_texture", stamp_texture)
			smat.set_shader_parameter("albedo_color", Color(1.0, 1.0, 1.0, stamp_opacity))
		elif stamp_mesh_instance.material_override is StandardMaterial3D:
			var mat := stamp_mesh_instance.material_override as StandardMaterial3D
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
	var qm := QuadMesh.new()
	qm.size = Vector2(stamp_scale, stamp_scale)
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

		# Update face bounds clipping on preview decal
		if stamp_mesh_instance.material_override is ShaderMaterial and mesh_node != null and mesh_node.pb_mesh_data != null:
			var smat := stamp_mesh_instance.material_override as ShaderMaterial
			var data := mesh_node.pb_mesh_data
			if face_idx >= 0 and face_idx < data.faces.size():
				var face := data.faces[face_idx]
				var bounds := PBSplat.get_face_planar_bounds(data, face)
				smat.set_shader_parameter("face_u", bounds["u"])
				smat.set_shader_parameter("face_v", bounds["v"])
				smat.set_shader_parameter("face_bounds", Vector4(bounds["min_u"], bounds["max_u"], bounds["min_v"], bounds["max_v"]))
				smat.set_shader_parameter("mesh_to_world", mesh_node.global_transform)
				smat.set_shader_parameter("clip_to_face", true)

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
	_stroke_ctx = {}
	_stroke_last_dab_local = Vector3.INF
	_stroke_last_dab_mesh = null
	# Ensure UV2 channel is present once at stroke begin (not per motion event)
	PBSplat.ensure_mesh_uv2(target_mesh.pb_mesh_data)
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

	# Dab spacing: skip motion events that did not travel far enough from the
	# last dab (a dab covering the brush footprint re-walks its pixels; at high
	# motion-event rates that is pure redundant CPU on every event).
	if _stroke_last_dab_mesh == target_mesh:
		var spacing := maxf(brush_radius * DAB_SPACING_FRACTION, 0.01)
		var local_now: Vector3 = target_mesh.global_transform.affine_inverse() * cursor_point
		if _stroke_last_dab_local.distance_squared_to(local_now) < spacing * spacing:
			return

	var splat_mat := _ensure_face_splat_material(target_mesh, face)
	if splat_mat == null:
		return

	# Ensure a layer exists for paint_texture on splat_mat
	if paint_texture != null:
		var layer := PBSplat.ensure_layer_for_texture(splat_mat, paint_texture)
		if layer > 0:
			active_layer_idx = layer

	# Convert world hit point to node local coordinates
	var local_hit: Vector3 = target_mesh.global_transform.affine_inverse() * cursor_point

	# Paint on target face under cursor
	var modified := PBSplat.paint_face_splat(
		data, face, splat_mat, active_layer_idx,
		local_hit, brush_radius, brush_softness, brush_opacity, erase_mode,
		_stroke_ctx
	)

	_stroke_last_dab_local = local_hit
	_stroke_last_dab_mesh = target_mesh

	if modified:
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
	if mode != Mode.STAMP or target_mesh == null or not is_instance_valid(target_mesh) or not has_hit:
		return
	if stamp_texture == null:
		return

	# Compute canonical stamp basis on surface
	var sbasis := PBSplat.get_stamp_basis(cursor_normal)
	var u_right: Vector3 = sbasis["right"]
	var v_up: Vector3 = sbasis["up"]
	var n_axis: Vector3 = sbasis["normal"]

	var rot_rad := deg_to_rad(stamp_rotation)
	var rot_right := cos(rot_rad) * u_right + sin(rot_rad) * v_up
	var rot_up := -sin(rot_rad) * u_right + cos(rot_rad) * v_up

	var world_pos := cursor_point + n_axis * 0.002
	# Basis columns X/Y carry the FULL quad extent; the quad mesh itself is unit
	# size. This makes the re-anchoring math (PBSplat.compute_stamp_anchor)
	# shear-capable: a non-uniform face resize can stretch the decal.
	var world_basis := Basis(rot_right * stamp_scale, rot_up * stamp_scale, n_axis)
	var world_xf := Transform3D(world_basis, world_pos)

	# Get or create PBStamps container child under target_mesh
	var stamps_container := target_mesh.get_node_or_null("PBStamps") as Node3D
	if stamps_container == null:
		stamps_container = Node3D.new()
		stamps_container.name = "PBStamps"
		target_mesh.add_child(stamps_container)
		var scene_root := target_mesh.get_tree().get_edited_scene_root() if target_mesh.is_inside_tree() else null
		if scene_root != null:
			stamps_container.owner = scene_root

	# Create high-fidelity billboard decal quad (unit size; extents live in the
	# transform basis so anchors stay meaningful across face resizes)
	var stamp_node := MeshInstance3D.new()
	stamp_node.name = "Stamp_%d" % (stamps_container.get_child_count() + 1)
	var qm := QuadMesh.new()
	qm.size = Vector2.ONE
	stamp_node.mesh = qm

	var dshader := get_decal_shader()
	if dshader != null:
		var mat := ShaderMaterial.new()
		mat.shader = dshader
		mat.set_shader_parameter("albedo_texture", stamp_texture)
		mat.set_shader_parameter("albedo_color", Color(1.0, 1.0, 1.0, stamp_opacity))
		mat.set_shader_parameter("mesh_to_world", target_mesh.global_transform)
		mat.set_shader_parameter("clip_to_face", true)

		var data := target_mesh.pb_mesh_data
		if data != null and target_face_idx >= 0 and target_face_idx < data.faces.size():
			var face := data.faces[target_face_idx]
			# Geometry bounds (not persisted splat_bounds): decals clip against
			# the live face extent and follow resizes via PBMesh._refresh_stamps.
			var bounds := PBSplat.get_face_planar_bounds(data, face, true)
			mat.set_shader_parameter("face_u", bounds["u"])
			mat.set_shader_parameter("face_v", bounds["v"])
			mat.set_shader_parameter("face_bounds", Vector4(bounds["min_u"], bounds["max_u"], bounds["min_v"], bounds["max_v"]))

		mat.render_priority = 2
		stamp_node.material_override = mat
	else:
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = stamp_texture
		mat.albedo_color = Color(1.0, 1.0, 1.0, stamp_opacity)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		mat.render_priority = 2
		stamp_node.material_override = mat

	stamp_node.transform = stamps_container.global_transform.affine_inverse() * world_xf

	# Store metadata for export baking (resolution-independent so the future
	# bake step can re-rasterize at any tile size)
	stamp_node.set_meta("stamp_scale", stamp_scale)
	stamp_node.set_meta("stamp_rotation", stamp_rotation)
	stamp_node.set_meta("stamp_opacity", stamp_opacity)
	stamp_node.set_meta("stamp_texture_path", stamp_texture.resource_path)
	stamp_node.set_meta("face_idx", target_face_idx)

	# Face-anchored placement: stamps maintain fixed object-space position and size
	# (PBMesh._refresh_stamps re-evaluates these anchors on every rebuild).
	var anchor_data := target_mesh.pb_mesh_data
	if anchor_data != null and target_face_idx >= 0 and target_face_idx < anchor_data.faces.size():
		var anchor := PBSplat.compute_stamp_anchor(anchor_data, anchor_data.faces[target_face_idx], stamp_node.transform)
		if not anchor.is_empty():
			stamp_node.set_meta("anchor_center", anchor["center"])
			stamp_node.set_meta("anchor_du", anchor["du"])
			stamp_node.set_meta("anchor_dv", anchor["dv"])
			stamp_node.set_meta("anchor_u", anchor["u_center"])
			stamp_node.set_meta("anchor_v", anchor["v_center"])
			stamp_node.set_meta("anchor_scale_x", anchor["scale_x"])
			stamp_node.set_meta("anchor_scale_y", anchor["scale_y"])
			stamp_node.set_meta("anchor_rot_right", anchor["rot_right"])
			stamp_node.set_meta("anchor_rot_up", anchor["rot_up"])
	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null:
			var scene_root := plugin.get_editor_interface().get_edited_scene_root()
			undo.create_action("Add Stamp Decal", UndoRedo.MERGE_DISABLE, target_mesh)
			undo.add_do_method(plugin, "_attach_detached", stamp_node, stamps_container)
			undo.add_do_method(plugin, "_own_node", stamp_node)
			undo.add_do_reference(stamp_node)
			undo.add_undo_method(plugin, "_detach_node", stamp_node)
			undo.commit_action()
			stroke_committed.emit()
			return

	stamps_container.add_child(stamp_node)
	var sr := target_mesh.get_tree().get_edited_scene_root() if target_mesh.is_inside_tree() else null
	if sr != null:
		stamp_node.owner = sr
	stroke_committed.emit()

## Removes all stamps under target_mesh's PBStamps container.
func clear_all_stamps(mesh: PBMesh) -> void:
	if mesh == null:
		return
	var container := mesh.get_node_or_null("PBStamps") as Node3D
	if container == null:
		return
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()
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
	mesh.rebuild()
	mesh.update_gizmos()
	if plugin != null and plugin.has_method("get_undo_redo"):
		var undo = plugin.get_undo_redo()
		if undo != null:
			undo.create_action(action_name, UndoRedo.MERGE_DISABLE, mesh)
			undo.add_do_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), after)
			undo.add_undo_method(plugin, "_restore_mesh_snapshot", mesh.get_instance_id(), before)
			undo.commit_action()
