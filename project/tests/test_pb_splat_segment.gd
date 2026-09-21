## test_pb_splat_segment.gd — the swept splat dab (paint_face_splat_segment).
##
## The splat brush paints the cursor path as ONE capsule per same-face run
## instead of a disc per spacing step (the iGPU paint-lag fix: a fast stroke
## stamped ~25 overlapping discs and re-walked each mask pixel up to ten
## times). These pin the sweep's semantics against the stamped discs it
## replaced: coverage is a pointwise superset, values at dab centres match,
## a zero-length segment degenerates to the disc dab, erase stays
## once-per-stroke, and the controller's run dab keeps stroke bookkeeping.
@tool
extends GutTest

func before_each() -> void:
	_test_cube = PBMesh.create_cube(2.0)
	add_child_autofree(_test_cube)

func after_each() -> void:
	_test_cube = null

var _test_cube: PBMesh = null

func _top_face(data: PBMeshData) -> int:
	for fi in range(data.faces.size()):
		var n := PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes())
		if n.y > 0.99:
			return fi
	return -1

func _layer(mat: ShaderMaterial) -> int:
	return PBSplat.add_layer(mat, ImageTexture.create_from_image(
		Image.create(16, 16, false, Image.FORMAT_RGBA8)))

## Mask value (0..255) at a node-local point of `face`, through the face's
## planar [0,1] bounds — the same mapping the shader's CUSTOM0 uses.
func _mask_value(data: PBMeshData, mat: ShaderMaterial, face: PBFace, layer: int,
		local_point: Vector3) -> int:
	var bounds := PBSplat.get_face_planar_bounds(data, face)
	var u := ((bounds["u"] as Vector3).dot(local_point) - float(bounds["min_u"])) / float(bounds["range_u"])
	var v := ((bounds["v"] as Vector3).dot(local_point) - float(bounds["min_v"])) / float(bounds["range_v"])
	var img := PBSplat.get_layer_mask_image(mat, layer)
	var x := clampi(int(u * float(img.get_width() - 1)), 0, img.get_width() - 1)
	var y := clampi(int(v * float(img.get_height() - 1)), 0, img.get_height() - 1)
	return int(img.get_data()[y * img.get_width() + x])

func test_segment_paints_its_whole_path() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	assert_true(fi >= 0, "cube must have a top face")
	var mat := PBSplat.create_splat_material()
	var layer := _layer(mat)

	var ctx := {}
	var painted := PBSplat.paint_face_splat_segment(data, data.faces[fi], mat, layer,
			Vector3(-0.6, 1.0, 0.3), Vector3(0.6, 1.0, 0.3), 0.3, 0.5, 1.0, false, ctx)
	assert_true(painted, "a 1.2 m sweep must paint")

	# The spine is the capsule's closest point to the centre — full weight —
	# at every fraction INCLUDING the middle (the "dotted stroke" regression).
	for frac in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var p := Vector3(-0.6 + 1.2 * frac, 1.0, 0.3)
		assert_true(_mask_value(data, mat, data.faces[fi], layer, p) > 200,
			"spine at %.2f must be painted (sweeps must be continuous)" % frac)
	# Two radii off the path the falloff has died: nothing painted.
	assert_eq(_mask_value(data, mat, data.faces[fi], layer, Vector3(0.0, 1.0, 1.2)), 0,
		"the falloff must die by two radii off the path")

