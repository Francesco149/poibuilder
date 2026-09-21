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

## Total nonzero splat mask texels across a mesh (queue-deferral probe).
static func _mask_painted(mesh: PBMesh) -> int:
	var total := 0
	if mesh == null or mesh.pb_mesh_data == null:
		return 0
	for mat in mesh.pb_mesh_data.materials:
		if mat is ShaderMaterial and PBSplat.is_splat_material(mat):
			for i in range(1, PBSplat.MAX_LAYERS + 1):
				if (mat as ShaderMaterial).get_shader_parameter("layer_%d_enabled" % i) == true:
					var img := PBSplat.get_layer_mask_image(mat, i)
					if img == null:
						continue
					for b in img.get_data():
						if b != 0:
							total += 1
	return total

## Backpressure: consecutive same-face continuations MERGE into the pending
## chord, so a long fast stroke cannot pile up a queue that end_stroke would
## dump in one frame (the trace's 26-entry, 1.8 s release flush).
func test_pending_queue_stays_shallow_under_a_stroke() -> void:
	var cube := _test_cube
	var fi := _top_face(cube.pb_mesh_data)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, fi)
	ctrl.begin_stroke()
	for i in range(10):
		var x := -0.4 + 0.08 * float(i)
		ctrl.apply_paint_stroke_splat(cube, fi, Vector3(x + 0.04, 1.0, 0.0),
				Vector3(x, 1.0, 0.0))
	# 2 = the press disc (which must NOT chain-merge into a streak the user
	# never stroked) + the one merged chord of all ten continuations.
	assert_eq(ctrl._pending_sweeps.size(), 2,
			"chained same-face sweeps must merge; only the press disc stays apart")
	ctrl.end_stroke()

func test_face_mask_resolution_is_capped_for_big_faces() -> void:
	# The 3x3 face the user reported as the laggiest: its mask must not
	# exceed the 256 ceiling (512x512 still walked 30-55 K pixels per sweep
	# at ~700 ns/px in the GDScript loop, overshooting the frame budget).
	var data := PBMeshData.create_cube(3.0)
	var res := PBSplat.calculate_uniform_face_resolution(data, data.faces[0])
	assert_eq(res, Vector2i(256, 256), "a 3m face's splat mask must be capped at 256")

## Splitting a sweep into collinear pieces (what the time-slice queue does)
## must byte-match the single unsplit sweep in every brush mode: middle
## pieces skip both caps and the caps tile exactly along a straight chain.
func test_split_sweep_matches_unsplit() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var a := Vector3(-0.6, 1.0, 0.4)
	var c := Vector3(0.6, 1.0, 0.4)
	var m := a.lerp(c, 0.45)
	for v in [[0.5, false, "soft paint"], [0.0, false, "hard paint"], [0.35, true, "erase"]]:
		var radius: float = v[0]
		var erase: bool = v[1]
		var label: String = v[2]
		var split_mat := PBSplat.create_splat_material()
		var split_layer := _layer(split_mat)
		var one_mat := PBSplat.create_splat_material()
		var one_layer := _layer(one_mat)
		if erase:
			# Base coat, each with its OWN stroke ctx (a separate stroke).
			PBSplat.paint_face_splat_segment(data, data.faces[fi], split_mat, split_layer,
					a, c, radius + 0.1, 0.0, 1.0, false, {})
			PBSplat.paint_face_splat_segment(data, data.faces[fi], one_mat, one_layer,
					a, c, radius + 0.1, 0.0, 1.0, false, {})
		var ctx := {}
		PBSplat.paint_face_splat_segment(data, data.faces[fi], split_mat, split_layer,
				a, m, radius, 0.5, 1.0, erase, ctx, false, false)
		PBSplat.paint_face_splat_segment(data, data.faces[fi], split_mat, split_layer,
				m, c, radius, 0.5, 1.0, erase, ctx, true, true)
		var ctx2 := {}
		PBSplat.paint_face_splat_segment(data, data.faces[fi], one_mat, one_layer,
				a, c, radius, 0.5, 1.0, erase, ctx2)
		# Bool compare: GUT formats megabyte arrays into assert messages.
		assert_true(PBSplat.get_layer_mask_image(split_mat, split_layer).get_data()
				== PBSplat.get_layer_mask_image(one_mat, one_layer).get_data(),
				"a collinear split sweep must byte-match the unsplit one (%s)" % label)

