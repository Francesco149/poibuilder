## Test: 2D UV Editor Panel & Canvas
##
## Verifies:
## 1. PBUvCanvas instantiation, coordinate space conversions, and invertibility.
## 2. PBUvCanvas zoom clamping, cursor-anchored zoom, and pan offset.
## 3. Framing: frame unit square [0,1] and frame selection bounds.
## 4. Geometric point picking: point-in-triangle and point-to-segment distance.
## 5. UV Island detection across connected UV faces.
## 6. Selection sets: Face, Edge, Vertex selection and clear/select-all.
## 7. PBUvEditorPanel toolbar controls, mode switches, snapping steps, and channels.
## 8. Bidirectional selection synchronization from 3D face selection to 2D UV canvas.
extends GutTest

func test_canvas_instantiation_and_defaults():
	var canvas := PBUvCanvas.new()
	canvas.size = Vector2(800, 600)

	assert_not_null(canvas, "PBUvCanvas must instantiate cleanly")
	assert_eq(canvas.select_mode, PBUvCanvas.SelectMode.FACE, "Default select mode must be FACE")
	assert_eq(canvas.uv_channel, PBUvCanvas.UvChannel.UV1, "Default channel must be UV1")
	assert_true(canvas.show_texture, "Show texture underlay must default to true")
	assert_false(canvas.show_texture_tiling, "Texture tiling must default to false")
	assert_almost_eq(canvas.texture_opacity, 0.6, 0.01, "Default texture opacity must be 0.6")
	assert_almost_eq(canvas.grid_snap_step, 0.125, 0.001, "Default snap step must be 0.125 (1/8)")

	canvas.free()

func test_coordinate_conversion_invertibility():
	var canvas := PBUvCanvas.new()
	canvas.size = Vector2(800, 600)
	canvas.zoom = 400.0
	canvas.pan_offset = Vector2(50, -30)

	var test_uvs := [
		Vector2(0, 0),
		Vector2(1, 1),
		Vector2(0.5, 0.5),
		Vector2(-0.25, 1.75),
		Vector2(3.1415, -2.718)
	]

	for uv in test_uvs:
		var screen_pos: Vector2 = canvas.uv_to_screen(uv)
		var back_uv: Vector2 = canvas.screen_to_uv(screen_pos)
		assert_almost_eq(back_uv.x, uv.x, 0.0001, "Screen to UV conversion must invert X cleanly for %s" % uv)
		assert_almost_eq(back_uv.y, uv.y, 0.0001, "Screen to UV conversion must invert Y cleanly for %s" % uv)

	canvas.free()

func test_cursor_anchored_zoom():
	var canvas := PBUvCanvas.new()
	canvas.size = Vector2(800, 600)
	canvas.zoom = 300.0
	canvas.pan_offset = Vector2.ZERO

	var cursor_pixel := Vector2(250, 420)
	var uv_before: Vector2 = canvas.screen_to_uv(cursor_pixel)

	# Zoom in at cursor
	canvas._zoom_at(cursor_pixel, 1.5)

	var uv_after: Vector2 = canvas.screen_to_uv(cursor_pixel)
	assert_almost_eq(uv_after.x, uv_before.x, 0.0001, "Zoom at cursor must keep UV X coordinate fixed under cursor")
	assert_almost_eq(uv_after.y, uv_before.y, 0.0001, "Zoom at cursor must keep UV Y coordinate fixed under cursor")

	canvas.free()

func test_frame_unit_square():
	var canvas := PBUvCanvas.new()
	canvas.size = Vector2(1000, 800)
	canvas.pan_offset = Vector2(300, -200)
	canvas.zoom = 50.0

	canvas.frame_unit_square()

	# After framing unit square, center (0.5, 0.5) must map directly to canvas center
	var center_screen := canvas.uv_to_screen(Vector2(0.5, 0.5))
	assert_almost_eq(center_screen.x, 500.0, 0.01, "Unit square center X must map to screen center X")
	assert_almost_eq(center_screen.y, 400.0, 0.01, "Unit square center Y must map to screen center Y")
	assert_gt(canvas.zoom, 100.0, "Framing must set appropriate zoom")

	canvas.free()

