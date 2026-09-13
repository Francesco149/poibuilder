## Test: UV Editor Operations, 2D Gizmo, Snapping, Seams & Projections (Session 2)
##
## Verifies:
## 1. UV Mode conversion: Auto, Manual, Mixed mode detection and conversion.
## 2. 2D Transformations: Translation, Rotation around pivot, Scaling around pivot,
##    Horizontal / Vertical Flips, and 90° CW/CCW rotations.
## 3. Projections: Fit UVs [0,1], Planar Projection, Box Projection.
## 4. Seam tools: Sew UVs, Split UVs, Collapse UVs, and Auto-Stitch.
## 5. Texel Density: Sampling density and normalizing across faces.
## 6. Template Export: Exporting UV wireframe PNG template.
## 7. 2D Gizmo: Hit testing, handle interaction, and drag calculations.
## 8. Panel Operations: Operation toolbar buttons, tool switching, and Undo/Redo.
extends GutTest

func test_uv_mode_detection_and_conversion():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	# Initially all faces are Auto UV
	assert_eq(PBUvOps.get_uv_mode(cube, [0, 1]), "Auto", "Initial faces must be Auto UV")
	assert_eq(PBUvOps.get_uv_mode(cube, []), "NoSelection", "Empty selection must be NoSelection")

	# Convert Face 0 to Manual
	var changed := PBUvOps.convert_to_manual(cube, [0])
	assert_true(changed, "convert_to_manual must return true when mode changes")
	assert_true(cube.faces[0].manual_uv, "Face 0 manual_uv must be true")
	assert_false(cube.faces[1].manual_uv, "Face 1 manual_uv must remain false")

	# Mixed mode
	assert_eq(PBUvOps.get_uv_mode(cube, [0, 1]), "Mixed", "Selection with auto and manual must report Mixed")
	assert_eq(PBUvOps.get_uv_mode(cube, [0]), "Manual", "Selection with only manual must report Manual")

	# Convert Face 0 back to Auto
	changed = PBUvOps.convert_to_auto(cube, [0])
	assert_true(changed, "convert_to_auto must return true")
	assert_false(cube.faces[0].manual_uv, "Face 0 manual_uv must now be false")
	assert_eq(PBUvOps.get_uv_mode(cube, [0, 1]), "Auto", "Both faces must now report Auto")

func test_uv_translation():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var face0: PBFace = cube.faces[0]
	var verts := face0.get_distinct_indexes()
	var orig_uv0 := cube.textures0[verts[0]]

	# Translate face 0 vertices by (0.5, 0.25)
	var delta := Vector2(0.5, 0.25)
	var ok := PBUvOps.translate_uvs(cube, verts, delta)
	assert_true(ok, "translate_uvs must return true")
	assert_true(face0.manual_uv, "translate_uvs must automatically set face to manual_uv")

	var new_uv0 := cube.textures0[verts[0]]
	assert_almost_eq(new_uv0.x, orig_uv0.x + 0.5, 0.0001, "Translated UV X must match delta")
	assert_almost_eq(new_uv0.y, orig_uv0.y + 0.25, 0.0001, "Translated UV Y must match delta")

func test_uv_rotation_around_pivot():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var face0: PBFace = cube.faces[0]
	var verts := face0.get_distinct_indexes()
	var bounds := PBUvOps.get_uv_bounds(cube.textures0, verts)
	var pivot := bounds.get_center()

	var p0_before := cube.textures0[verts[0]]

	# Rotate 90 degrees around pivot
	var ok := PBUvOps.rotate_uvs(cube, verts, pivot, 90.0)
	assert_true(ok, "rotate_uvs must return true")

	var p0_after := cube.textures0[verts[0]]
	var expected := pivot + (p0_before - pivot).rotated(deg_to_rad(90.0))
	assert_almost_eq(p0_after.x, expected.x, 0.0001, "Rotated UV X must match expected rotation")
	assert_almost_eq(p0_after.y, expected.y, 0.0001, "Rotated UV Y must match expected rotation")

func test_uv_scaling_around_pivot():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var face0: PBFace = cube.faces[0]
	var verts := face0.get_distinct_indexes()
	var bounds := PBUvOps.get_uv_bounds(cube.textures0, verts)
	var pivot := bounds.get_center()

	var orig_size := bounds.size
	# Scale by (2.0, 0.5)
	var ok := PBUvOps.scale_uvs(cube, verts, pivot, Vector2(2.0, 0.5))
	assert_true(ok, "scale_uvs must return true")

	var new_bounds := PBUvOps.get_uv_bounds(cube.textures0, verts)
	assert_almost_eq(new_bounds.size.x, orig_size.x * 2.0, 0.001, "Scaled bounds width must double")
	assert_almost_eq(new_bounds.size.y, orig_size.y * 0.5, 0.001, "Scaled bounds height must halve")

