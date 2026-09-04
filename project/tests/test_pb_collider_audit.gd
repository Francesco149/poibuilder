extends GutTest

## Collider integrity audits + behavioral physics tests.
##
## Written for the v0.9.29 curved-stairs ramp bug: the wedge was wound inward,
## so characters passed through its backfaces and got trapped inside — while
## every existing collider test stayed green (they only asserted "collided").
## These tests instead measure: winding orientation (signed volume + outward
## visibility), shell closure (edge pairing), collider-vs-mesh concordance
## (drop rays onto tread-derived probe points), and character behavior
## (containment outside the shell, unhindered climb along the ramp).

const DEF_SIZE := Vector3(2.0, 2.0, 2.0) # -> stair_w 1.5, r_in 0.5, r_out 2.0, H 2.0, 180 deg, 8 steps
const DEF_RIN := 0.5
const DEF_ROUT := 2.0
const DEF_H := 2.0
const DEF_CIR := PI
const DEF_STEPS := 8

# The generator centers the arc in XZ; for the 180-degree sweep the circle
# center lands at local (0, *, -1.0).
const DEF_CENTER := Vector3(0.0, 0.0, -1.0)


# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

func _mk_default_stairs(id: StringName = &"curved_stair") -> PBMesh:
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBShapeFactory.create_shape(id, DEF_SIZE)
	pb.rebuild()
	return pb

func _collider_faces(pb: PBMesh) -> PackedVector3Array:
	var body := pb.get_collider_body()
	assert_not_null(body, "collider body exists")
	if body == null:
		return PackedVector3Array()
	var col := body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	assert_not_null(col, "collision shape node exists")
	if col == null or col.shape == null:
		return PackedVector3Array()
	return PBColliderAudit.shape_faces(col.shape)

func _concave_shape(pb: PBMesh) -> ConcavePolygonShape3D:
	var body := pb.get_collider_body()
	if body == null:
		return null
	var col := body.get_node_or_null(NodePath("CollisionShape3D")) as CollisionShape3D
	if col == null:
		return null
	return col.shape as ConcavePolygonShape3D

## Horizontal tread faces of a stair mesh, sorted bottom to top, as
## {centroid, y} dicts. Derived from the RENDER mesh so the audit stays
## independent of the collider generator's own math.
func _treads(pb: PBMesh) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var data := pb.pb_mesh_data
	for face in data.faces:
		var idx: PackedInt32Array = face.indexes
		if idx.size() < 3:
			continue
		var p0: Vector3 = data.positions[idx[0]]
		var p1: Vector3 = data.positions[idx[1]]
		var p2: Vector3 = data.positions[idx[2]]
		var n: Vector3 = (p1 - p0).cross(p2 - p0)
		if n.length_squared() < 1e-10:
			continue
		n = n.normalized()
		if absf(n.y) < 0.95:
			continue
		# idx is a TRIANGLE index list (quad = 6 entries with repeats);
		# dedupe so the centroid is not biased along the split diagonal.
		var seen := {}
		var c := Vector3.ZERO
		var n_corners := 0
		for j in idx:
			if seen.has(j):
				continue
			seen[j] = true
			c += data.positions[j]
			n_corners += 1
		out.append({"centroid": c / maxi(1, n_corners), "y": p0.y})
	out.sort_custom(func(a, b): return a["y"] < b["y"])
	return out

func _ray_down(space: PhysicsDirectSpaceState3D, x: float, z: float, y_top := 5.0, y_bottom := -5.0) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, y_top, z), Vector3(x, y_bottom, z))
	q.hit_back_faces = false
	q.hit_from_inside = false
	return space.intersect_ray(q)

func _mk_capsule_character(radius := 0.3, height := 1.6) -> CharacterBody3D:
	var ch := CharacterBody3D.new()
	add_child_autofree(ch)
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = height
	col.shape = cap
	ch.add_child(col)
	return ch

func _mk_ground(top_y: float) -> StaticBody3D:
	var ground := StaticBody3D.new()
	add_child_autofree(ground)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 0.2, 40.0)
	col.shape = box
	ground.add_child(col)
	ground.position = Vector3(0, top_y - 0.1, 0)
	return ground

func _ramp_y(theta: float) -> float:
	return -DEF_H * 0.5 + (theta / DEF_CIR) * DEF_H

## Angle around the (centered) arc; NaN-safe for points outside the sweep.
func _theta_of(pos: Vector3) -> float:
	var rel := Vector3(pos.x, 0, pos.z) - Vector3(DEF_CENTER.x, 0, DEF_CENTER.z)
	return atan2(rel.z, -rel.x)