## Time-slicing: sweeps queue on push (nothing painted), end_stroke flushes
## them synchronously BEFORE committing, and the drain paints at least one
## entry per call.
func test_sweeps_queue_and_flush_before_commit() -> void:
	var cube := _test_cube
	var data := cube.pb_mesh_data
	var fi := _top_face(data)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, fi)
	ctrl.begin_stroke()

	ctrl.apply_paint_stroke_splat(cube, fi, Vector3(0.4, 1.0, 0.2), Vector3(-0.4, 1.0, 0.2))
	ctrl.apply_paint_stroke_splat(cube, fi, Vector3(0.4, 1.0, -0.2), Vector3(-0.4, 1.0, -0.2))
	assert_true(_mask_painted(cube) == 0, "two queued sweeps must not paint until drained")

	# One drain pass paints at least one entry (frame-budget semantics).
	ctrl._drain_pending_sweeps()
	var after_one := _mask_painted(cube)
	assert_true(after_one > 0, "a drain pass must paint at least one queued sweep")

	ctrl.end_stroke()
	assert_true(_mask_painted(cube) >= after_one, "end_stroke must flush the rest before committing")

func test_sweep_snaps_to_face_endpoint_and_closes_the_seam() -> void:
	var cube := _test_cube
	var data := cube.pb_mesh_data
	var fi := _top_face(data)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, fi)
	ctrl.begin_stroke()

	# First run ends at x=0.3; the next run's pick lands 0.05m further (within
	# the 0.25r snap window) — the sweep must START from the recorded endpoint
	# so the seam between the two runs carries paint.
	ctrl.apply_paint_stroke_splat(cube, fi, Vector3(0.3, 1.0, 0.0), Vector3(-0.3, 1.0, 0.0))
	ctrl.apply_paint_stroke_splat(cube, fi, Vector3(0.6, 1.0, 0.0), Vector3(0.35, 1.0, 0.0))
	ctrl.flush_pending_sweeps()
	ctrl.end_stroke()

	var mat := data.get_face_material(data.faces[fi]) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(mat), "the sweeps must leave a splat material")
	var layer := PBSplat.get_first_active_layer(mat)
	# The seam point (0.325, 1, 0) sits between the two runs' endpoints: with
	# the snap it lies INSIDE the second sweep's band (weight ~255 region).
	assert_true(_mask_value(data, mat, data.faces[fi], layer, Vector3(0.325, 1.0, 0.0)) > 200,
			"the snapped continuation must paint the seam between runs")

func test_controller_run_dab_paints_and_tracks_last_dab() -> void:
	var cube := _test_cube
	var data := cube.pb_mesh_data
	var fi := _top_face(data)
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	ctrl.update_cursor(Vector3(0, 1.0, 0), Vector3.UP, cube, fi)
	ctrl.begin_stroke()

	# The interpolated walk's run dab: one swept call across the face —
	# ENQUEUED now (time-sliced painting): nothing is painted until a drain.
	ctrl.apply_paint_stroke_splat(cube, fi, Vector3(0.6, 1.0, 0.2), Vector3(-0.6, 1.0, 0.2))
	assert_false(ctrl.stroke_dirty, "a queued sweep must not mark the stroke dirty before it drains")
	assert_true(_mask_painted(cube) == 0, "a queued sweep must not paint until drained")

	ctrl.flush_pending_sweeps()
	assert_true(ctrl.stroke_dirty, "the drained sweep must mark the stroke dirty")

	ctrl.end_stroke()
	var mat := data.get_face_material(data.faces[fi]) as ShaderMaterial
	assert_true(PBSplat.is_splat_material(mat), "the run dab must leave a splat material")
	for frac in [0.0, 0.5, 1.0]:
		assert_true(_mask_value(data, mat, data.faces[fi], PBSplat.get_first_active_layer(mat),
				Vector3(-0.6 + 1.2 * frac, 1.0, 0.2)) > 200,
				"the swept run must paint continuously at %.1f" % frac)