func test_uv_flip_and_rotate_90():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var face0: PBFace = cube.faces[0]
	var verts := face0.get_distinct_indexes()
	var bounds_before := PBUvOps.get_uv_bounds(cube.textures0, verts)

	# Flip horizontal
	var ok := PBUvOps.flip_uvs(cube, [0], true)
	assert_true(ok, "flip_uvs must succeed")
	var bounds_after := PBUvOps.get_uv_bounds(cube.textures0, verts)
	assert_almost_eq(bounds_before.get_center().x, bounds_after.get_center().x, 0.001, "Flip must preserve center X")

	# Rotate 90 degrees CW then CCW
	PBUvOps.rotate_90(cube, [0], true)
	PBUvOps.rotate_90(cube, [0], false)
	var bounds_restored := PBUvOps.get_uv_bounds(cube.textures0, verts)
	assert_almost_eq(bounds_restored.size.x, bounds_before.size.x, 0.001, "90 CW + 90 CCW must restore dimensions")

func test_fit_uvs():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	# Deliberately offset and scale UVs of Face 0
	var verts := cube.faces[0].get_distinct_indexes()
	PBUvOps.translate_uvs(cube, verts, Vector2(10.5, -4.2))
	PBUvOps.scale_uvs(cube, verts, Vector2(10.5, -4.2), Vector2(3.5, 2.8))

	# Fit UVs into [0, 1]
	var ok := PBUvOps.fit_uvs(cube, [0])
	assert_true(ok, "fit_uvs must succeed")

	var bounds := PBUvOps.get_uv_bounds(cube.textures0, verts)
	assert_almost_eq(bounds.position.x, 0.0, 0.001, "Fit UV min X must be 0.0")
	assert_almost_eq(bounds.position.y, 0.0, 0.001, "Fit UV min Y must be 0.0")
	assert_almost_eq(bounds.size.x, 1.0, 0.001, "Fit UV width must be 1.0")
	assert_almost_eq(bounds.size.y, 1.0, 0.001, "Fit UV height must be 1.0")

func test_planar_and_box_projections():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	# Planar project faces 0 and 1
	var ok_planar := PBUvOps.planar_project(cube, [0, 1])
	assert_true(ok_planar, "planar_project must succeed")
	assert_true(cube.faces[0].manual_uv, "Planar projected face 0 must be manual_uv")
	assert_true(cube.faces[1].manual_uv, "Planar projected face 1 must be manual_uv")

	var bounds := PBUvOps.get_uv_bounds(cube.textures0, PBUvOps.get_distinct_vertices_for_faces(cube, [0, 1]))
	assert_almost_eq(bounds.position.x, 0.0, 0.001, "Planar projection must align lower-left U to 0")
	assert_almost_eq(bounds.position.y, 0.0, 0.001, "Planar projection must align lower-left V to 0")

	# Box project all faces
	var all_faces := [0, 1, 2, 3, 4, 5]
	var ok_box := PBUvOps.box_project(cube, all_faces)
	assert_true(ok_box, "box_project must succeed")
	for fi in all_faces:
		assert_true(cube.faces[fi].manual_uv, "Box projected face %d must be manual_uv" % fi)
		var f_verts := cube.faces[fi].get_distinct_indexes()
		var fb := PBUvOps.get_uv_bounds(cube.textures0, f_verts)
		assert_gte(fb.position.x, -0.001, "Box projected face bounds min X must be >= 0")
		assert_lte(fb.end.x, 1.001, "Box projected face bounds max X must be <= 1")

func test_sew_split_and_collapse_uvs():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	# On a standard cube, adjacent faces meet at 3D edges
	var f0_verts := cube.faces[0].get_distinct_indexes()
	var f2_verts := cube.faces[2].get_distinct_indexes()
	var test_verts := []
	test_verts.append_array(f0_verts)
	test_verts.append_array(f2_verts)

	# Collapse face 0 UVs
	var ok_collapse := PBUvOps.collapse_uvs(cube, f0_verts)
	assert_true(ok_collapse, "collapse_uvs must succeed")
	var c0 := cube.textures0[f0_verts[0]]
	for vi in f0_verts:
		assert_almost_eq(cube.textures0[vi].x, c0.x, 0.0001, "All collapsed vertices must share X")
		assert_almost_eq(cube.textures0[vi].y, c0.y, 0.0001, "All collapsed vertices must share Y")

	# Split UVs with an offset
	var split_count := PBUvOps.split_uvs(cube, f0_verts, Vector2(0.1, 0.1))
	assert_gt(split_count, 0, "split_uvs must displace coincident vertices")

	# Sew proximate UVs between adjacent faces
	var sew_count := PBUvOps.sew_uvs(cube, test_verts, 2.0)
	assert_gt(sew_count, 0, "sew_uvs must weld proximate coincident vertices between adjacent faces")
func test_auto_stitch():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	# Faces 0 and 2 on standard cube share a 3D edge
	# Distort Face 2 UVs heavily
	var f2_verts := cube.faces[2].get_distinct_indexes()
	PBUvOps.translate_uvs(cube, f2_verts, Vector2(5.0, 5.0))
	PBUvOps.rotate_uvs(cube, f2_verts, Vector2(5.0, 5.0), 45.0)

	# Auto-stitch face 2 to face 0
	var ok := PBUvOps.auto_stitch(cube, 0, 2)
	assert_true(ok, "auto_stitch between adjacent cube faces must succeed")
	assert_true(cube.faces[2].manual_uv, "Stitched face must become manual_uv")

