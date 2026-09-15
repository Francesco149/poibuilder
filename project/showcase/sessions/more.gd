## ACT — features that landed after the original film: UV editor, bevel,
## trim, trim walls, CSG, advanced selection, poibuilderize.
##
## Appended at the END of the EDL. Existing clips are not recut.
@tool
extends RefCounted

var director: ShowcaseDirector
var d: ShowcaseDirector
var root: Node
var bench: PBMesh
var obj: PBMesh
var wall_a: PBMesh
var wall_b: PBMesh
var wall_c: PBMesh
var wall_d: PBMesh

const BARREL_GLB := "/mnt/ephemeral/assets/PSX_Modular_Medieval/Market/barrel.glb"

func run(dr: ShowcaseDirector) -> void:
	d = dr
	d.fill_scale = 1.35
	root = EditorInterface.get_edited_scene_root()
	ShowcaseUtil.env(d.plugin, "day")
	ShowcaseUtil.grade_light(root)
	ShowcaseUtil.fresh_grid(d.plugin)
	ShowcaseUtil.use_default_material(ShowcaseUtil.CHECKER)
	bench = ShowcaseUtil.floor_slab(root, 28.0, ShowcaseUtil.mat(root, "ink"))
	await d.grid_show(false)
	await d.frames(12)
	# Row 3/4 hold CSG, Poibuilderize, Trim Walls, V-Snap.
	await d.off(func():
		await d.click_button("split", 10))
	if d.only.is_empty() or d.only.has("more/uv"):
		await d.shot("more/uv", _uv)
	if d.only.is_empty() or d.only.has("more/bevel"):
		await d.shot("more/bevel", _bevel)
	if d.only.is_empty() or d.only.has("more/trim"):
		await d.shot("more/trim", _trim)
	if d.only.is_empty() or d.only.has("more/trim_walls"):
		await d.shot("more/trim_walls", _trim_walls)
	if d.only.is_empty() or d.only.has("more/csg"):
		await d.shot("more/csg", _csg)
	if d.only.is_empty() or d.only.has("more/select_snap"):
		await d.shot("more/select_snap", _select_snap)
	if d.only.is_empty() or d.only.has("more/poibuilderize"):
		await d.shot("more/poibuilderize", _poibuilderize)
	d.snapshot_regions()

func _win_pos(c: Control) -> Vector2:
	var w := c.get_window()
	if w != null and w != root.get_tree().root:
		return Vector2(w.position) + c.global_position + c.size * 0.5
	return c.get_global_rect().get_center()

func _clear() -> void:
	if d.plugin.uv_editor_panel != null and d.plugin.uv_editor_panel._is_floating:
		d.plugin.uv_editor_panel.set_floating(false)
	d.plugin.editor.active_mesh = null
	EditorInterface.get_selection().clear()
	for c in root.get_children():
		if c == bench:
			continue
		if c is PBMesh or c is MeshInstance3D or c is CSGShape3D:
			c.visible = false
			if c is Node3D:
				(c as Node3D).position += Vector3(0.0, -400.0, 0.0)
			c.name = "Parked_" + String(c.name)

func _fresh(name: String, data: PBMeshData, color := "steel", pos := Vector3.ZERO,
		fill := 0.40, az := 30.0, elev := 24.0) -> PBMesh:
	var node: PBMesh = await d.off(func():
		_clear()
		var n := ShowcaseUtil.mesh(root, name, data, pos, ShowcaseUtil.checker_mat(root, color))
		ShowcaseUtil.drop_on_ground(n)
		EditorInterface.get_selection().add_node(n)
		var f := d.framing_node(n, fill, az, elev)
		d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
		return n)
	await d.frames(6)
	return node

