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

func test_apply_drag_extents_round_shapes_take_height_relatively():
	# Sphere: the base rect sets the footprint radius; the height drag then
	# RESIZES from that baseline (top follows the cursor 1:1) instead of
	# competing with it via max(). NAN height = base drag only.
	var values := PBShapeParams.get_default_values(&"sphere")
	PBShapeParams.apply_drag_extents(values, 2.0, 2.0, NAN)
	assert_almost_eq(values["radius"], 1.0, 0.0001, "Base rect 2×2 → radius 1")
	var base := values.duplicate()
	PBShapeParams.apply_drag_extents(values, 2.0, 2.0, 1.0, base)
	assert_almost_eq(values["radius"], 1.5, 0.0001,
		"Height 1 grows the radius by 0.5 from the base-release value (top +1)")
	PBShapeParams.apply_drag_extents(values, 2.0, 2.0, -0.5, base)
	assert_almost_eq(values["radius"], 0.75, 0.0001,
		"A negative drag shrinks the sphere below its base size (was a dead zone)")

func test_apply_drag_extents_torus_height_drives_the_tube():
	var values := PBShapeParams.get_default_values(&"torus")
	PBShapeParams.apply_drag_extents(values, 3.0, 3.0, NAN)
	assert_almost_eq(values["outer_radius"], 1.5, 0.0001, "Base rect sets the outer radius")
	assert_almost_eq(values["tube_radius"], 0.15, 0.0001, "Base drag leaves the tube alone")
	var base := values.duplicate()
	PBShapeParams.apply_drag_extents(values, 3.0, 3.0, 0.5, base)
	assert_almost_eq(values["outer_radius"], 1.5, 0.0001,
		"The height drag no longer inflates the outer radius")
	assert_almost_eq(values["tube_radius"], 0.4, 0.0001,
		"The height drag thickens the tube (the 3rd dimension follows the mouse)")

func test_apply_drag_extents_arch_maps_rect_footprint():
	# The arch has a real depth: the base rect maps width → span, depth →
	# wall depth, and the height drag grows the arch 1:1 (its top IS the
	# radius) — including shrinking below the base size.
	var values := PBShapeParams.get_default_values(&"arch")
	PBShapeParams.apply_drag_extents(values, 4.0, 0.6, NAN)
	assert_almost_eq(values["radius"], 2.0, 0.0001, "Width → the arch's span (radius)")
	assert_almost_eq(values["depth"], 0.6, 0.0001, "Depth → the arch's wall depth")
	var base := values.duplicate()
	PBShapeParams.apply_drag_extents(values, 4.0, 0.6, 1.5, base)
	assert_almost_eq(values["radius"], 3.5, 0.0001, "Arch top follows the cursor 1:1 (rate 1.0)")
	PBShapeParams.apply_drag_extents(values, 4.0, 0.6, -1.5, base)
	assert_almost_eq(values["radius"], 0.5, 0.0001, "A downward drag shrinks the arch")

func test_apply_drag_extents_height_param_shapes_map_radius_from_base():
	## REGRESSION (v0.9.14): cylinder/pipe/cone have a height param, which
	## used to skip the footprint block entirely — the base drag never
	## touched the radius and it stuck at the default 0.5.
	for shape in [&"cylinder", &"pipe", &"cone"]:
		var values := PBShapeParams.get_default_values(shape)
		PBShapeParams.apply_drag_extents(values, 2.0, 2.4, NAN)
		assert_almost_eq(values["radius"], 1.2, 0.0001,
			"%s: base rect inscribes the radius" % shape)
		assert_almost_eq(values["height"], 1.0, 0.0001,
			"%s: base drag leaves the height alone" % shape)
		# The u/v extents persist through the height phase: the radius keeps
		# tracking the base rect while the height drag drives the height.
		PBShapeParams.apply_drag_extents(values, 2.0, 2.4, 3.0, values.duplicate())
		assert_almost_eq(values["radius"], 1.2, 0.0001,
			"%s: radius survives the height phase" % shape)
		assert_almost_eq(values["height"], 3.0, 0.0001,
			"%s: height drag drives the height" % shape)

func test_height_drag_param_and_surface_pinning():
	assert_eq(PBShapeParams.height_drag_param(&"sphere")["param"], "radius")
	assert_eq(PBShapeParams.height_drag_param(&"torus")["param"], "tube_radius")
	assert_eq(PBShapeParams.height_drag_param(&"arch")["param"], "radius")
	assert_true(PBShapeParams.height_drag_param(&"cube").is_empty(),
		"Shapes with a real height param use the absolute mapping")
	for pinned in [&"sphere", &"torus", &"arch", &"sprite"]:
		assert_true(PBShapeParams.stays_on_surface(pinned),
			"%s never flips below the surface" % pinned)
	assert_false(PBShapeParams.stays_on_surface(&"cube"),
		"Cubes keep ProBuilder's negative-height grow-below behavior")
	assert_true(PBShapeParams.height_drags_offset(&"sprite"))
	assert_false(PBShapeParams.height_drags_offset(&"cube"))

func test_apply_drag_extents_ignores_height_for_flat_shapes():
	var values := PBShapeParams.get_default_values(&"plane")
	PBShapeParams.apply_drag_extents(values, 2.0, 3.0, 9.0)
	assert_almost_eq(values["width"], 2.0, 0.0001)
	assert_almost_eq(values["depth"], 3.0, 0.0001)
	assert_false(values.has("height"), "Planes stay flat — height drag is ignored")

func test_facing_direction_only_for_asymmetric_shapes():
	assert_eq(PBShapeParams.facing_direction(&"stair"), Vector3(0, 0, 1),
		"Stairs rise toward +Z (their generator stacks steps along +Z)")
	assert_eq(PBShapeParams.facing_direction(&"curved_stair"), Vector3(0, 0, 1))
	assert_eq(PBShapeParams.facing_direction(&"door"), Vector3(0, 0, 1),
		"The door's front face is its local +Z")
	for symmetric in [&"cube", &"sphere", &"torus", &"arch", &"cylinder", &"cone",
			&"pipe", &"prism", &"plane", &"sprite"]:
		assert_eq(PBShapeParams.facing_direction(symmetric), Vector3.ZERO,
			"Symmetric shapes have no facing arrow: %s" % symmetric)

func test_count_params_are_int_steps():
	for shape_id in PBShapeFactory.get_shape_ids():
		for def in PBShapeParams.get_param_defs(shape_id):
			if def["kind"] == PBShapeParams.KIND_COUNT:
				assert_almost_eq(float(def["step"]), 1.0, 0.0001,
					"%s count param '%s' steps by whole numbers" % [shape_id, def["name"]])

func test_simple_shapes_skip_the_placement_modal():
	# Size-only shapes finalize at the confirming click (no modal); the
	# modal is for shapes with parameters the drag cannot express.
	for simple in [&"cube", &"prism", &"plane", &"sprite"]:
		assert_false(PBShapeParams.needs_params_modal(simple),
			"%s needs no placement modal" % simple)

func test_parameterized_shapes_open_the_placement_modal():
	for parameterized in [&"stair", &"curved_stair", &"cylinder", &"cone", &"pipe",
			&"door", &"arch", &"sphere", &"torus"]:
		assert_true(PBShapeParams.needs_params_modal(parameterized),
			"%s opens the params modal (steps/sides/thickness/...)" % parameterized)