func test_texel_density_sampling_and_normalization():
	var cube := PBMeshData.create_cube(2.0) # 2m cube (each face 2m x 2m = 4m²)
	PBUv.refresh_mesh_uvs(cube, true)

	var density := PBUvOps.sample_texel_density(cube, cube.faces[0], Vector2(512, 512))
	assert_gt(density, 0.0, "Texel density must be positive")

	# Normalize texel density to 256 px/m across all faces
	var norm_count := PBUvOps.normalize_texel_density(cube, [0, 1, 2, 3, 4, 5], 256.0, Vector2(512, 512))
	assert_eq(norm_count, 6, "All 6 faces must be normalized")

	var new_density := PBUvOps.sample_texel_density(cube, cube.faces[0], Vector2(512, 512))
	assert_almost_eq(new_density, 256.0, 1.0, "Sampled density after normalization must equal target")

func test_uv_template_png_export():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var test_path := "user://test_uv_template_output.png"
	var err := PBUvOps.export_uv_template(cube, test_path, 256, Color.WHITE, Color.BLACK, false)
	assert_eq(err, OK, "export_uv_template must return OK")
	assert_true(FileAccess.file_exists(test_path), "Template PNG file must exist on disk")

	# Clean up
	DirAccess.remove_absolute(test_path)

func test_uv_gizmo_hit_testing_and_drag():
	var canvas := PBUvCanvas.new()
	canvas.size = Vector2(800, 600)
	canvas.zoom = 300.0
	canvas.pan_offset = Vector2.ZERO

	var gizmo := PBUvGizmo.new()
	gizmo.pivot_uv = Vector2(0.5, 0.5)

	var pivot_screen := canvas.uv_to_screen(gizmo.pivot_uv)

	# 1. Test MOVE tool hits
	gizmo.tool_mode = PBUvGizmo.ToolMode.MOVE
	assert_eq(gizmo.hit_test(pivot_screen, canvas), PBUvGizmo.HandleType.MOVE_CENTER, "Hit on pivot must pick MOVE_CENTER")
	assert_eq(gizmo.hit_test(pivot_screen + Vector2(25, 0), canvas), PBUvGizmo.HandleType.MOVE_AXIS_U, "Hit along horizontal arm must pick MOVE_AXIS_U")
	assert_eq(gizmo.hit_test(pivot_screen + Vector2(0, 25), canvas), PBUvGizmo.HandleType.MOVE_AXIS_V, "Hit along vertical arm must pick MOVE_AXIS_V")

	# 2. Test ROTATE tool hit
	gizmo.tool_mode = PBUvGizmo.ToolMode.ROTATE
	assert_eq(gizmo.hit_test(pivot_screen + Vector2(PBUvGizmo.ROTATE_RADIUS, 0), canvas), PBUvGizmo.HandleType.ROTATE_DIAL, "Hit on ring must pick ROTATE_DIAL")

	# 3. Test SCALE tool hit
	gizmo.tool_mode = PBUvGizmo.ToolMode.SCALE
	assert_eq(gizmo.hit_test(pivot_screen, canvas), PBUvGizmo.HandleType.SCALE_UNIFORM, "Hit on pivot must pick SCALE_UNIFORM")
	assert_eq(gizmo.hit_test(pivot_screen + Vector2(PBUvGizmo.HANDLE_LENGTH, 0), canvas), PBUvGizmo.HandleType.SCALE_AXIS_U, "Hit on U arm must pick SCALE_AXIS_U")
	assert_eq(gizmo.hit_test(pivot_screen + Vector2(0, PBUvGizmo.HANDLE_LENGTH), canvas), PBUvGizmo.HandleType.SCALE_AXIS_V, "Hit on V arm must pick SCALE_AXIS_V")

	# 4. Drag simulation
	gizmo.snap_enabled = false
	gizmo.begin_drag(PBUvGizmo.HandleType.MOVE_CENTER, pivot_screen, canvas)
	assert_true(gizmo.is_dragging, "Gizmo must be in dragging state")

	var delta_res := gizmo.apply_drag(pivot_screen + Vector2(30, 60), canvas, false, false)
	assert_eq(delta_res.get("type", ""), "move", "Drag result must be move")
	assert_almost_eq(delta_res.get("delta", Vector2.ZERO).x, 30.0 / 300.0, 0.001, "Delta X must match screen delta / zoom")
	assert_almost_eq(delta_res.get("delta", Vector2.ZERO).y, 60.0 / 300.0, 0.001, "Delta Y must match screen delta / zoom")

	gizmo.commit_drag()
	assert_false(gizmo.is_dragging, "Commit drag must clear dragging state")

	canvas.free()

