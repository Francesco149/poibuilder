## Test: PBObjectState — Lit / cast-shadow decisions behind the toolbar
## toggles, and PBMaterialDock.shape_palette_ids (the Shapes tab palette).
extends GutTest

func _make_mesh(shared_mat: Material = null) -> PBMesh:
	var node := PBMesh.new()
	node.name = "TestMesh"
	node.pb_mesh_data = PBShapeGenerators.create_box(Vector3(1, 1, 1))
	var mat: Material = shared_mat if shared_mat != null else PBMeshData.get_default_material()
	node.pb_mesh_data.materials = [mat]
	add_child_autofree(node)
	return node

func test_lit_and_unlit_roundtrip_on_pbmesh():
	var node := _make_mesh()
	assert_true(PBObjectState.is_node_lit(node), "A default-material mesh starts lit")
	var rec := PBObjectState.set_node_lit(node, false)
	assert_eq(rec.get("kind"), "pbmesh", "Un-litting a lit mesh produces a pbmesh record")
	assert_true(PBObjectState.is_node_lit(node) == false, "After the change the mesh is unlit")
	var sm: StandardMaterial3D = node.pb_mesh_data.materials[0]
	assert_eq(sm.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "Material shading is UNSHADED")
	assert_eq(node.pb_mesh_data.materials.size(), 1, "Mesh keeps exactly one material")
	# Already unlit: a second call changes nothing (empty record)
	assert_true(PBObjectState.set_node_lit(node, false).is_empty(), "No-op returns empty record")
	# Back to lit
	var rec2 := PBObjectState.set_node_lit(node, true)
	assert_eq(rec2.get("kind"), "pbmesh")
	assert_eq((node.pb_mesh_data.materials[0] as StandardMaterial3D).shading_mode,
		BaseMaterial3D.SHADING_MODE_PER_PIXEL, "Lit target is per-pixel shading")

func test_unlit_does_not_mutate_shared_material():
	# Two meshes sharing ONE material resource: toggling one must leave the
	# other's material untouched (the shared .tres is duplicated, not edited).
	var shared := StandardMaterial3D.new()
	shared.albedo_color = Color(1, 0, 0)
	var a := _make_mesh(shared)
	var b := _make_mesh(shared)
	PBObjectState.set_node_lit(a, false)
	assert_eq((a.pb_mesh_data.materials[0] as StandardMaterial3D).shading_mode,
		BaseMaterial3D.SHADING_MODE_UNSHADED, "Mesh A went unlit")
	assert_eq((b.pb_mesh_data.materials[0] as StandardMaterial3D).shading_mode,
		BaseMaterial3D.SHADING_MODE_PER_PIXEL, "Mesh B's shared material stays lit")
	assert_true(a.pb_mesh_data.materials[0] != b.pb_mesh_data.materials[0],
		"The duplicated material is a different resource")
	assert_true(shared.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED,
		"The shared source material itself was never mutated")

func test_shadow_toggle_states():
	var node := _make_mesh()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var rec := PBObjectState.set_node_shadow(node, false)
	assert_eq(rec.get("kind"), "shadow")
	assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	assert_false(PBObjectState.is_node_shadow_casting(node))
	assert_true(PBObjectState.set_node_shadow(node, false).is_empty(), "No-op when already off")
	PBObjectState.set_node_shadow(node, true)
	assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)

func test_shadow_toggle_keeps_double_sided():
	var node := _make_mesh()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	var rec := PBObjectState.set_node_shadow(node, true)
	assert_true(rec.is_empty(), "DOUBLE_SIDED already casts — no change")
	PBObjectState.set_node_shadow(node, false)
	assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	PBObjectState.set_node_shadow(node, true)
	assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"Re-enabling a disabled sprite uses ON, not DOUBLE_SIDED")

func test_combined_states_and_sync():
	var lit_mesh := _make_mesh()
	var unlit_mesh := _make_mesh()
	PBObjectState.set_node_lit(unlit_mesh, false)
	var nodes: Array[GeometryInstance3D] = [lit_mesh, unlit_mesh]
	assert_eq(PBObjectState.lit_state(nodes), PBObjectState.MIXED,
		"One lit + one unlit = mixed")
	# "Checking" the mixed toggle synchronizes EVERY selected object.
	for node in nodes:
		PBObjectState.set_node_lit(node, true)
	assert_eq(PBObjectState.lit_state(nodes), 1, "Synchronized selection is all lit")
	for node in nodes:
		PBObjectState.set_node_lit(node, false)
	assert_eq(PBObjectState.lit_state(nodes), 0, "All unlit = 0")
	# Shadows: mixed casting state across a selection
	unlit_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lit_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	assert_eq(PBObjectState.shadow_state(nodes), PBObjectState.MIXED)
	unlit_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lit_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	assert_eq(PBObjectState.shadow_state(nodes), 0)

func test_record_replay_restores_previous_state():
	var node := _make_mesh()
	var rec := PBObjectState.set_node_lit(node, false)
	# Simulate undo: restore the old material array.
	var typed: Array[Material] = []
	for m in rec["old_materials"]:
		typed.append(m)
	node.pb_mesh_data.materials = typed
	node.rebuild()
	assert_true(PBObjectState.is_node_lit(node), "Restoring old_materials re-lights the mesh")

func test_shape_palette_excludes_sprite_and_ngon():
	var ids := PBMaterialDock.shape_palette_ids()
	assert_true(ids.has(&"cube"), "Cube is in the palette")
	assert_true(ids.has(&"trim"), "Trim is in the palette")
	assert_false(ids.has(&"sprite"), "Sprite has its own tab, not the Shapes palette")
	assert_false(ids.has(&"ngon"), "N-Gon is the draw tool, not a drag primitive")
	# Every palette entry must build (preview + creation depend on it).
	for id in ids:
		assert_not_null(PBShapeFactory.create_shape(id, Vector3.ONE),
			"Palette shape '%s' must generate preview geometry" % id)
	# Previews use distinct bright colors per card.
	var count := ids.size()
	var hues: Array[float] = []
	for i in range(count):
		var c := PBMaterialDock._shape_palette_color(i, count)
		assert_true(c.s >= 0.8 and c.v >= 0.99,
			"Palette color %d must be bright and saturated" % i)
		hues.append(c.h)
	for i in range(count):
		for j in range(i + 1, count):
			var dh: float = absf(hues[i] - hues[j])
			dh = minf(dh, 1.0 - dh)
			assert_gt(dh, 0.01, "Palette colors %d and %d must be visually distinct" % [i, j])

func test_actions_register_lit_and_shadow_hotkeys():
	# The toggles are bindable in Editor Settings → Shortcuts (default unbound).
	assert_true(PBActions.ACTIONS.has("obj_toggle_lit"), "obj_toggle_lit is a registered action")
	assert_true(PBActions.ACTIONS.has("obj_toggle_shadows"), "obj_toggle_shadows is a registered action")
	assert_eq(PBActions.ACTIONS["obj_toggle_lit"]["label"], "Object: Toggle Lit (Selected)")