# ------------------------------------------------------------------------------
# Static audits
# ------------------------------------------------------------------------------

func test_ramp_signed_volume_is_outward():
	var pb := _mk_default_stairs()
	var faces := _collider_faces(pb)
	assert_true(faces.size() > 0, "ramp collider has faces")
	var vol := PBColliderAudit.signed_volume(faces)
	# Analytic wedge volume: annular sector area x mean height, minus a few
	# percent of chord sag (the incline is triangulated, not truly curved).
	var analytic: float = 0.5 * (DEF_ROUT * DEF_ROUT - DEF_RIN * DEF_RIN) * DEF_CIR * (DEF_H / 2.0)
	assert_lt(vol, 0.0, "ramp shell must be wound CW-from-outside (negative RHR volume); got %f" % vol)
	assert_almost_eq(absf(vol), analytic, analytic * 0.15,
		"ramp volume %.3f must sit within 15%% of the analytic wedge %.3f" % [vol, analytic])

func test_ramp_shell_edges_all_paired():
	var pb := _mk_default_stairs()
	var faces := _collider_faces(pb)
	var report := PBColliderAudit.edge_pairing_report(faces)
	assert_eq(report["conflicts"].size(), 0, "no same-direction duplicate edges (winding locally consistent)")
	assert_eq(report["open"].size(), 0, "ramp wedge with sides is a closed shell (no boundary edges)")

func test_ramp_all_faces_front_outward():
	# Math-pure audit: generalized winding numbers classify each face's two
	# sides as inside/outside without a physics server (the old ray battery
	# was blind to inverted walls — self-referential probe origins).
	var pb := _mk_default_stairs()
	var faces := _collider_faces(pb)
	var report := PBColliderAudit.front_exterior_report(faces)
	assert_eq(report["degenerate"].size(), 0, "no degenerate collider triangles")
	if report["failures"].size() > 0:
		var f: Dictionary = report["failures"][0]
		gut.p("first front-exterior failure: tri %d centroid %s normal %s w_front %.3f w_back %.3f" % [
			f["tri"], f["centroid"], f["normal"], f["w_front"], f["w_back"]])
	assert_eq(report["failures"].size(), 0,
		"every collider face's front must face outward (inverted faces trap bodies)")

func test_ramp_drop_rays_hit_expected_heights():
	var pb := _mk_default_stairs()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := pb.get_world_3d().direct_space_state
	var treads := _treads(pb)
	assert_eq(treads.size(), DEF_STEPS, "found one tread per step in the render mesh")
	var step_h := DEF_H / float(DEF_STEPS)
	for i in range(treads.size()):
		var t: Dictionary = treads[i]
		var c: Vector3 = t["centroid"]
		var expected: float = t["y"] - step_h * 0.5 # ramp passes mid-riser under each tread
		var hit := _ray_down(space, c.x, c.z)
		assert_false(hit.is_empty(), "downward ray over tread %d must hit the ramp (no tunnel-through)" % i)
		if not hit.is_empty():
			var y: float = hit["position"].y
			assert_almost_eq(y, expected, 0.08,
				"ramp height under tread %d within chord-sag tolerance (expected %.3f)" % [i, expected])
			var n: Vector3 = hit["normal"]
			assert_gt(n.y, 0.5, "hit face normal points up (front side out)")

func test_accurate_cube_collider_passes_audit():
	# Control case: the audit machinery must approve a known-good collider.
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = PBMeshData.create_cube(2.0)
	pb.rebuild()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var faces := _collider_faces(pb)
	var vol := PBColliderAudit.signed_volume(faces)
	assert_lt(vol, 0.0, "cube trimesh wound outward")
	assert_almost_eq(absf(vol), 8.0, 0.01, "cube volume 2^3")
	var edges := PBColliderAudit.edge_pairing_report(faces)
	assert_eq(edges["conflicts"].size(), 0)
	assert_eq(edges["open"].size(), 0)
	var rep := PBColliderAudit.front_exterior_report(faces)
	assert_eq(rep["failures"].size(), 0, "cube faces' fronts point outward")

# ------------------------------------------------------------------------------
# Freshness rules (stale colliders must never outlive the mesh they copy)
# ------------------------------------------------------------------------------

func test_edited_curved_stairs_fall_back_to_current_mesh():
	var pb := _mk_default_stairs()
	var ramp_before := _collider_faces(pb).size()
	assert_true(ramp_before > 0)
	# Simulate any committed edit: params no longer describe the geometry.
	pb.pb_mesh_data.shape_edited = true
	pb._update_collider()
	var shape := _concave_shape(pb)
	assert_not_null(shape, "edited stairs still get a concave collider")
	var mesh_tris := pb.mesh.get_faces()
	assert_eq(shape.get_faces().size(), mesh_tris.size(),
		"edited stairs collider must be the trimesh of the CURRENT mesh, not the stale ramp")