func test_panel_operations_toolbar_and_undo():
	var panel := PBUvEditorPanel.new()
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	panel.active_mesh = mesh

	# Select face 0 in UV canvas
	panel.canvas.selected_faces[0] = true

	# Test Tool selection buttons (Move / Rotate / Scale)
	panel._btn_tool_rot.emit_signal("pressed")
	assert_eq(panel.canvas.transform_tool, PBUvGizmo.ToolMode.ROTATE, "Pressing Rotate tool button must update canvas transform_tool")

	panel._btn_tool_scale.emit_signal("pressed")
	assert_eq(panel.canvas.transform_tool, PBUvGizmo.ToolMode.SCALE, "Pressing Scale tool button must update canvas transform_tool")

	panel._btn_tool_move.emit_signal("pressed")
	assert_eq(panel.canvas.transform_tool, PBUvGizmo.ToolMode.MOVE, "Pressing Move tool button must update canvas transform_tool")

	# Test Convert to Manual button
	panel._btn_mode_manual.emit_signal("pressed")
	assert_true(cube.faces[0].manual_uv, "Pressing Manual button must convert face 0 to manual_uv")

	# Test Fit button
	panel._btn_proj_fit.emit_signal("pressed")
	var verts := cube.faces[0].get_distinct_indexes()
	var bounds := PBUvOps.get_uv_bounds(cube.textures0, verts)
	assert_almost_eq(bounds.size.x, 1.0, 0.001, "Pressing Fit button must normalize face width to 1.0")

	# Test Flip U button
	var center_before := bounds.get_center()
	panel._btn_flip_u.emit_signal("pressed")
	var bounds_flipped := PBUvOps.get_uv_bounds(cube.textures0, verts)
	assert_almost_eq(bounds_flipped.get_center().x, center_before.x, 0.001, "Flip U must preserve center X")

	# Test Convert to Auto button
	panel._btn_mode_auto.emit_signal("pressed")
	assert_false(cube.faces[0].manual_uv, "Pressing Auto button must convert face 0 to auto UV")

	mesh.free()
	panel.free()

func test_gizmo_pivot_resets_on_undo():
	var canvas := PBUvCanvas.new()
	canvas.size = Vector2(800, 600)
	canvas.zoom = 300.0

	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	canvas.active_mesh = mesh
	canvas.select_mode = PBUvCanvas.SelectMode.VERTEX

	# Select vertex 0
	canvas.selected_verts[0] = true
	canvas._update_gizmo_pivot()

	var orig_uv: Vector2 = cube.textures0[0]
	assert_almost_eq(canvas.gizmo.pivot_uv.x, orig_uv.x, 0.001, "Gizmo pivot X must initially match vertex 0 UV")
	assert_almost_eq(canvas.gizmo.pivot_uv.y, orig_uv.y, 0.001, "Gizmo pivot Y must initially match vertex 0 UV")

	# Capture snapshot and move vertex via gizmo
	var cmd := CmdMeshOp.new(cube, "Move UV", mesh)
	canvas._gizmo_drag_snapshot_uvs = canvas.get_uv_array().duplicate()
	canvas._gizmo_affected_indices = canvas.get_selected_vertex_indices()
	var p_screen := canvas.uv_to_screen(orig_uv)
	canvas.gizmo.begin_drag(PBUvGizmo.HandleType.MOVE_CENTER, p_screen, canvas)
	var t := canvas.gizmo.apply_drag(p_screen + Vector2(60, 90), canvas, false, false)
	canvas._apply_gizmo_transform(t)
	canvas.gizmo.commit_drag()
	canvas._update_gizmo_pivot()
	cmd.capture_after()

	# Verify vertex moved and pivot followed
	var moved_uv: Vector2 = cube.textures0[0]
	assert_gt(orig_uv.distance_to(moved_uv), 0.1, "Vertex UV must have moved")
	assert_almost_eq(canvas.gizmo.pivot_uv.x, moved_uv.x, 0.001, "Gizmo pivot X must follow moved vertex")
	assert_almost_eq(canvas.gizmo.pivot_uv.y, moved_uv.y, 0.001, "Gizmo pivot Y must follow moved vertex")

	# Simulate Undo: apply before snapshot
	cmd.undo_it()

	# Verify gizmo pivot moved back to original position
	var restored_uv: Vector2 = cube.textures0[0]
	assert_almost_eq(restored_uv.x, orig_uv.x, 0.001, "Restored UV X must match original")
	assert_almost_eq(restored_uv.y, orig_uv.y, 0.001, "Restored UV Y must match original")
	assert_almost_eq(canvas.gizmo.pivot_uv.x, orig_uv.x, 0.001, "Gizmo pivot X must reset back to original on undo")
	assert_almost_eq(canvas.gizmo.pivot_uv.y, orig_uv.y, 0.001, "Gizmo pivot Y must reset back to original on undo")

	mesh.free()
	canvas.free()

func test_select_face_in_3d_then_select_single_vertex_in_uv_editor():
	var panel := PBUvEditorPanel.new()
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	panel.active_mesh = mesh

	# 1. Simulate selecting Face 0 in 3D face mode
	panel.sync_selection_from_3d([0])
	assert_true(panel.canvas.selected_faces.has(0), "Face 0 must be in selected_faces")

	# 2. User switches to Vertex mode in UV editor
	panel._btn_mode_vert.emit_signal("pressed")
	assert_eq(panel.canvas.select_mode, PBUvCanvas.SelectMode.VERTEX, "Select mode must be VERTEX")
	assert_true(panel.canvas.selected_faces.is_empty(), "selected_faces must be cleared upon entering VERTEX mode")
	assert_gt(panel.canvas.selected_verts.size(), 0, "selected_verts must have been populated from face vertices")

	# 3. User clicks on a single vertex (vertex 0)
	var v0_uv: Vector2 = cube.textures0[0]
	var v0_screen: Vector2 = panel.canvas.uv_to_screen(v0_uv)
	panel.canvas._handle_left_press(v0_screen, false)
	panel.canvas._handle_left_release(v0_screen)

	# Verify that ONLY vertex 0 is selected
	assert_eq(panel.canvas.selected_verts.size(), 1, "Exactly one vertex must be selected")
	assert_true(panel.canvas.selected_verts.has(0), "Vertex 0 must be selected")
	assert_true(panel.canvas.selected_faces.is_empty(), "selected_faces must remain empty so whole face is not yellow")
	assert_almost_eq(panel.canvas.gizmo.pivot_uv.x, v0_uv.x, 0.001, "Gizmo pivot must be centered on the selected vertex")
	assert_almost_eq(panel.canvas.gizmo.pivot_uv.y, v0_uv.y, 0.001, "Gizmo pivot must be centered on the selected vertex")

	mesh.free()
	panel.free()

