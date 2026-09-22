## test_pb_paint_perf.gd — headless paint-stroke micro-benchmarks.
##
## These measure the GDScript pixel-loop cost of splat painting WITHOUT
## the editor, display, or GPU texture upload — the component the interactive
## trace identified as the dominant bottleneck on the iGPU.
##
## The tests time repeated dab/segment walks on cubes of known size, on the
## UNIFORM live mask every face now paints on (PBSplat.MASK_RESOLUTION), under
## both hard and soft brush. They verify:
## 1. Per-dab cost stays inside a generous envelope (50 ms first dab, 20 ms
##    subsequent — headless is faster than the real editor, so these are
##    worst-case bounds, not tight ones).
## 2. Per-dab cost does NOT scale with the face's world size: that coupling
##    (a mask sized at 256 texels/m) is exactly what made a 3 m face the
##    laggiest thing the painter could brush, and it is what the uniform mask
##    removed. Measured here, headlessly.
##
## The row-skip scanline bookkeeping is deliberately NOT asserted as a speedup:
## it was measured at 3-7% against the same code with row_max disabled, i.e.
## inside the noise. See the round's notes in CHANGELOG.md.
##
## NOT a substitute for the interactive trace (trace_paint.sh) or the
## real-GPU perf bench (run_paint_perf.sh) — those test the full pipeline
## including texture upload and frame pacing.  This catches regressions in
## the pixel loop itself, headlessly, in the regular test suite.
@tool
extends GutTest

## A cube large enough that the uniform live mask is what caps the walk
## (under the old density policy a 3 m face carried a 512x512 mask).
const CUBE_SIZE := 3.0
## Brush parameters matching the default interactive brush.
const BRUSH_RADIUS := 0.5
const BRUSH_OPACITY := 0.8

var _mesh: PBMesh = null

func before_each() -> void:
	_mesh = PBMesh.create_cube(CUBE_SIZE)
	add_child_autofree(_mesh)

func after_each() -> void:
	_mesh = null

func _top_face(data: PBMeshData) -> int:
	for fi in range(data.faces.size()):
		var n := PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes())
		if n.y > 0.99:
			return fi
	return -1

# ==============================================================================
# Benchmark helpers
# ==============================================================================

## Simulates a fast horizontal stroke across the top face of the cube:
## a series of segment sweeps advancing by `advance` metres each step,
## using `brush_soft` softness.  Returns an array of per-dab times in µs.
func _bench_stroke(brush_soft: float, advance: float, dabs: int) -> Array[float]:
	var data := _mesh.pb_mesh_data
	PBSplat.ensure_mesh_splat_uv(data)
	var fi := _top_face(data)
	assert_ne(fi, -1, "fixture: cube must have a top face")
	var face := data.faces[fi]
	var splat_mat := PBSplat.create_splat_material()
	data.set_face_material(face, splat_mat)
	var layer := PBSplat.add_layer(splat_mat, ImageTexture.create_from_image(
			Image.create(16, 16, false, Image.FORMAT_RGBA8)))

	var stroke_ctx := {}
	var times: Array[float] = []
	var y := CUBE_SIZE * 0.5  # on top face
	var z := 0.0  # centre of face
	# Start at left edge, walk right
	var x_start := -(CUBE_SIZE * 0.4)
	var prev := Vector3.INF

	for i in range(dabs):
		var x := x_start + float(i) * advance
		var pt := Vector3(x, y, z)
		var t0 := Time.get_ticks_usec()
		if prev != Vector3.INF:
			PBSplat.paint_face_splat_segment(data, face, splat_mat, layer,
					prev, pt, BRUSH_RADIUS, brush_soft, BRUSH_OPACITY,
					false, stroke_ctx)
		else:
			PBSplat.paint_face_splat(data, face, splat_mat, layer,
					pt, BRUSH_RADIUS, brush_soft, BRUSH_OPACITY,
					false, stroke_ctx)
		var elapsed := float(Time.get_ticks_usec() - t0)
		times.append(elapsed)
		prev = pt

	return times

