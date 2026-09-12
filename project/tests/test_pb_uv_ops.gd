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