func test_stale_ramp_faces_meta_is_ignored():
	# Legacy scenes (<= 0.9.28) serialized an inward-wound ramp as resource
	# metadata. The collider must ALWAYS be regenerated from params; this
	# asserts the meta is never consulted.
	var pb := _mk_default_stairs()
	var garbage := PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3.RIGHT])
	pb.pb_mesh_data.set_meta("ramp_faces", garbage) # what an old scene carries
	pb._update_collider()
	var shape := _concave_shape(pb)
	assert_not_null(shape)
	assert_ne(shape.get_faces().size(), garbage.size(), "collider must not consume the stored ramp_faces meta")
	# The regenerated wedge for the default shape: 8 segments * floor/walls.
	# Whatever the exact count, it must be far above a 1-triangle garbage meta.
	assert_gt(shape.get_faces().size(), 30, "collider rebuilt from params")

# ------------------------------------------------------------------------------
# Behavioral: character containment + climbing
# ------------------------------------------------------------------------------

func test_character_cannot_tunnel_into_the_wedge():
	var pb := _mk_default_stairs()
	_mk_ground(-1.0)
	var ch := _mk_capsule_character()
	# Stand outside the outer wall at mid-arc, feet at ground level.
	var th := PI * 0.5
	var start_r := DEF_ROUT + 0.8
	ch.global_position = Vector3(
		DEF_CENTER.x - cos(th) * start_r,
		-1.0 + 0.81, # capsule half height 0.8 + epsilon
		DEF_CENTER.z + sin(th) * start_r)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var sank_frames := 0
	var min_r := 999.0
	var touched_wall := false
	for frame in range(90):
		var pos := ch.global_position
		var rel := Vector3(pos.x, 0, pos.z) - Vector3(DEF_CENTER.x, 0, DEF_CENTER.z)
		var r := rel.length()
		# Walk straight at the staircase.
		var inward := -rel.normalized()
		ch.velocity.x = inward.x * 2.0
		ch.velocity.z = inward.z * 2.0
		ch.velocity.y = 0.0 if ch.is_on_floor() else -9.8
		ch.move_and_slide()
		await get_tree().physics_frame
		if ch.is_on_wall():
			touched_wall = true
		r = rel.length()
		min_r = minf(min_r, r)
		var theta := atan2(rel.z, -rel.x)
		if theta < 0.0:
			theta += TAU
		var foot := ch.global_position.y - 0.8
		if r < DEF_ROUT - 0.05 and theta > 0.02 and theta < DEF_CIR - 0.02:
			var surface := _ramp_y(theta)
			if foot < surface - 0.15:
				sank_frames += 1
	assert_eq(sank_frames, 0, "capsule must NEVER end up below the ramp surface while inside the footprint (trap bug)")
	assert_gt(min_r, DEF_ROUT - 0.4, "capsule is stopped at the outer wall, not driven through it")
	assert_true(touched_wall, "the engine actually registered contact with the wall (test is not vacuous)")

func test_character_walks_up_curved_ramp():
	var pb := _mk_default_stairs()
	_mk_ground(-1.0)
	var ch := _mk_capsule_character()
	ch.floor_max_angle = deg_to_rad(50.0)
	# Start on the ramp just after the bottom edge.
	var th0 := 0.15
	var r0 := (DEF_RIN + DEF_ROUT) * 0.5
	ch.global_position = Vector3(
		DEF_CENTER.x - cos(th0) * r0,
		_ramp_y(th0) + 0.81,
		DEF_CENTER.z + sin(th0) * r0)
	var start_y: float = ch.global_position.y
	await get_tree().physics_frame
	await get_tree().physics_frame

	var sank_frames := 0
	var made_floor := false
	var last_theta := th0
	for frame in range(150):
		var pos := ch.global_position
		var rel := Vector3(pos.x, 0, pos.z) - Vector3(DEF_CENTER.x, 0, DEF_CENTER.z)
		var theta := atan2(rel.z, -rel.x)
		if theta < 0.0:
			theta += TAU # atan2 wraps past pi; the arc lives in [0, cir]
		# Tangent of the ascending path (d/dtheta of (-cos, sin) = (sin, cos)).
		var tangent := Vector3(sin(theta), 0, cos(theta))
		ch.velocity.x = tangent.x * 2.0
		ch.velocity.z = tangent.z * 2.0
		ch.velocity.y = 0.0 if ch.is_on_floor() else -9.8
		ch.move_and_slide()
		await get_tree().physics_frame
		if ch.is_on_floor():
			made_floor = true
			last_theta = theta
			var foot := ch.global_position.y - 0.8
			var surface := _ramp_y(clampf(theta, 0.0, DEF_CIR))
			if rel.length() < DEF_ROUT - 0.05 and rel.length() > DEF_RIN + 0.05 \
					and theta > 0.02 and theta < DEF_CIR - 0.02:
				if foot < surface - 0.15:
					sank_frames += 1
	assert_true(made_floor, "capsule stands on the ramp")
	assert_eq(sank_frames, 0, "capsule never sank below the ramp surface while climbing")
	assert_gt(last_theta, 1.5, "capsule progressed up the arc (theta %.2f); a snag would pin it near the start" % last_theta)
	assert_gt(ch.global_position.y, start_y + 0.8,
		"capsule climbed: y %.2f -> %.2f" % [start_y, ch.global_position.y])