func test_uv_panel_buttons_have_svg_icons():
	var panel := PBUvEditorPanel.new()

	# Row 1 buttons have icons
	assert_not_null(panel._btn_tool_move.icon, "Move tool button must have icon")
	assert_not_null(panel._btn_tool_rot.icon, "Rotate tool button must have icon")
	assert_not_null(panel._btn_tool_scale.icon, "Scale tool button must have icon")
	assert_not_null(panel._btn_mode_face.icon, "Face mode button must have icon")
	assert_not_null(panel._btn_mode_vert.icon, "Vertex mode button must have icon")
	assert_not_null(panel._btn_mode_edge.icon, "Edge mode button must have icon")
	assert_not_null(panel._btn_mode_island.icon, "Island mode button must have icon")
	assert_not_null(panel._btn_frame_unit.icon, "Frame unit button must have icon")
	assert_not_null(panel._btn_frame_sel.icon, "Frame selection button must have icon")
	assert_not_null(panel._btn_snap_toggle.icon, "Snap toggle button must have icon")
	assert_not_null(panel._btn_toggle_tex.icon, "Toggle texture button must have icon")
	assert_not_null(panel._btn_toggle_tile.icon, "Toggle tile button must have icon")
	assert_not_null(panel._btn_pop_out.icon, "Pop-out button must have icon")

	# Row 2 operation buttons have icons
	assert_not_null(panel._btn_mode_auto.icon, "Auto UV button must have icon")
	assert_not_null(panel._btn_mode_manual.icon, "Manual UV button must have icon")
	assert_not_null(panel._btn_proj_planar.icon, "Planar button must have icon")
	assert_not_null(panel._btn_proj_box.icon, "Box button must have icon")
	assert_not_null(panel._btn_proj_fit.icon, "Fit button must have icon")
	assert_not_null(panel._btn_flip_u.icon, "Flip U button must have icon")
	assert_not_null(panel._btn_flip_v.icon, "Flip V button must have icon")
	assert_not_null(panel._btn_rot_ccw.icon, "Rotate CCW button must have icon")
	assert_not_null(panel._btn_rot_cw.icon, "Rotate CW button must have icon")
	assert_not_null(panel._btn_sew.icon, "Sew button must have icon")
	assert_not_null(panel._btn_split.icon, "Split button must have icon")
	assert_not_null(panel._btn_collapse.icon, "Collapse button must have icon")
	assert_not_null(panel._btn_stitch.icon, "Stitch button must have icon")
	assert_not_null(panel._btn_texel_get.icon, "Texel get button must have icon")
	assert_not_null(panel._btn_texel_set.icon, "Texel set button must have icon")
	assert_not_null(panel._btn_export_png.icon, "Export PNG button must have icon")


func test_stitched_coincident_vertices_selected_and_move_together():
	var canvas := PBUvCanvas.new()
	canvas.size = Vector2(800, 600)
	canvas.zoom = 300.0

	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	# Auto-stitch Face 0 and Face 2 along their shared 3D edge
	var ok := PBUvOps.auto_stitch(cube, 0, 2)
	assert_true(ok, "auto_stitch must succeed")

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	canvas.active_mesh = mesh
	canvas.select_mode = PBUvCanvas.SelectMode.VERTEX

	# Vertex 1 on Face 0 and Vertex 8 on Face 2 are now stitched together
	var v1_uv := cube.textures0[1]
	var v8_uv := cube.textures0[8]
	assert_almost_eq(v1_uv.x, v8_uv.x, 0.0001, "Stitched vertices must share UV X")
	assert_almost_eq(v1_uv.y, v8_uv.y, 0.0001, "Stitched vertices must share UV Y")

	# Clicking vertex 1 must select BOTH coincident sewn vertices
	var v1_screen := canvas.uv_to_screen(v1_uv)
	canvas._handle_left_press(v1_screen, false)
	canvas._handle_left_release(v1_screen)

	assert_true(canvas.selected_verts.has(1), "Vertex 1 must be selected")
	assert_true(canvas.selected_verts.has(8), "Vertex 8 (coincident sewn vertex) must also be selected")
	assert_gte(canvas.selected_verts.size(), 2, "Both faces' corners must be selected together")

	# Move vertices via gizmo
	canvas._gizmo_drag_snapshot_uvs = canvas.get_uv_array().duplicate()
	canvas._gizmo_affected_indices = canvas.get_selected_vertex_indices()
	canvas.gizmo.begin_drag(PBUvGizmo.HandleType.MOVE_CENTER, v1_screen, canvas)
	var t := canvas.gizmo.apply_drag(v1_screen + Vector2(40, 50), canvas, false, false)
	canvas._apply_gizmo_transform(t)
	canvas.gizmo.commit_drag()

	# Assert that both vertices moved in lockstep and remain joined
	var new_v1 := cube.textures0[1]
	var new_v8 := cube.textures0[8]
	assert_almost_eq(new_v1.x, new_v8.x, 0.0001, "After move, vertex 1 and 8 must remain joined at same X")
	assert_almost_eq(new_v1.y, new_v8.y, 0.0001, "After move, vertex 1 and 8 must remain joined at same Y")
	assert_gt(v1_uv.distance_to(new_v1), 0.1, "Joined vertices must have moved together")

	mesh.free()
	canvas.free()