func test_segment_values_geq_dense_stamped_discs() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var from_p := Vector3(-0.6, 1.0, -0.2)
	var to_p := Vector3(0.6, 1.0, -0.2)

	# The old behaviour: discs stamped every half-radius along the same path,
	# one stroke ctx (so their max accumulates the way a real stroke did).
	var stamp_mat := PBSplat.create_splat_material()
	var stamp_layer := _layer(stamp_mat)
	var stamp_ctx := {}
	for i in range(9):
		PBSplat.paint_face_splat(data, data.faces[fi], stamp_mat, stamp_layer,
				from_p.lerp(to_p, float(i) / 8.0), 0.3, 0.5, 1.0, false, stamp_ctx)

	# The new behaviour: the same path as ONE swept capsule.
	var sweep_mat := PBSplat.create_splat_material()
	var sweep_layer := _layer(sweep_mat)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], sweep_mat, sweep_layer,
			from_p, to_p, 0.3, 0.5, 1.0, false, {})

	var stamp_img := PBSplat.get_layer_mask_image(stamp_mat, stamp_layer)
	var sweep_img := PBSplat.get_layer_mask_image(sweep_mat, sweep_layer)
	var stamp_b := stamp_img.get_data()
	var sweep_b := sweep_img.get_data()
	assert_eq(stamp_b.size(), sweep_b.size(), "both masks must share the face's resolution")
	var swept_below := 0
	for i in range(stamp_b.size()):
		if sweep_b[i] < stamp_b[i]:
			swept_below += 1
	assert_eq(swept_below, 0,
		"the sweep is distance-to-a-continuum: no pixel may fall below the stamped discs' max")
	# At the dab centres the two agree exactly (same LUT, same distance).
	for frac in [0.0, 0.5, 1.0]:
		var p := from_p.lerp(to_p, frac)
		var dv := _mask_value(data, sweep_mat, data.faces[fi], sweep_layer, p) \
				- _mask_value(data, stamp_mat, data.faces[fi], stamp_layer, p)
		assert_true(absi(dv) <= 1, "values at dab centres must match at %.1f (delta %d)" % [frac, dv])

## Every dispatch branch of the segment walk (u-aligned, v-aligned, general
## diagonal) must hold the same contract against dense stamped discs: the
## sweep never paints below their pointwise max, and its spine is continuous.
## The horizontal case exercises the u-aligned fast path, the vertical case
## the transposed v-aligned one, and 45 degrees the general per-pixel walk.
func test_segment_all_branches_geq_stamped_discs() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var dirs := {
		"u-aligned": Vector3(1.2, 0, 0),
		"v-aligned": Vector3(0, 0, 1.2),
		"diagonal (general)": Vector3(0.6, 0, -0.6) * 1.4142,
	}
	for branch: String in dirs:
		var delta: Vector3 = dirs[branch]
		var from_p := Vector3(-0.5, 1.0, 0.1) - delta * 0.5
		var to_p := from_p + delta

		var stamp_mat := PBSplat.create_splat_material()
		var stamp_layer := _layer(stamp_mat)
		var stamp_ctx := {}
		for i in range(9):
			PBSplat.paint_face_splat(data, data.faces[fi], stamp_mat, stamp_layer,
					from_p.lerp(to_p, float(i) / 8.0), 0.3, 0.5, 1.0, false, stamp_ctx)

		var sweep_mat := PBSplat.create_splat_material()
		var sweep_layer := _layer(sweep_mat)
		var ctx := {}
		var painted := PBSplat.paint_face_splat_segment(data, data.faces[fi], sweep_mat,
				sweep_layer, from_p, to_p, 0.3, 0.5, 1.0, false, ctx)
		assert_true(painted, "%s: the sweep must paint" % branch)

		var stamp_b := PBSplat.get_layer_mask_image(stamp_mat, stamp_layer).get_data()
		var sweep_b := PBSplat.get_layer_mask_image(sweep_mat, sweep_layer).get_data()
		var swept_below := 0
		for i in range(stamp_b.size()):
			if sweep_b[i] < stamp_b[i]:
				swept_below += 1
		assert_eq(swept_below, 0, "%s: no pixel may fall below the stamped discs' max" % branch)
		for frac in [0.25, 0.5, 0.75]:
			var mid := from_p.lerp(to_p, frac)
			assert_true(_mask_value(data, sweep_mat, data.faces[fi], sweep_layer, mid) > 200,
				"%s: the spine must be painted at %.2f" % [branch, frac])

