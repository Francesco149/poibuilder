extends GutTest

## Tests for PBSmoothGroups: setting, clearing, auto-smoothing, and normal preview.

var cube: PBMeshData
var cylinder: PBMeshData

func before_each() -> void:
	cube = PBMeshData.create_cube(1.0)
	cylinder = PBShapeCylinder.create_cylinder(0.5, 1.0, 8, 1, 1)

func test_set_and_clear_smoothing_groups() -> void:
	PBSmoothGroups.set_smoothing_group(cube, PackedInt32Array([0, 1]), 5)
	assert_eq(cube.faces[0].smoothing_group, 5)
	assert_eq(cube.faces[1].smoothing_group, 5)
	assert_eq(cube.faces[2].smoothing_group, 0)

	PBSmoothGroups.clear_smoothing_groups(cube, PackedInt32Array([0]))
	assert_eq(cube.faces[0].smoothing_group, 0)
	assert_eq(cube.faces[1].smoothing_group, 5)

func test_auto_smooth_cube_threshold() -> void:
	# Cube faces meet at 90 degrees.
	# Threshold 45 deg should not group any faces (all remain group 0).
	var groups_45 := PBSmoothGroups.auto_smooth(cube, 45.0)
	assert_eq(groups_45, 0, "45-deg threshold should not smooth any cube faces")
	for f in cube.faces:
		assert_eq(f.smoothing_group, 0)

	# Threshold 95 deg should group all adjacent cube faces into smoothing group 1.
	var groups_95 := PBSmoothGroups.auto_smooth(cube, 95.0)
	assert_eq(groups_95, 1, "95-deg threshold should group all cube faces into 1 smooth group")
	for f in cube.faces:
		assert_eq(f.smoothing_group, 1)

func test_auto_smooth_cylinder() -> void:
	# 8-sided cylinder: side quads meet at 45 degrees, caps meet sides at 90 degrees.
	# Threshold 50 degrees should smooth cylinder side quads into 1 group, leaving caps hard (group 0).
	var num_groups := PBSmoothGroups.auto_smooth(cylinder, 50.0)
	assert_gt(num_groups, 0, "Should generate at least 1 smooth group for cylinder body")

	# Verify side quads are smoothed
	var body_quad_smoothed := false
	for f in cylinder.faces:
		if f.get_distinct_indexes().size() == 4 and f.smoothing_group > 0:
			body_quad_smoothed = true
			break
	assert_true(body_quad_smoothed, "Cylinder body quads should be assigned a smoothing group")

func test_get_normal_preview_lines() -> void:
	var lines := PBSmoothGroups.get_normal_preview_lines(cube, 0.2)
	# Cube has 24 positions -> 24 lines -> 48 points
	assert_eq(lines.size(), cube.positions.size() * 2)
	assert_eq(lines[0], cube.positions[0])