# ------------------------------------------------------------------------------
# Shape variants (pie / flipped / no sides) — each in its own test so the
# physics space holds exactly one staircase (shared spaces contaminate rays).
# ------------------------------------------------------------------------------

func _mk_variant(inner_radius: float, curvature: float, sides: bool) -> PBMesh:
	var data := PBShapeComplex.create_curved_stairs(1.5, 2.0, inner_radius, curvature, DEF_STEPS, sides)
	data.shape_id = &"curved_stair"
	data.shape_params = {
		"stair_width": 1.5,
		"height": 2.0,
		"inner_radius": inner_radius,
		"curvature": curvature,
		"steps": DEF_STEPS,
		"sides": 1.0 if sides else 0.0,
	}
	var pb := PBMesh.new()
	add_child_autofree(pb)
	pb.pb_mesh_data = data
	pb.rebuild()
	return pb

func _audit_variant(label: String, inner_radius: float, curvature: float, sides: bool) -> void:
	var pb := _mk_variant(inner_radius, curvature, sides)
	var faces := _collider_faces(pb)
	assert_true(faces.size() > 0, "%s: ramp faces generated" % label)
	var vol := PBColliderAudit.signed_volume(faces)
	if sides:
		assert_lt(vol, 0.0, "%s: ramp shell wound outward (volume %f)" % [label, vol])
		# Open shells have no meaningful signed volume; visibility audit below
		# still checks every face's front direction.
	var edges := PBColliderAudit.edge_pairing_report(faces)
	assert_eq(edges["conflicts"].size(), 0, "%s: no winding-inconsistent edges" % label)
	if sides:
		assert_eq(edges["open"].size(), 0, "%s: closed shell (pole hole counts: pie ramps get a 5cm inner wall)" % label)
		var rep := PBColliderAudit.front_exterior_report(faces)
		assert_eq(rep["degenerate"].size(), 0, "%s: no degenerate triangles" % label)
		if rep["failures"].size() > 0:
			var f: Dictionary = rep["failures"][0]
			gut.p("%s: front-exterior failure: tri %d centroid %s normal %s w_front %.3f w_back %.3f" % [
				label, f["tri"], f["centroid"], f["normal"], f["w_front"], f["w_back"]])
		assert_eq(rep["failures"].size(), 0, "%s: all faces' fronts point outward" % label)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := pb.get_world_3d().direct_space_state

	# Drop-ray concordance with the render mesh's treads (generator-independent).
	var treads := _treads(pb)
	assert_eq(treads.size(), DEF_STEPS, "%s: tread discovery" % label)
	var step_h := DEF_H / float(DEF_STEPS)
	for i in [0, DEF_STEPS / 2, DEF_STEPS - 1]:
		var t: Dictionary = treads[i]
		var c: Vector3 = t["centroid"]
		var expected: float = t["y"] - step_h * 0.5
		var hit := _ray_down(space, c.x, c.z)
		assert_false(hit.is_empty(), "%s: ray over tread %d hits the ramp" % [label, i])
		if not hit.is_empty():
			assert_almost_eq(hit["position"].y, expected, 0.08,
				"%s: ramp height under tread %d" % [label, i])

func test_ramp_variant_pie():
	await _audit_variant("pie", 0.0, 180.0, true)

func test_ramp_variant_flipped():
	await _audit_variant("flipped", 0.5, -120.0, true)

func test_ramp_variant_no_sides():
	await _audit_variant("no_sides", 0.5, 180.0, false)
