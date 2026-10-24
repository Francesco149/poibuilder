## test_pb_scroll_runtime.gd — scrolling textures move in a RUNNING game
## (PBScrollRuntime, v0.9.186). Before, only the editor plugin animated them,
## so a PoiBuilder scene played as the game showed every scrolling face at
## rest. The suite turns the runtime off for everything else
## (tests/hooks/pb_pre_run.gd); this suite turns it on for itself.
extends GutTest

func before_all() -> void:
	PBScrollRuntime.enabled = true

func after_all() -> void:
	PBScrollRuntime.enabled = false

func _scrolling_plane(mat: StandardMaterial3D) -> PBMesh:
	var pb := PBMesh.new()
	pb.pb_mesh_data = PBShapeGenerators.create_plane(1.0, 1.0, 1, 1)
	pb.pb_mesh_data.set_faces_material(pb.pb_mesh_data.faces, mat)
	return pb

func _scrolling(speed: Vector2, base := Vector3.ZERO) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.uv1_offset = base
	PBUv.set_scroll_speed(m, speed)
	return m

func _entry_count_for(mat: Material) -> int:
	var n := 0
	for e in PBScrollRuntime.runner_for(get_tree())._entries:
		if (e[0] as WeakRef).get_ref() == mat:
			n += 1
	return n

func test_a_scrolling_mesh_animates_with_the_editors_formula() -> void:
	var mat := _scrolling(Vector2(0.25, -2.75), Vector3(0.1, 0.2, 0.0))
	add_child_autofree(_scrolling_plane(mat))
	await wait_process_frames(10)
	var runner := PBScrollRuntime.runner_for(get_tree())
	assert_true(runner.is_inside_tree(), "the runner joined the tree")
	assert_eq(_entry_count_for(mat), 1, "the mesh registered its scrolling material")
	# Two reads one frame apart: the offset is base + speed * t (mod 1000), t
	# the runner's own clock — exactly what the editor's preview computes.
	var t: float = runner._time
	var expect := Vector3(fposmod(0.1 + 0.25 * t, 1000.0), fposmod(0.2 - 2.75 * t, 1000.0), 0.0)
	assert_true(mat.uv1_offset.is_equal_approx(expect), "offset %s == base + speed*t %s" % [mat.uv1_offset, expect])
	assert_gt(t, 0.0, "time advanced")
	assert_false(mat.uv1_offset.is_equal_approx(Vector3(0.1, 0.2, 0.0)), "the texture moved")

func test_a_shared_material_animates_once() -> void:
	var mat := _scrolling(Vector2(0, -1.0))
	add_child_autofree(_scrolling_plane(mat))
	add_child_autofree(_scrolling_plane(mat))
	await wait_process_frames(3)
	assert_eq(_entry_count_for(mat), 1)

func test_a_still_mesh_registers_nothing() -> void:
	var still := StandardMaterial3D.new()
	add_child_autofree(_scrolling_plane(still))
	await wait_process_frames(3)
	assert_eq(_entry_count_for(still), 0)
	assert_eq(still.uv1_offset, Vector3.ZERO)

func test_freed_materials_leave_the_runner() -> void:
	var pb := _scrolling_plane(_scrolling(Vector2(1, 0)))
	add_child(pb)
	await wait_process_frames(3)
	var runner := PBScrollRuntime.runner_for(get_tree())
	var before: int = runner._entries.size()
	pb.free()
	await wait_process_frames(3)
	assert_lt(runner._entries.size(), before, "the freed mesh's material was pruned")

func test_disabled_runtime_registers_nothing() -> void:
	PBScrollRuntime.enabled = false
	var mat := _scrolling(Vector2(0, -1.0))
	add_child_autofree(_scrolling_plane(mat))
	await wait_process_frames(3)
	PBScrollRuntime.enabled = true
	assert_eq(_entry_count_for(mat), 0, "the suite's own switch is honoured")