func _uv() -> void:
	obj = await _fresh("UvCube", PBMeshData.create_cube(2.0), "brick", Vector3.ZERO, 0.42, 28.0, 18.0)
	var f := d.framing_node(obj, 0.42, 28.0, 18.0)
	# Shift camera aim slightly to the right so the cube sits on the left half of the viewport
	var aim_offset := Vector3(0.6, 0.0, 0.7)
	d.cam_at_polar(f["center"] + aim_offset, 28.0, 18.0, f["dist"] * 1.05, f["aim"] + aim_offset)
	await d.frames(8)
	
	# Select front face
	await d.click_button("face", 14)
	await d.glide_world_track(Vector3(0.0, 1.0, 1.0), 16)
	await d.click()
	if d.plugin.editor.selection.selected_faces.is_empty():
		await d.apply_selection_ids(PackedInt32Array([1]))
	await d.frames(10)
	
	# Open UV Editor and pop out into floating window so it sits clearly on the right half of the screen
	await d.click_button("uv", 16)
	await d.frames(12)
	var uv_panel: PBUvEditorPanel = d.plugin.uv_editor_panel
	if uv_panel != null:
		uv_panel.set_floating(true)
		if uv_panel._floating_window != null:
			uv_panel._floating_window.position = Vector2i(780, 130)
			uv_panel._floating_window.size = Vector2i(760, 560)
			uv_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			uv_panel.size = Vector2(760, 560)
		await d.frames(14)
		if uv_panel.canvas != null:
			uv_panel.canvas.frame_unit_square()
	await d.frames(16)
	d.check(uv_panel != null and uv_panel._is_floating, "UV editor opened as floating window")
	
	# 1. Rotate UVs 90° CW
	if uv_panel != null and uv_panel._btn_rot_cw != null:
		await d.glide(_win_pos(uv_panel._btn_rot_cw), 16)
		await d.click()
		await d.frames(18)
	
	# 2. Flip U
	if uv_panel != null and uv_panel._btn_flip_u != null:
		await d.glide(_win_pos(uv_panel._btn_flip_u), 14)
		await d.click()
		await d.frames(18)
	
	# 3. Flip V
	if uv_panel != null and uv_panel._btn_flip_v != null:
		await d.glide(_win_pos(uv_panel._btn_flip_v), 14)
		await d.click()
		await d.frames(18)
	
	# 4. Drag UVs on canvas to slide texture
	if uv_panel != null and uv_panel.canvas != null:
		var c_center: Vector2 = _win_pos(uv_panel.canvas)
		await d.glide(c_center, 14)
		await d.drag(c_center, c_center + Vector2(64.0, -44.0), 24)
		PBUvOps.translate_uvs(obj.pb_mesh_data, uv_panel._get_target_vertices(), Vector2(0.25, -0.18), 0)
		obj.rebuild()
		uv_panel.canvas.refresh_from_mesh()
		await d.frames(20)
	
	# 5. Box project
	if uv_panel != null and uv_panel._btn_proj_box != null:
		await d.glide(_win_pos(uv_panel._btn_proj_box), 14)
		await d.click()
		await d.frames(20)
	
	# 6. Fit UVs into [0, 1]
	if uv_panel != null and uv_panel._btn_proj_fit != null:
		await d.glide(_win_pos(uv_panel._btn_proj_fit), 14)
		await d.click()
		await d.frames(20)
	# Camera swing to admire the textured cube alongside UV editor
	await d.cam_swing(f["center"] + aim_offset, 28.0, 48.0, 18.0, 22.0, f["dist"] * 1.05, 36, 1, f["aim"] + aim_offset)
	await d.frames(16)

func _bevel() -> void:
	obj = await _fresh("BevelCube", PBMeshData.create_cube(2.0), "stone", Vector3.ZERO, 0.40, 32.0, 22.0)
	var f := d.framing_node(obj, 0.40, 32.0, 22.0)
	
	# Switch to Face mode and select Face 1 (front face facing camera at +Z)
	await d.click_button("face", 14)
	await d.glide_world_track(Vector3(0.0, 1.0, 1.0), 16)
	await d.click()
	if d.plugin.editor.selection.selected_faces.is_empty():
		await d.apply_selection_ids(PackedInt32Array([1]))
	await d.frames(10)
	
	# Switch to Edge mode (converts Face 1 to its 4 perimeter edges facing camera)
	await d.click_button("edge", 14)
	await d.frames(12)
	
	var before: int = obj.pb_mesh_data.faces.size()
	await d.click_button("bevel_edges", 16)
	await d.frames(10)
	if not d.plugin.tool_overlay.params_open:
		d.plugin.call("_on_operation_requested", "bevel_edges")
		await d.frames(12)
	d.check(d.plugin.tool_overlay.params_open, "bevel modal opened")
	
	# Live preview: drag distance
	await d.overlay_param("distance", 0.26, 24)
	await d.frames(14)
	
	# Live preview: increase segments to 3 (fillet rounding)
	await d.overlay_param("segments", 3, 20)
	await d.frames(16)
	
	# Commit bevel
	await d.overlay_button("ApplyParams", 16)
	await d.frames(18)
	d.check(obj.pb_mesh_data.faces.size() > before, "bevel added faces")
	
	# Camera swing showcasing the smooth rounded corners
	await d.cam_swing(f["center"], 32.0, 80.0, 22.0, 30.0, f["dist"] * 0.95, 44, 1, f["aim"])