# ==============================================================================
# Benchmark tests
# ==============================================================================

func test_hard_brush_stroke_perf() -> void:
	# 20 dabs, advancing 0.15 m each step (overlapping heavily at r=0.5)
	var times := _bench_stroke(0.0, 0.15, 20)
	var first := times[0]
	# Subsequent dabs (skip first 2 for warmup)
	var subsequent: Array[float] = []
	for i in range(2, times.size()):
		subsequent.append(times[i])
	var mean_sub := 0.0
	for t in subsequent:
		mean_sub += t
	mean_sub /= float(subsequent.size())

	gut.p("[PAINT PERF] hard brush 256x256: first=%.0f µs, mean_subsequent=%.0f µs (n=%d)" % [
			first, mean_sub, subsequent.size()])

	# Row-skip should make subsequent dabs much cheaper than the first.
	# First dab paints ALL rows; subsequent dabs overlap and row_max
	# causes most rows to be skipped entirely.
	assert_lt(first, 50000.0,
			"first hard dab on the uniform mask must be < 50 ms (was %.1f ms)" % [first / 1000.0])
	assert_lt(mean_sub, 20000.0,
			"subsequent hard dabs must be < 20 ms mean (was %.1f ms)" % [mean_sub / 1000.0])

	# Amortisation ratio: subsequent should be noticeably cheaper
	if first > 1000.0:  # don't divide by near-zero
		var ratio := first / mean_sub
		gut.p("[PAINT PERF] amortisation ratio: %.1fx" % ratio)

func test_soft_brush_stroke_perf() -> void:
	var times := _bench_stroke(0.5, 0.15, 20)
	var first := times[0]
	var subsequent: Array[float] = []
	for i in range(2, times.size()):
		subsequent.append(times[i])
	var mean_sub := 0.0
	for t in subsequent:
		mean_sub += t
	mean_sub /= float(subsequent.size())

	gut.p("[PAINT PERF] soft brush 256x256: first=%.0f µs, mean_subsequent=%.0f µs (n=%d)" % [
			first, mean_sub, subsequent.size()])

	assert_lt(first, 50000.0,
			"first soft dab on the uniform mask must be < 50 ms (was %.1f ms)" % [first / 1000.0])
	assert_lt(mean_sub, 20000.0,
			"subsequent soft dabs must be < 20 ms mean (was %.1f ms)" % [mean_sub / 1000.0])

func test_disc_dab_perf() -> void:
	# Repeated disc dabs at the same spot — worst case for overlap
	var data := _mesh.pb_mesh_data
	PBSplat.ensure_mesh_splat_uv(data)
	var fi := _top_face(data)
	assert_ne(fi, -1)
	var face := data.faces[fi]
	var splat_mat := PBSplat.create_splat_material()
	data.set_face_material(face, splat_mat)
	var layer := PBSplat.add_layer(splat_mat, ImageTexture.create_from_image(
			Image.create(16, 16, false, Image.FORMAT_RGBA8)))

	var stroke_ctx := {}
	var pt := Vector3(0.0, CUBE_SIZE * 0.5, 0.0)
	var times: Array[float] = []

	for i in range(10):
		var t0 := Time.get_ticks_usec()
		PBSplat.paint_face_splat(data, face, splat_mat, layer,
				pt, BRUSH_RADIUS, 0.5, BRUSH_OPACITY, false, stroke_ctx)
		times.append(float(Time.get_ticks_usec() - t0))

	var first := times[0]
	var last := times[times.size() - 1]
	gut.p("[PAINT PERF] disc dab same spot: first=%.0f µs, last=%.0f µs" % [first, last])

	# After the first dab, subsequent dabs at the same spot skip all writes
	# (every pixel's wmax already covers the target), but the GDScript loop
	# still visits each pixel for the wmax check.  The per-pixel overhead
	# is ~700 ns, so 5-8K pixels → 4-6 ms; 15 ms is a generous envelope.
	assert_lt(first, 50000.0,
			"first disc dab must be < 50 ms (was %.1f ms)" % [first / 1000.0])
	assert_lt(last, 15000.0,
			"repeated disc dab must be < 15 ms (was %.1f ms)" % [last / 1000.0])

