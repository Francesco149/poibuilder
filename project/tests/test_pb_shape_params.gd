## Tests for PBShapeParams — per-shape parameter definitions, defaults,
## rebuild dispatch, drag-extent mapping, and facing directions.
##
## Every factory shape must round-trip: defaults → build() → valid mesh data;
## modified values → build() must regenerate with the requested parameters.
extends GutTest

func test_every_shape_declares_params():
	for shape_id in PBShapeFactory.get_shape_ids():
		var defs := PBShapeParams.get_param_defs(shape_id)
		assert_gt(defs.size(), 0, "%s declares at least one parameter" % shape_id)
		for def in defs:
			assert_true(def.has_all(["name", "label", "min", "max", "step", "default", "kind"]),
				"%s param '%s' is fully described" % [shape_id, def.get("name", "?")])
			assert_true(float(def["min"]) <= float(def["default"]),
				"%s param '%s' default is inside its range" % [shape_id, def["name"]])

func test_defaults_match_defs_for_every_shape():
	for shape_id in PBShapeFactory.get_shape_ids():
		var values := PBShapeParams.get_default_values(shape_id)
		for def in PBShapeParams.get_param_defs(shape_id):
			assert_true(values.has(def["name"]),
				"%s defaults cover param '%s'" % [shape_id, def["name"]])

func test_unknown_shape_has_no_params():
	assert_eq(PBShapeParams.get_param_defs(&"nope").size(), 0)
	assert_null(PBShapeParams.build(&"nope"))

func test_every_shape_builds_from_defaults():
	for shape_id in PBShapeFactory.get_shape_ids():
		var data := PBShapeParams.build(shape_id)
		assert_not_null(data, "%s builds from defaults" % shape_id)
		if data != null:
			assert_eq(data.validate(), "", "%s default build validates" % shape_id)

func test_build_with_modified_values_regenerates():
	var values := {"width": 4.0, "height": 2.0, "depth": 3.0}
	var data := PBShapeParams.build(&"cube", values)
	assert_not_null(data)
	# The box spans [-w/2, w/2] etc — check the extents match the params.
	var max_x: float = data.positions[0].x
	var max_y: float = data.positions[0].y
	var max_z: float = data.positions[0].z
	for p in data.positions:
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
		max_z = maxf(max_z, p.z)
	assert_almost_eq(max_x, 2.0, 0.0001, "Width 4 → half-extent 2")
	assert_almost_eq(max_y, 1.0, 0.0001, "Height 2 → half-extent 1")
	assert_almost_eq(max_z, 1.5, 0.0001, "Depth 3 → half-extent 1.5")

func test_stair_steps_param_changes_topology():
	var four := PBShapeParams.build(&"stair", {"steps": 4})
	var ten := PBShapeParams.build(&"stair", {"steps": 10})
	assert_not_null(four)
	assert_not_null(ten)
	assert_gt(ten.faces.size(), four.faces.size(),
		"More steps generate more faces (topology follows the param)")

func test_cylinder_sides_param_changes_topology():
	var hexagon := PBShapeParams.build(&"cylinder", {"sides": 6})
	var dodecagon := PBShapeParams.build(&"cylinder", {"sides": 12})
	assert_gt(dodecagon.faces.size(), hexagon.faces.size(),
		"More sides generate more faces")

func test_partial_values_fill_from_defaults():
	var data := PBShapeParams.build(&"cylinder", {"sides": 16})
	assert_not_null(data)
	assert_eq(data.validate(), "", "Only-override builds stay valid (radius/height default)")

func test_apply_drag_extents_maps_size_dims():
	var values := PBShapeParams.get_default_values(&"cube")
	PBShapeParams.apply_drag_extents(values, 2.0, 3.0, 4.0)
	assert_almost_eq(values["width"], 2.0, 0.0001, "u extent → width")
	assert_almost_eq(values["depth"], 3.0, 0.0001, "v extent → depth")
	assert_almost_eq(values["height"], 4.0, 0.0001, "normal extent → height")

func test_apply_drag_extents_grows_round_shapes_with_height():
	var values := PBShapeParams.get_default_values(&"sphere")
	PBShapeParams.apply_drag_extents(values, 2.0, 2.0, 3.0)
	assert_almost_eq(values["radius"], 1.5, 0.0001,
		"Spheres have no height param — the larger extent (incl. height) drives the radius")

func test_apply_drag_extents_ignores_height_for_flat_shapes():
	var values := PBShapeParams.get_default_values(&"plane")
	PBShapeParams.apply_drag_extents(values, 2.0, 3.0, 9.0)
	assert_almost_eq(values["width"], 2.0, 0.0001)
	assert_almost_eq(values["depth"], 3.0, 0.0001)
	assert_false(values.has("height"), "Planes stay flat — height drag is ignored")

func test_facing_direction_stairs_only():
	assert_eq(PBShapeParams.facing_direction(&"stair"), Vector3(0, 0, 1),
		"Stairs rise toward +Z (their generator stacks steps along +Z)")
	assert_eq(PBShapeParams.facing_direction(&"curved_stair"), Vector3(0, 0, 1))
	assert_eq(PBShapeParams.facing_direction(&"cube"), Vector3.ZERO,
		"Symmetric shapes have no facing arrow")

func test_count_params_are_int_steps():
	for shape_id in PBShapeFactory.get_shape_ids():
		for def in PBShapeParams.get_param_defs(shape_id):
			if def["kind"] == PBShapeParams.KIND_COUNT:
				assert_almost_eq(float(def["step"]), 1.0, 0.0001,
					"%s count param '%s' steps by whole numbers" % [shape_id, def["name"]])
