extends GutTest

## Verifies PBMesh auto-collider generation, collider_type settings (Off, Accurate, Ramp),
## and runtime physics collision with CharacterBody3D.

func test_cube_auto_collider_accurate_default():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBMeshData.create_cube(2.0)
	pb.rebuild()
	
	assert_eq(pb.collider_type, PBMesh.ColliderType.ACCURATE, "Default collider for cube should be ACCURATE")
	var body := pb.get_collider_body()
	assert_not_null(body, "PBMesh should auto-generate StaticBody3D")
	assert_true(body.is_inside_tree(), "Body should be inside scene tree")
	
	var col_shape := body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	assert_not_null(col_shape, "StaticBody3D should have CollisionShape3D child")
	assert_true(col_shape.shape is ConcavePolygonShape3D, "Accurate collider should use ConcavePolygonShape3D (trimesh)")
	
	# Test physics collision with CharacterBody3D
	var char_body := CharacterBody3D.new()
	add_child_autofree(char_body)
	var char_col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	char_col.shape = sphere
	char_body.add_child(char_col)
	
	# Cube top is at y = 1.0. Position sphere bottom slightly above cube top
	char_body.position = Vector3(0, 1.55, 0)
	char_body.velocity = Vector3(0, -10.0, 0)
	
	await get_tree().physics_frame
	await get_tree().physics_frame
	
	char_body.move_and_slide()
	
	assert_gt(char_body.get_slide_collision_count(), 0, "Character should collide with auto-generated collider")
	if char_body.get_slide_collision_count() > 0:
		var collision := char_body.get_slide_collision(0)
		assert_eq(collision.get_collider(), body, "Collider should be PBMesh's StaticBody3D")
		assert_almost_eq(char_body.position.y, 1.5, 0.05, "Character should rest on top of cube")

func test_collider_type_off():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBMeshData.create_cube(2.0)
	pb.rebuild()
	
	assert_not_null(pb.get_collider_body(), "Body should exist initially")
	
	pb.collider_type = PBMesh.ColliderType.OFF
	assert_null(pb.get_collider_body(), "StaticBody3D should be freed when collider_type is OFF")
	
	# Character should fall through without collision
	var char_body := CharacterBody3D.new()
	add_child_autofree(char_body)
	var char_col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	char_col.shape = sphere
	char_body.add_child(char_col)
	
	char_body.position = Vector3(0, 1.55, 0)
	char_body.velocity = Vector3(0, -10.0, 0)
	
	await get_tree().physics_frame
	await get_tree().physics_frame
	
	char_body.move_and_slide()
	assert_eq(char_body.get_slide_collision_count(), 0, "Character should not collide when collider is OFF")

func test_stairs_default_ramp_collider():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBShapeFactory.create_shape(&"stair", Vector3(2.0, 2.0, 4.0))
	pb.rebuild()
	
	assert_true(pb.is_stairs(), "Mesh should be recognized as stairs")
	assert_eq(pb.collider_type, PBMesh.ColliderType.RAMP, "Default collider for stairs must be RAMP")
	
	var body := pb.get_collider_body()
	assert_not_null(body, "Stairs should have StaticBody3D")
	
	var col_shape := body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	assert_not_null(col_shape, "Body should have CollisionShape3D")
	assert_true(col_shape.shape is ConvexPolygonShape3D, "Straight stairs ramp should use ConvexPolygonShape3D")
	assert_eq((col_shape.shape as ConvexPolygonShape3D).points.size(), 6, "Straight stairs ramp should be 6-vertex triangular prism flush with ground")
	# Test character collision with ramp
	var char_body := CharacterBody3D.new()
	add_child_autofree(char_body)
	var char_col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.4
	char_col.shape = sphere
	char_body.add_child(char_col)
	
	# Stairs are centered at origin: y from -1 to +1, z from -2 to +2.
	# Position character right on the ramp slope and test collision
	char_body.position = Vector3(0, 0.45, 0)
	char_body.velocity = Vector3(0, -5.0, 0)
	
	await get_tree().physics_frame
	await get_tree().physics_frame
	
	char_body.move_and_slide()
	assert_gt(char_body.get_slide_collision_count(), 0, "Character should collide with stairs ramp")

func test_stairs_switch_to_accurate_collider():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBShapeFactory.create_shape(&"stair")
	pb.rebuild()
	
	assert_eq(pb.collider_type, PBMesh.ColliderType.RAMP)
	
	# Switch to accurate
	pb.collider_type = PBMesh.ColliderType.ACCURATE
	var body := pb.get_collider_body()
	var col_shape := body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	assert_true(col_shape.shape is ConcavePolygonShape3D, "Accurate mode on stairs should use ConcavePolygonShape3D")