class MockPlugin:
	extends RefCounted
	var last_selected_subgizmo_id: int = -999
	func select_subgizmo_element(_mesh: PBMesh, id: int) -> void:
		last_selected_subgizmo_id = id

func test_bidirectional_vertex_selection_sync_with_3d():
	var panel := PBUvEditorPanel.new()
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	panel.active_mesh = mesh

	var mock_plugin := MockPlugin.new()
	var editor := PBEditor.new()
	editor.active_mesh = mesh
	editor.selection.set_mesh_data(cube)
	panel.editor = editor
	panel.plugin = mock_plugin

	# 1. Select vertex 0 in UV editor canvas
	panel.canvas.select_mode = PBUvCanvas.SelectMode.VERTEX
	var v0_uv: Vector2 = cube.textures0[0]
	var v0_screen: Vector2 = panel.canvas.uv_to_screen(v0_uv)
	panel.canvas._handle_left_press(v0_screen, false)
	panel.canvas._handle_left_release(v0_screen)

	# Verify 3D editor selection was updated
	var expected_sv: int = cube.get_shared_vertex_index(0)
	assert_eq(editor.select_mode, PBEditor.SelectMode.VERTEX, "3D editor must switch to VERTEX mode")
	assert_true(editor.selection.is_vertex_selected(expected_sv), "3D editor selection must have shared vertex selected")
	assert_eq(mock_plugin.last_selected_subgizmo_id, expected_sv, "Plugin select_subgizmo_element must be called with shared vertex id")

	mesh.free()
	panel.free()

func test_uv_box_unwrap_non_overlapping():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var ok := PBUvOps.unwrap_box(cube, [0, 1, 2, 3, 4, 5])
	assert_true(ok, "unwrap_box must return true")

	# Check that all 6 faces are manual_uv
	for fi in range(6):
		assert_true(cube.faces[fi].manual_uv, "Face %d must be manual_uv" % fi)

	# Verify none of the 6 face UV bounds overlap with each other
	var face_bounds: Array[Rect2] = []
	for fi in range(6):
		var f_verts := cube.faces[fi].get_distinct_indexes()
		var fb := PBUvOps.get_uv_bounds(cube.textures0, f_verts)
		face_bounds.append(fb)
		assert_gte(fb.position.x, -0.01, "Face %d min X must be >= 0" % fi)
		assert_gte(fb.position.y, -0.01, "Face %d min Y must be >= 0" % fi)
		assert_lte(fb.end.x, 1.01, "Face %d max X must be <= 1" % fi)
		assert_lte(fb.end.y, 1.01, "Face %d max Y must be <= 1" % fi)

	for i in range(5):
		for j in range(i + 1, 6):
			var r1 := face_bounds[i].grow(-0.005)
			var r2 := face_bounds[j].grow(-0.005)
			assert_false(r1.intersects(r2), "Face %d and Face %d must not overlap in unwrapped UV layout" % [i, j])

func test_export_uv_template_with_offset_islands():
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	# Displace Face 0 far outside [0, 1] to simulate scattered layout
	var f0_verts := cube.faces[0].get_distinct_indexes()
	PBUvOps.translate_uvs(cube, f0_verts, Vector2(2.5, 3.0))

	var test_path := "user://test_uv_template_offset.png"
	var err := PBUvOps.export_uv_template(cube, test_path, 256, Color.WHITE, Color.BLACK, false)
	assert_eq(err, OK, "export_uv_template with offset UVs must succeed")
	assert_true(FileAccess.file_exists(test_path), "Exported template with offset UVs must exist on disk")

	DirAccess.remove_absolute(test_path)

func test_click_off_in_vertex_mode_stays_in_vertex_mode():
	var panel := PBUvEditorPanel.new()
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	panel.active_mesh = mesh

	var editor := PBEditor.new()
	editor.active_mesh = mesh
	editor.selection.set_mesh_data(cube)
	panel.editor = editor

	# 1. Start in Face mode in 3D
	editor.select_mode = PBEditor.SelectMode.FACE
	panel.sync_selection_from_3d_state(editor.select_mode, editor.selection)

	# 2. Click Vertex mode in UV editor
	panel._btn_mode_vert.emit_signal("pressed")
	assert_eq(panel.canvas.select_mode, PBUvCanvas.SelectMode.VERTEX, "UV canvas must be in VERTEX mode")
	assert_eq(editor.select_mode, PBEditor.SelectMode.VERTEX, "3D editor must switch to VERTEX mode")
	assert_true(panel._btn_mode_vert.button_pressed, "Vertex button must be visually pressed")

	# 3. Click off on empty canvas space to deselect
	var empty_pos := Vector2(20, 20)
	panel.canvas._handle_left_press(empty_pos, false)
	panel.canvas._handle_left_release(empty_pos)

	# 4. Must STAY in Vertex mode!
	assert_eq(panel.canvas.select_mode, PBUvCanvas.SelectMode.VERTEX, "UV canvas must STAY in VERTEX mode after clicking off")
	assert_eq(editor.select_mode, PBEditor.SelectMode.VERTEX, "3D editor must STAY in VERTEX mode after clicking off")
	assert_true(panel._btn_mode_vert.button_pressed, "Vertex button must STAY visually pressed")

	mesh.free()
	panel.free()