## A v-aligned sweep and a u-aligned sweep of the same length paint the same
## capsule (the transposed normalization must not skew the geometry).
func test_segment_v_aligned_matches_u_aligned_geometry() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var h_mat := PBSplat.create_splat_material()
	var h_layer := _layer(h_mat)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], h_mat, h_layer,
			Vector3(-0.5, 1.0, 0.0), Vector3(0.5, 1.0, 0.0), 0.3, 0.5, 1.0, false, {})
	var v_mat := PBSplat.create_splat_material()
	var v_layer := _layer(v_mat)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], v_mat, v_layer,
			Vector3(0.0, 1.0, -0.5), Vector3(0.0, 1.0, 0.5), 0.3, 0.5, 1.0, false, {})

	var h_img := PBSplat.get_layer_mask_image(h_mat, h_layer)
	var v_img := PBSplat.get_layer_mask_image(v_mat, v_layer)
	var n := h_img.get_width()
	var worst := 0
	for y in range(n):
		for x in range(n):
			# Transpose the horizontal mask; compare against the vertical one.
			var a := int(h_img.get_data()[x * n + y])
			var b := int(v_img.get_data()[y * n + x])
			worst = maxi(worst, absi(a - b))
	assert_true(worst <= 1, "u- and v-aligned sweeps must be transposes of each other (worst delta %d)" % worst)

func test_zero_length_segment_degenerates_to_disc() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var at := Vector3(0.2, 1.0, -0.4)

	var seg_mat := PBSplat.create_splat_material()
	var seg_layer := _layer(seg_mat)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], seg_mat, seg_layer,
			at, at, 0.3, 0.5, 1.0, false, {})

	var disc_mat := PBSplat.create_splat_material()
	var disc_layer := _layer(disc_mat)
	PBSplat.paint_face_splat(data, data.faces[fi], disc_mat, disc_layer,
			at, 0.3, 0.5, 1.0, false, {})

	var seg_img := PBSplat.get_layer_mask_image(seg_mat, seg_layer)
	var disc_img := PBSplat.get_layer_mask_image(disc_mat, disc_layer)
	# Bool compare, not assert_eq: GUT formats megabyte PackedByteArrays into
	# its messages (the suite dies in the memory guard even on a pass).
	assert_true(seg_img.get_data() == disc_img.get_data(),
		"a zero-length sweep must paint exactly the disc dab")

func test_segment_erase_is_once_per_stroke() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var mat := PBSplat.create_splat_material()
	var layer := _layer(mat)
	# Opaque base coat, hard brush.
	PBSplat.paint_face_splat(data, data.faces[fi], mat, layer,
			Vector3(0, 1.0, 0), 0.5, 0.0, 1.0, false, {})

	# One erase sweep down the middle (same stroke ctx for both calls).
	var ctx := {}
	var spine := Vector3(-0.4, 1.0, 0.0)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], mat, layer,
			spine, Vector3(0.4, 1.0, 0.0), 0.25, 0.5, 1.0, true, ctx)
	var after_once := PBSplat.get_layer_mask_image(mat, layer).get_data().duplicate()
	var erased := 0
	for i in range(after_once.size()):
		if after_once[i] == 0:
			erased += 1
	assert_true(erased > 100, "the erase sweep must have drained its spine (%d px)" % erased)

	# Re-erasing the SAME segment in the SAME stroke must not drain further:
	# erase applies once per pixel per stroke (wmax bookkeeping). Bool compare
	# for the same megabyte-formatting reason as above.
	PBSplat.paint_face_splat_segment(data, data.faces[fi], mat, layer,
			spine, Vector3(0.4, 1.0, 0.0), 0.25, 0.5, 1.0, true, ctx)
	assert_true(PBSplat.get_layer_mask_image(mat, layer).get_data() == after_once,
		"a repeated erase sweep within one stroke must be a no-op")

func test_controller_run_dab_paints_and_tracks_last_dab() -> void:
	var cube := _test_cube
	var data := cube.pb_mesh_data
	var fi := _top_face(data)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, fi)
	ctrl.begin_stroke()

	# The interpolated walk's run dab: one swept call across the face.
	ctrl.apply_paint_stroke_splat(cube, fi, Vector3(0.6, 1.0, 0.2), Vector3(-0.6, 1.0, 0.2))
	assert_true(ctrl.stroke_dirty, "the run dab must mark the stroke dirty")

	ctrl.end_stroke()
	var mat := data.get_face_material(data.faces[fi]) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(mat), "the run dab must leave a splat material")
	for frac in [0.0, 0.5, 1.0]:
		assert_true(_mask_value(data, mat, data.faces[fi], PBSplat.get_first_active_layer(mat),
				Vector3(-0.6 + 1.2 * frac, 1.0, 0.2)) > 200,
				"the swept run must paint continuously at %.1f" % frac)