## A trimmed continuation (near cap skipped) must byte-match the untrimmed
## one: the previous sweep's far half-cap + band already tile the disc at the
## shared endpoint at exactly the values the revisit would write.
func test_trimmed_continuation_matches_full_sweep() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var a := Vector3(-0.6, 1.0, 0.35)
	var b := Vector3(0.0, 1.0, 0.35)
	var c := Vector3(0.6, 1.0, 0.35)

	var trim_mat := PBSplat.create_splat_material()
	var trim_layer := _layer(trim_mat)
	var ctx := {}
	PBSplat.paint_face_splat_segment(data, data.faces[fi], trim_mat, trim_layer,
			a, b, 0.3, 0.5, 1.0, false, ctx)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], trim_mat, trim_layer,
			b, c, 0.3, 0.5, 1.0, false, ctx, true)

	var full_mat := PBSplat.create_splat_material()
	var full_layer := _layer(full_mat)
	var ctx2 := {}
	PBSplat.paint_face_splat_segment(data, data.faces[fi], full_mat, full_layer,
			a, b, 0.3, 0.5, 1.0, false, ctx2)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], full_mat, full_layer,
			b, c, 0.3, 0.5, 1.0, false, ctx2)

	# Bool compare — GUT formats megabyte arrays into its messages otherwise.
	assert_true(PBSplat.get_layer_mask_image(trim_mat, trim_layer).get_data()
			== PBSplat.get_layer_mask_image(full_mat, full_layer).get_data(),
			"a trimmed continuation must byte-match the untrimmed sweep")

## Erase sweeps must IGNORE the trim flag: erase's wmax accounting takes the
## max sub over visits, so the result depends on visit order (a trimmed
## continuation can land a different total sub on rim pixels). The walk
## clamps trim off for erase, so an erase continuation with the flag set
## must still byte-match the untrimmed one.
func test_trimmed_erase_matches_full_erase() -> void:
	var data := _test_cube.pb_mesh_data
	var fi := _top_face(data)
	var a := Vector3(-0.6, 1.0, -0.35)
	var b := Vector3(0.0, 1.0, -0.35)
	var c := Vector3(0.6, 1.0, -0.35)

	var trim_mat := PBSplat.create_splat_material()
	var trim_layer := _layer(trim_mat)
	var ctx := {}
	# Base coat (its OWN stroke ctx), then two erase sweeps sharing one
	# stroke's ctx — second one passes the trim flag, which the walk must
	# clamp off for erase.
	PBSplat.paint_face_splat_segment(data, data.faces[fi], trim_mat, trim_layer,
			a, c, 0.35, 0.0, 1.0, false, {})
	PBSplat.paint_face_splat_segment(data, data.faces[fi], trim_mat, trim_layer,
			a, b, 0.25, 0.5, 1.0, true, ctx)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], trim_mat, trim_layer,
			b, c, 0.25, 0.5, 1.0, true, ctx, true)

	var full_mat := PBSplat.create_splat_material()
	var full_layer := _layer(full_mat)
	var ctx2 := {}
	PBSplat.paint_face_splat_segment(data, data.faces[fi], full_mat, full_layer,
			a, c, 0.35, 0.0, 1.0, false, {})
	PBSplat.paint_face_splat_segment(data, data.faces[fi], full_mat, full_layer,
			a, b, 0.25, 0.5, 1.0, true, ctx2)
	PBSplat.paint_face_splat_segment(data, data.faces[fi], full_mat, full_layer,
			b, c, 0.25, 0.5, 1.0, true, ctx2)

	assert_true(PBSplat.get_layer_mask_image(trim_mat, trim_layer).get_data()
			== PBSplat.get_layer_mask_image(full_mat, full_layer).get_data(),
			"a trimmed erase continuation must byte-match the untrimmed one")