func test_stitched_faces_move_together_in_face_mode():
	var panel := PBUvEditorPanel.new()
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	panel.active_mesh = mesh

	# Auto-stitch Face 0 and Face 2 along shared edge
	var ok := PBUvOps.auto_stitch(cube, 0, 2)
	assert_true(ok, "auto_stitch must succeed")

	# Vertex 1 on Face 0 and Vertex 8 on Face 2 are stitched together
	var v1_orig: Vector2 = cube.textures0[1]
	var v8_orig: Vector2 = cube.textures0[8]
	assert_almost_eq(v1_orig.x, v8_orig.x, 0.0001, "Stitched vertices must share X initially")
	assert_almost_eq(v1_orig.y, v8_orig.y, 0.0001, "Stitched vertices must share Y initially")

	# Select Face 0 in UV canvas
	panel.canvas.select_mode = PBUvCanvas.SelectMode.FACE
	panel.canvas.selected_faces[0] = true

	# Affected indices must include Face 2's coincident vertex (8)
	var affected := panel.canvas.get_selected_vertex_indices()
	assert_true(affected.has(1), "Affected indices must contain vertex 1")
	assert_true(affected.has(8), "Affected indices must contain sewn vertex 8 from adjacent face")

	# Drag Move gizmo
	panel.canvas._gizmo_drag_snapshot_uvs = panel.canvas.get_uv_array().duplicate()
	panel.canvas._gizmo_affected_indices = affected
	var p_screen := panel.canvas.uv_to_screen(panel.canvas.gizmo.pivot_uv)
	panel.canvas.gizmo.begin_drag(PBUvGizmo.HandleType.MOVE_CENTER, p_screen, panel.canvas)
	var t := panel.canvas.gizmo.apply_drag(p_screen + Vector2(50, 70), panel.canvas, false, false)
	panel.canvas._apply_gizmo_transform(t)
	panel.canvas.gizmo.commit_drag()

	# Assert both vertices remained joined at identical coordinates
	var new_v1: Vector2 = cube.textures0[1]
	var new_v8: Vector2 = cube.textures0[8]
	assert_almost_eq(new_v1.x, new_v8.x, 0.0001, "Vertex 1 and 8 must remain joined at same X")
	assert_almost_eq(new_v1.y, new_v8.y, 0.0001, "Vertex 1 and 8 must remain joined at same Y")
	assert_gt(v1_orig.distance_to(new_v1), 0.1, "Stitched vertices must have moved together")


func test_stock_cube_faces_are_not_joined_in_uv():
	var cube := PBShapeGenerators.create_box(Vector3.ONE)
	var panel := PBUvEditorPanel.new()
	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	panel.active_mesh = mesh

	# On a stock cube, corner (-0.5, -0.5, -0.5) has UV (0, 0) on Front (v1), Left (v8), and Bottom (v21).
	# However, none of these faces share a sewn edge, so they must NOT be considered joined.
	var coin := panel.canvas.get_coincident_uv_vertices(8)
	assert_eq(coin.size(), 1, "Vertex 8 on Left face must not be joined to Front or Bottom on a stock cube")
	assert_eq(coin[0], 8, "Vertex 8 must only be coincident with itself")

	# In Island Mode on a stock cube, each face must be its own independent island
	var island_0 := panel.canvas._get_uv_island(0)
	assert_eq(island_0.size(), 1, "Face 0 on a stock cube must be its own island")
	assert_eq(island_0[0], 0, "Island 0 must contain only Face 0")

	# In Face Mode, selecting Face 2 (Left) and getting affected indices must ONLY contain Face 2's vertices
	panel.canvas.select_mode = PBUvCanvas.SelectMode.FACE
	panel.canvas.selected_faces[2] = true
	var affected := panel.canvas.get_selected_vertex_indices()
	assert_true(affected.has(8), "Affected indices must contain Face 2's vertex 8")
	assert_false(affected.has(1), "Affected indices must NOT contain Face 0's vertex 1")
	assert_false(affected.has(21), "Affected indices must NOT contain Face 5's vertex 21")

	mesh.free()
	panel.free()