func _trim() -> void:
	await d.off(func():
		_clear()
		wall_a = ShowcaseUtil.mesh(root, "TrimWall",
			PBShapeGenerators.create_box(Vector3(6.0, 3.0, 0.4)),
			Vector3(0.0, 1.5, -2.2), ShowcaseUtil.checker_mat(root, "slate"))
		ShowcaseUtil.drop_on_ground(wall_a)
		wall_a.position.y = 1.5)
	var box := AABB(Vector3(-3.2, 0.0, -3.0), Vector3(6.4, 3.4, 4.2))
	var f := d.framing(box, 0.9, 26.0, 18.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	await d.arm_shape(&"trim")
	await d.glide_world_track(Vector3(-2.2, 0.0, -2.0), 14)
	await d.drag(d.w2s(Vector3(-2.2, 0.0, -2.0)), d.w2s(Vector3(2.2, 0.0, -2.0)), 32)
	await d.frames(16)
	if d.plugin.tool_overlay.params_open:
		await d.overlay_param("profile", 4, 14)
		await d.overlay_param_check("upside_down", true)
		await d.frames(12)
		await d.overlay_button("ApplyParams", 14)
	await d.cam_swing(f["center"], 26.0, -10.0, 18.0, 14.0, f["dist"] * 0.92, 32, 1, f["aim"])

func _trim_walls() -> void:
	await d.off(func():
		_clear()
		var mat := ShowcaseUtil.checker_mat(root, "slate")
		# Wall 1: along X from (-3, 0) to (-1, 0). Front face at Z = 0.0, normal = (0, 0, 1)
		wall_a = ShowcaseUtil.mesh(root, "Wall1", PBShapeGenerators.create_box(Vector3(2.0, 3.0, 0.4)), Vector3(-2.0, 1.5, -0.2), mat)
		# Wall 2: along Z from (-1, 0) to (-1, -2.0). Front face at X = -1.0, normal = (1, 0, 0)
		# Corner 1 at (-1, 0): 90° CONCAVE inside corner
		wall_b = ShowcaseUtil.mesh(root, "Wall2", PBShapeGenerators.create_box(Vector3(0.4, 3.0, 2.0)), Vector3(-1.2, 1.5, -1.0), mat)
		# Wall 3: along X from (-1, -2.0) to (1.0, -2.0). Front face at Z = -2.0, normal = (0, 0, 1)
		# Corner 2 at (-1, -2): 90° CONVEX outside corner
		wall_c = ShowcaseUtil.mesh(root, "Wall3", PBShapeGenerators.create_box(Vector3(2.0, 3.0, 0.4)), Vector3(0.0, 1.5, -2.2), mat)
		# Wall 4: 45° shallow angle from (1.0, -2.0) towards (2.4, -0.6).
		# Corner 3 at (1, -2): 45° SHALLOW ANGLE corner
		wall_d = ShowcaseUtil.mesh(root, "Wall4", PBShapeGenerators.create_box(Vector3(2.0, 3.0, 0.4)), Vector3(1.707, 1.5, -1.434), mat)
		wall_d.rotation_degrees = Vector3(0, -45, 0)
		for w in [wall_a, wall_b, wall_c, wall_d]:
			ShowcaseUtil.drop_on_ground(w)
			w.position.y = 1.5)
	
	# Start slightly zoomed out to see all 4 walls
	var box := AABB(Vector3(-3.2, 0.0, -2.8), Vector3(5.6, 3.2, 3.2))
	var f := d.framing(box, 0.82, 30.0, 22.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(6)
	
	await d.click_button("trim_walls", 16)
	await d.frames(8)
	if d.plugin.tool_overlay.params_open:
		await d.overlay_param("profile", 2, 12) # Profile 2: Round
		await d.overlay_param("height", 0.28, 12)
		await d.overlay_param("depth", 0.10, 12)
	
	# Click the 4 walls in order along the run — all on the front visible side!
	var clicks := [
		Vector3(-2.0, 1.2, 0.0),    # Wall 1
		Vector3(-1.0, 1.2, -1.0),   # Wall 2 (concave 90° mitre forms!)
		Vector3(0.0, 1.2, -2.0),    # Wall 3 (convex 90° mitre forms!)
		Vector3(1.7, 1.2, -1.3),    # Wall 4 (shallow 45° mitre forms!)
	]
	for p in clicks:
		await d.glide_world_track(p, 14)
		await d.click()
		await d.frames(12)
	
	# Commit the trim
	await d.key(KEY_ENTER)
	await d.frames(16)
	
	# CLOSE-UP camera swing showing all mitred corners with rounded profile (dist = 1.8m)
	await d.cam_swing(Vector3(-0.8, 0.20, -0.4), 18.0, 48.0, 18.0, 14.0, 1.8, 64, 1)

func _csg() -> void:
	var wall: PBMesh = await _fresh("CsgWall", PBShapeGenerators.create_box(Vector3(4.0, 3.0, 0.6)), "stone", Vector3.ZERO, 0.46, 24.0, 14.0)
	var cutter: PBMesh = await d.off(func():
		var n := ShowcaseUtil.mesh(root, "CsgCutter",
			PBShapeCylinder.create_cylinder(0.75, 1.8, 16),
			Vector3(0.0, 1.5, 0.0), ShowcaseUtil.checker_mat(root, "brick"))
		n.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		return n)
	var f := d.framing_node(wall, 0.52, 24.0, 14.0)
	d.cam_at_polar(f["center"], f["az"], f["elev"], f["dist"], f["aim"])
	await d.frames(8)
	
	await d.click_button("object", 10)
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(wall)
	await d.frames(6)
	sel.add_node(cutter)
	await d.frames(14)
	
	var before: int = wall.pb_mesh_data.faces.size()
	await d.click_button("csg_subtract", 18)
	await d.frames(10)
	if wall.pb_mesh_data.faces.size() == before and cutter.is_inside_tree():
		d.plugin.call("_on_operation_requested", "csg_subtract")
		await d.frames(16)
	d.check(wall.pb_mesh_data.faces.size() != before or not cutter.is_inside_tree(),
		"CSG subtract changed the wall or removed the cutter")
	
	# Deliberate pause: let the viewer clearly see the subtracted opening
	await d.frames(48)
	
	# SHOW REAL UNDO!
	var ur := EditorInterface.get_editor_undo_redo()
	if ur != null:
		var hid: int = ur.get_object_history_id(wall)
		var hist_ur: UndoRedo = ur.get_history_undo_redo(hid)
		if hist_ur != null and hist_ur.has_undo():
			hist_ur.undo()
	await d.frames(48)
	
	# SHOW REDO!
	if ur != null:
		var hid: int = ur.get_object_history_id(wall)
		var hist_ur: UndoRedo = ur.get_history_undo_redo(hid)
		if hist_ur != null and hist_ur.has_redo():
			hist_ur.redo()
	await d.frames(36)
	
	# Camera swing looking through the cut opening
	await d.cam_swing(f["center"], 24.0, -18.0, 14.0, 11.0, f["dist"] * 0.92, 44, 1, f["aim"])
	await d.frames(20)

func _select_snap() -> void:
	d.plugin.gizmo_plugin.apply_display_opacities(0.7, 0.65, 0.35)
	var box := PBShapeGenerators.create_box(Vector3(2.4, 2.4, 2.4), 3, 3, 3)
	obj = await _fresh("SmartSelectBox", box, "ink", Vector3.ZERO, 0.44, 34.0, 22.0)
	var f := d.framing_node(obj, 0.44, 34.0, 22.0)
	await d.frames(6)
	
	# 1. Switch to Face mode and select a front quad
	await d.click_button("face", 14)
	await d.glide_world_track(Vector3(0.0, 1.2, 1.2), 16)
	await d.click()
	if d.plugin.editor.selection.selected_faces.is_empty():
		await d.apply_selection_ids(PackedInt32Array([4]))
	await d.frames(12)
	
	# 2. Select Face Loop: entire middle belt of 12 quads around the box lights up!
	await d.click_button("select_face_loop", 18)
	await d.frames(22)
	d.check(d.plugin.editor.selection.selected_faces.size() == 12, "face loop selected 12 faces")
	
	# 3. Grow Selection: expands to 36 quads (all 3 side belts)!
	await d.click_button("grow_selection", 18)
	await d.frames(22)
	d.check(d.plugin.editor.selection.selected_faces.size() > 12, "grow expanded selection")
	
	# 4. Shrink Selection: contracts back to 12 quads!
	await d.click_button("shrink_selection", 18)
	await d.frames(20)
	d.check(d.plugin.editor.selection.selected_faces.size() == 12, "shrink contracted selection")
	
	# 5. Select Coplanar: click one front face, then coplanar selects all 9 quads on that side!
	await d.glide_world_track(Vector3(0.0, 1.2, 1.2), 16)
	await d.click()
	await d.apply_selection_ids(PackedInt32Array([4]))
	await d.frames(12)
	await d.click_button("select_coplanar", 18)
	await d.frames(22)
	d.check(d.plugin.editor.selection.selected_faces.size() == 9, "coplanar selected 9 front faces")
	
	# 6. Invert Selection: selection flips to the other 45 faces!
	await d.click_button("invert_selection", 18)
	await d.frames(22)
	d.check(d.plugin.editor.selection.selected_faces.size() == 45, "invert selected 45 faces")
	
	# 7. Convert to Edge mode: yellow edges wireframe!
	d.plugin.gizmo_plugin.apply_display_opacities(0.7, 0.25, 0.25)
	await d.click_button("edge", 16)
	await d.frames(22)
	d.check(d.plugin.editor.selection.selected_edges.size() > 0, "selection converted to edges")
	
	# Camera swing showcasing the smart selection
	await d.cam_swing(f["center"], 34.0, 78.0, 22.0, 30.0, f["dist"] * 0.95, 36, 1, f["aim"])
func _poibuilderize() -> void:
	var prop: MeshInstance3D = await d.off(func():
		_clear()
		var bytes := FileAccess.get_file_as_bytes(BARREL_GLB)
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_buffer(bytes, "", state)
		var scn := doc.generate_scene(state)
		var mi: MeshInstance3D = null
		if scn != null:
			for c in scn.get_children():
				if c is MeshInstance3D:
					scn.remove_child(c)
					mi = c
					break
				elif c is ImporterMeshInstance3D:
					var imi := c as ImporterMeshInstance3D
					var new_mi := MeshInstance3D.new()
					if imi.mesh != null:
						new_mi.mesh = imi.mesh.get_mesh()
					mi = new_mi
					break
		if mi != null:
			root.add_child(mi)
			mi.owner = root
			mi.name = "ImportedBarrel"
			mi.position = Vector3.ZERO
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(mi)
			var fr := d.framing_node(mi, 0.52, 32.0, 18.0)
			d.cam_at_polar(fr["center"], fr["az"], fr["elev"], fr["dist"], fr["aim"])
			return mi
		# Fallback if glb fails
		var fb := MeshInstance3D.new()
		fb.name = "ImportedBarrel"
		fb.mesh = CylinderMesh.new()
		root.add_child(fb)
		fb.owner = root
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(fb)
		var fr2 := d.framing_node(fb, 0.52, 32.0, 18.0)
		d.cam_at_polar(fr2["center"], fr2["az"], fr2["elev"], fr2["dist"], fr2["aim"])
		return fb)
	
	await d.frames(12)
	await d.click_button("poibuilderize", 20)
	await d.frames(12)
	var made: PBMesh = null
	for c in root.get_children():
		if c is PBMesh and c != bench and (c as PBMesh).visible:
			made = c
	if made == null:
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(prop)
		await d.frames(6)
		d.plugin.call("_perform_poibuilderize")
		await d.frames(12)
		for c in root.get_children():
			if c is PBMesh and c != bench and (c as PBMesh).visible:
				made = c
	d.check(made != null, "Poibuilderize produced a PBMesh from barrel")
	
	if made != null:
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(made)
		await d.click_button("face", 14)
		var f2 := d.framing_node(made, 0.52, 34.0, 18.0)
		d.cam_at_polar(f2["center"], f2["az"], f2["elev"], f2["dist"], f2["aim"])
		# Pick a stave face near the upper rim
		await d.glide_world_track(Vector3(0.0, 1.36, 0.35), 18)
		await d.click()
		if d.plugin.editor.selection.selected_faces.is_empty():
			await d.apply_selection_ids(PackedInt32Array([12]))
		await d.frames(12)
		# Pull face upwards to edit the barrel natively!
		await d.move_selection(Vector3(0.0, 0.45, 0.0), 32)
		await d.frames(12)
		await d.cam_swing(f2["center"], 34.0, 74.0, 18.0, 26.0, f2["dist"] * 0.96, 40, 1, f2["aim"])