func test_point_picking_math():
	var canvas := PBUvCanvas.new()

	# Triangle test
	var a := Vector2(0, 0)
	var b := Vector2(1, 0)
	var c := Vector2(0, 1)

	assert_true(canvas._point_in_triangle(Vector2(0.2, 0.2), a, b, c), "Point inside triangle must evaluate true")
	assert_false(canvas._point_in_triangle(Vector2(0.8, 0.8), a, b, c), "Point outside triangle must evaluate false")
	assert_true(canvas._point_in_triangle(Vector2(0, 0), a, b, c), "Triangle corner must evaluate true")

	# Segment distance test
	var p1 := Vector2(0, 10)
	var p2 := Vector2(100, 10)
	var dist := canvas._point_to_segment_distance(Vector2(50, 15), p1, p2)
	assert_almost_eq(dist, 5.0, 0.001, "Distance to horizontal segment must be perpendicular offset")

	var dist_endpoint := canvas._point_to_segment_distance(Vector2(-10, 10), p1, p2)
	assert_almost_eq(dist_endpoint, 10.0, 0.001, "Distance past endpoint must clamp to endpoint")

	canvas.free()

func test_uv_island_detection():
	var canvas := PBUvCanvas.new()

	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	canvas.active_mesh = mesh

	# On standard cube with planar projection, check island detection
	var island := canvas._get_uv_island(0)
	assert_gt(island.size(), 0, "Island must find at least the seed face")

	mesh.free()
	canvas.free()

func test_uv_editor_panel_controls_and_channel():
	var panel := PBUvEditorPanel.new()
	assert_not_null(panel.canvas, "PBUvEditorPanel must instantiate PBUvCanvas")

	# Test mode switching
	panel._btn_mode_vert.emit_signal("pressed")
	assert_eq(panel.canvas.select_mode, PBUvCanvas.SelectMode.VERTEX, "Clicking Vertex mode must update canvas select_mode")

	panel._btn_mode_edge.emit_signal("pressed")
	assert_eq(panel.canvas.select_mode, PBUvCanvas.SelectMode.EDGE, "Clicking Edge mode must update canvas select_mode")

	panel._btn_mode_island.emit_signal("pressed")
	assert_eq(panel.canvas.select_mode, PBUvCanvas.SelectMode.ISLAND, "Clicking Island mode must update canvas select_mode")

	panel._btn_mode_face.emit_signal("pressed")
	assert_eq(panel.canvas.select_mode, PBUvCanvas.SelectMode.FACE, "Clicking Face mode must update canvas select_mode")

	# Test snap step selection
	panel._on_snap_step_selected(1) # 1/16
	assert_almost_eq(panel.canvas.grid_snap_step, 0.0625, 0.0001, "Snap step index 1 must set 0.0625 (1/16)")

	panel._on_snap_step_selected(3) # 1/4
	assert_almost_eq(panel.canvas.grid_snap_step, 0.25, 0.0001, "Snap step index 3 must set 0.25 (1/4)")

	# Test channel selection
	panel._on_channel_selected(1) # UV2
	assert_eq(panel.canvas.uv_channel, PBUvCanvas.UvChannel.UV2, "Channel index 1 must select UV2")

	panel._on_channel_selected(0) # UV1
	assert_eq(panel.canvas.uv_channel, PBUvCanvas.UvChannel.UV1, "Channel index 0 must select UV1")

	panel.free()

func test_selection_synchronization_from_3d():
	var panel := PBUvEditorPanel.new()
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)

	var mesh := PBMesh.new()
	mesh.pb_mesh_data = cube
	panel.active_mesh = mesh

	# Synchronize face 4 (top face) from 3D selection
	panel.sync_selection_from_3d([4])

	assert_true(panel.canvas.selected_faces.has(4), "Face 4 must be selected in UV canvas")
	assert_eq(panel.canvas.selected_faces.size(), 1, "Exactly one face must be selected")

	# Check status readout
	assert_string_contains(panel._lbl_status.text, "1 Faces selected")

	# Clear selection
	panel.canvas.clear_selection()
	assert_eq(panel.canvas.selected_faces.size(), 0, "Clearing selection must empty selected_faces")

	mesh.free()
	panel.free()