func test_uv_island_multi_face_3d_selection_sync():
	var cube := PBShapeGenerators.create_box(Vector3.ONE)
	var editor := PBEditor.new()
	var element_editor := PBElementEditor.new()
	element_editor.editor = editor

	# Simulate selecting an island of faces [0, 1, 2]
	var island_faces := PackedInt32Array([0, 1, 2])
	element_editor.set_selected_face_group(island_faces[0], island_faces)

	# expand_face_ids from the seed face 0 must expand to all faces in the island
	var expanded := element_editor.expand_face_ids(cube, PackedInt32Array([0]))
	assert_eq(expanded.size(), 3, "expand_face_ids must expand seed to all 3 island faces")
	assert_true(expanded.has(0), "Expanded faces must contain face 0")
	assert_true(expanded.has(1), "Expanded faces must contain face 1")
	assert_true(expanded.has(2), "Expanded faces must contain face 2")

	# mirror_engine_selection with engine_ids=[0] must preserve all 3 island faces
	editor.select_mode = PBEditor.SelectMode.FACE
	element_editor.mirror_engine_selection(editor.selection, cube, PackedInt32Array([0]))
	assert_eq(editor.selection.selected_faces.size(), 3, "editor.selection must retain all 3 island faces")
	assert_true(editor.selection.is_face_selected(0), "Face 0 must be selected in 3D")
	assert_true(editor.selection.is_face_selected(1), "Face 1 must be selected in 3D")
	assert_true(editor.selection.is_face_selected(2), "Face 2 must be selected in 3D")

	# Selecting a different face [4] in engine selection must clear the previous group
	element_editor.mirror_engine_selection(editor.selection, cube, PackedInt32Array([4]))
	assert_eq(editor.selection.selected_faces.size(), 1, "Selecting face 4 must drop previous island group")
	assert_true(editor.selection.is_face_selected(4), "Only face 4 must remain selected")

func test_texture_mode_in_scene_gizmo_transforms():
	var cube_data := PBShapeGenerators.create_box(Vector3.ONE)
	PBUv.refresh_mesh_uvs(cube_data, true)
	var node := PBMesh.new()
	node.pb_mesh_data = cube_data
	var editor := PBEditor.new()
	editor.active_mesh = node
	var element_editor := PBElementEditor.new()
	element_editor.editor = editor

	# 1. Selection mode and basis
	editor.select_mode = PBEditor.SelectMode.TEXTURE
	assert_true(editor.is_editing(), "TEXTURE mode must count as is_editing")
	editor.tool_mode = PBEditor.ToolMode.MOVE

	var f0_origin := element_editor.element_origin(cube_data, 0)
	var f0_basis := element_editor.element_basis(cube_data, node, 0)
	# Face 0 is Front (Z = -0.5)
	assert_almost_eq(f0_origin.z, -0.5, 0.01, "Face 0 centroid z must be -0.5")
	assert_almost_eq(f0_basis.z.z, -1.0, 0.01, "Face 0 normal basis z must point along normal -Z")

	# 2. Translate UVs via Move Tool
	var uvs_before := cube_data.textures0.duplicate()
	var start_xf := element_editor.get_subgizmo_transform(cube_data, node, 0)
	# Translate by 0.5m along face basis X (U axis)
	var moved_xf := Transform3D(start_xf.basis, start_xf.origin + f0_basis.x * 0.5)
	element_editor.set_subgizmo_transform(node, PackedInt32Array([0]), 0, moved_xf)

	var f0_indices: PackedInt32Array = cube_data.faces[0].get_distinct_indexes()
	var uv_diff := cube_data.textures0[f0_indices[0]] - uvs_before[f0_indices[0]]
	assert_gt(uv_diff.length(), 0.1, "UV coordinates of Face 0 must translate when moved in 3D")
	assert_true(cube_data.faces[0].manual_uv, "Face 0 must be converted to manual UV mode on drag")

	# Other faces must remain untouched
	var f1_indices: PackedInt32Array = cube_data.faces[1].get_distinct_indexes()
	assert_eq(cube_data.textures0[f1_indices[0]], uvs_before[f1_indices[0]], "Face 1 UVs must remain unchanged")

	# 3. Rotate UVs via Rotate Tool
	element_editor.commit_subgizmos(node, PackedInt32Array([0]), false)
	editor.tool_mode = PBEditor.ToolMode.ROTATE
	var rot_start_xf := element_editor.get_subgizmo_transform(cube_data, node, 0)
	var rotated_xf := Transform3D(rot_start_xf.basis.rotated(f0_basis.z, deg_to_rad(45)), rot_start_xf.origin)
	var uvs_pre_rot := cube_data.textures0.duplicate()
	element_editor.set_subgizmo_transform(node, PackedInt32Array([0]), 0, rotated_xf)

	var uv_rot_diff := cube_data.textures0[f0_indices[0]] - uvs_pre_rot[f0_indices[0]]
	assert_gt(uv_rot_diff.length(), 0.05, "UV coordinates of Face 0 must rotate when rotated in 3D")

	# 4. Commit and Undo
	var ur := UndoRedo.new()
	element_editor.undo = ur
	element_editor.commit_subgizmos(node, PackedInt32Array([0]), false)

	# Undoing must restore pre-rotation UVs
	ur.undo()
	assert_almost_eq(cube_data.textures0[f0_indices[0]].x, uvs_pre_rot[f0_indices[0]].x, 0.001, "Undo must restore pre-rotation U")
	assert_almost_eq(cube_data.textures0[f0_indices[0]].y, uvs_pre_rot[f0_indices[0]].y, 0.001, "Undo must restore pre-rotation V")

	# Redoing must restore rotated UVs
	ur.redo()
	assert_almost_eq(cube_data.textures0[f0_indices[0]].x, uvs_pre_rot[f0_indices[0]].x + uv_rot_diff.x, 0.001, "Redo must restore rotated U")

	node.free()