## Per-dab cost must NOT scale with the face's world size. This is the
## invariant the uniform live mask exists to hold, and the one the painter
## felt: under the old 256-texels/m policy a 3 m face carried a 512x512 mask
## (4x the pixels of a 1.5 m one), so the SAME brush was several times more
## expensive there — the reported "small faces lag" (it is really
## "densely-sampled faces lag", and face size is what set the density).
##
## The walk itself is what is timed, on masks of identical resolution, so this
## fails if anyone reintroduces a size-dependent live mask.
func test_paint_cost_does_not_scale_with_face_size() -> void:
	# 0.5 m is the face the painter brushes constantly; 8 m is the same brush
	# over a much larger surface. Both paint on PBSplat.MASK_RESOLUTION.
	var small := PBMesh.create_cube(0.5)
	var large := PBMesh.create_cube(8.0)
	add_child_autofree(small)
	add_child_autofree(large)

	var small_mean := _mean_segment_dab_ms(small, 0.5)
	var large_mean := _mean_segment_dab_ms(large, 0.5)
	gut.p("[PAINT PERF] size independence: 0.5m face %.2f ms/dab, 8m face %.2f ms/dab" % [
			small_mean, large_mean])
	if small_mean < 0.2:
		return # too fast on this machine for a meaningful ratio
	assert_lt(large_mean / small_mean, 4.0,
			"a big face must not cost multiples of a small one per dab (%.2f vs %.2f ms)" % [
					large_mean, small_mean])

## Mean per-dab cost (ms) of a straight stroke across `mesh`'s top face,
## travelling `advance` metres per dab. Both meshes are painted with the same
## brush, so any difference is the mask/geometry, not the parameters.
func _mean_segment_dab_ms(mesh: PBMesh, advance: float) -> float:
	var data := mesh.pb_mesh_data
	PBSplat.ensure_mesh_splat_uv(data)
	var fi := _top_face(data)
	assert_ne(fi, -1, "fixture: cube must have a top face")
	if fi < 0:
		return 0.0
	var face := data.faces[fi]
	var splat_mat := PBSplat.create_splat_material()
	data.set_face_material(face, splat_mat)
	var layer := PBSplat.add_layer(splat_mat, ImageTexture.create_from_image(
			Image.create(16, 16, false, Image.FORMAT_RGBA8)))
	PBSplat.ensure_face_splat_bounds(data, face)
	var b := PBSplat.get_face_planar_bounds(data, face)
	var u_ax: Vector3 = b["u"]
	var v_ax: Vector3 = b["v"]
	var mid_u: float = (b["min_u"] + b["max_u"]) * 0.5
	var mid_v: float = (b["min_v"] + b["max_v"]) * 0.5
	var origin: Vector3 = u_ax * mid_u + v_ax * mid_v
	var plane_y: float = data.positions[face.get_distinct_indexes()[0]].y
	var stroke_ctx := {}
	var prev := Vector3.INF
	var total := 0.0
	var dabs := 24
	for i in range(dabs):
		var pt: Vector3 = origin + u_ax * (float(i) * advance)
		pt.y = plane_y
		var t0 := Time.get_ticks_usec()
		if prev == Vector3.INF:
			PBSplat.paint_face_splat(data, face, splat_mat, layer, pt,
					BRUSH_RADIUS, 0.5, BRUSH_OPACITY, false, stroke_ctx)
		else:
			PBSplat.paint_face_splat_segment(data, face, splat_mat, layer,
					prev, pt, BRUSH_RADIUS, 0.5, BRUSH_OPACITY, false, stroke_ctx)
		total += float(Time.get_ticks_usec() - t0)
		prev = pt
	return total / 1000.0 / float(dabs)