func test_curved_stairs_default_ramp_collider():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBShapeFactory.create_shape(&"curved_stair")
	pb.rebuild()
	
	assert_true(pb.is_stairs(), "Curved stairs should be recognized as stairs")
	assert_eq(pb.collider_type, PBMesh.ColliderType.RAMP, "Default collider for curved stairs must be RAMP")
	
	var body := pb.get_collider_body()
	assert_not_null(body, "Curved stairs should have StaticBody3D")
	
	var col_shape := body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	assert_not_null(col_shape, "Body should have CollisionShape3D")
	assert_true(col_shape.shape is ConcavePolygonShape3D, "Curved stairs ramp should use ConcavePolygonShape3D")
	
	# Test character collision with curved stairs ramp
	var char_body := CharacterBody3D.new()
	add_child_autofree(char_body)
	var char_col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.4
	char_col.shape = sphere
	char_body.add_child(char_col)
	
	char_body.position = Vector3(0, 0.45, 0)
	char_body.velocity = Vector3(0, -5.0, 0)
	
	await get_tree().physics_frame
	await get_tree().physics_frame
	
	char_body.move_and_slide()
	assert_gt(char_body.get_slide_collision_count(), 0, "Character should collide with curved stairs ramp")

func test_non_stairs_ramp_fallback():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBMeshData.create_cube(1.0)
	pb.rebuild()
	
	# Attempt to set RAMP on a cube
	pb.collider_type = PBMesh.ColliderType.RAMP
	assert_eq(pb.collider_type, PBMesh.ColliderType.ACCURATE, "Setting RAMP on non-stairs should fall back to ACCURATE")

func test_character_walks_up_stairs_ramp():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	# Stairs 2m wide, 2m high, 4m deep. Origin is center:
	# Y from -1.0 to +1.0. Z from -2.0 to +2.0.
	pb.pb_mesh_data = PBShapeFactory.create_shape(&"stair", Vector3(2.0, 2.0, 4.0))
	pb.rebuild()

	var char_body := CharacterBody3D.new()
	add_child_autofree(char_body)
	var char_col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.6
	char_col.shape = capsule
	char_body.add_child(char_col)
	char_body.floor_snap_length = 0.4
	# Capsule height is 1.6, so center is 0.8 above feet.
	# Ramp top surface at z = -1.5 is at y ~ -0.45.
	# Placing center at y = 0.5 puts feet at y = -0.3, safely above the ramp surface.
	char_body.position = Vector3(0, 0.5, -1.5)
	var initial_y: float = char_body.position.y

	await get_tree().physics_frame
	await get_tree().physics_frame

	# Step forward and down (walking along the ramp with gravity)
	# Standard character controller movement: apply gravity when in air, walk forward
	for frame in range(40):
		if not char_body.is_on_floor():
			char_body.velocity.y = -9.8
		else:
			char_body.velocity.y = 0.0
		char_body.velocity.z = 4.0
		char_body.move_and_slide()
		await get_tree().physics_frame

	# Character should have moved forward (+Z) and climbed upward (+Y) smoothly
	assert_gt(char_body.position.z, 0.0, "Character should have moved forward along +Z past center")
	assert_gt(char_body.position.y, 0.5, "Character should have ascended up the stairs ramp")

func test_validate_property_options():
	var pb_cube := PBMesh.new()
	add_child_autofree(pb_cube)
	pb_cube.pb_mesh_data = PBMeshData.create_cube(1.0)
	var prop_cube := {"name": "collider_type", "hint": 0, "hint_string": ""}
	pb_cube._validate_property(prop_cube)
	assert_eq(prop_cube["hint_string"], "Off:0,Geometry Accurate:1", "Cube should not have Ramp option")

	var pb_stair := PBMesh.new()
	add_child_autofree(pb_stair)
	pb_stair.pb_mesh_data = PBShapeFactory.create_shape(&"stair")
	var prop_stair := {"name": "collider_type", "hint": 0, "hint_string": ""}
	pb_stair._validate_property(prop_stair)
	assert_eq(prop_stair["hint_string"], "Off:0,Geometry Accurate:1,Ramp:2", "Stairs should have Ramp option")

	var pb_curved := PBMesh.new()
	add_child_autofree(pb_curved)
	pb_curved.pb_mesh_data = PBShapeFactory.create_shape(&"curved_stair")
	var prop_curved := {"name": "collider_type", "hint": 0, "hint_string": ""}
	pb_curved._validate_property(prop_curved)
	assert_eq(prop_curved["hint_string"], "Off:0,Geometry Accurate:1,Ramp:2", "Curved stairs should have Ramp option")

func test_mesh_rebuild_updates_collider():
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBMeshData.create_cube(1.0)
	pb.rebuild()

	var body := pb.get_collider_body()
	var col_shape := body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	var shape1: ConcavePolygonShape3D = col_shape.shape
	assert_not_null(shape1)
	var face_count1 := shape1.get_faces().size()

	# Now replace with larger cylinder and rebuild
	pb.pb_mesh_data = PBShapeFactory.create_shape(&"cylinder")
	pb.rebuild()

	var shape2: ConcavePolygonShape3D = col_shape.shape
	assert_not_null(shape2)
	var face_count2 := shape2.get_faces().size()
	assert_ne(face_count1, face_count2, "Rebuilding mesh should update collider faces")

