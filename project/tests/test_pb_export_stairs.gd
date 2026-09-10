## Test stairs subdivision and winding
extends GutTest

func test_stairs_both_sides_subdivide_and_face_outward():
	var stairs := PBShapeComplex.create_stairs(Vector3(2.5, 3.0, 5.0), 8)
	assert_gt(stairs.faces.size(), 16)

	var left_face: PBFace = null
	var right_face: PBFace = null
	var left_idx := -1
	var right_idx := -1

	for fi in range(stairs.faces.size()):
		var f: PBFace = stairs.faces[fi]
		var n := PBMath.normal_from_positions(stairs.positions, f.get_indexes())
		if n.dot(Vector3.LEFT) > 0.9:
			left_face = f
			left_idx = fi
		elif n.dot(Vector3.RIGHT) > 0.9:
			right_face = f
			right_idx = fi

	assert_not_null(left_face, "Stairs must have a left side wall (-X)")
	assert_not_null(right_face, "Stairs must have a right side wall (+X)")

	var left_frags := PBFaceSubdivider.subdivide_face(stairs, left_face, left_idx, true, 1.0)
	var right_frags := PBFaceSubdivider.subdivide_face(stairs, right_face, right_idx, true, 1.0)

	assert_gt(left_frags.size(), 0, "Left side wall must subdivide into fragments")
	assert_gt(right_frags.size(), 0, "Right side wall must subdivide into fragments")

	var left_tris := 0
	for frag in left_frags:
		left_tris += frag.indices.size() / 3
		for t in range(frag.indices.size() / 3):
			var v0: Vector3 = frag.positions[frag.indices[t * 3]]
			var v1: Vector3 = frag.positions[frag.indices[t * 3 + 1]]
			var v2: Vector3 = frag.positions[frag.indices[t * 3 + 2]]
			var cross := (v1 - v0).cross(v2 - v0)
			print("DEBUG left tri %d: v0=%s v1=%s v2=%s cross_len=%.8f" % [t, v0, v1, v2, cross.length()])
			if cross.length_squared() > 0.000000001:
				var dot := frag.normals[0].dot(cross.normalized())
				assert_lt(dot, 0.0, "Left side triangle must be CW-from-outside, got %.3f" % dot)
			else:
				print("DEGENERATE TRIANGLE DETECTED on left side: v0=%s v1=%s v2=%s" % [v0, v1, v2])

	var right_tris := 0
	for frag in right_frags:
		right_tris += frag.indices.size() / 3
		for t in range(frag.indices.size() / 3):
			var v0: Vector3 = frag.positions[frag.indices[t * 3]]
			var v1: Vector3 = frag.positions[frag.indices[t * 3 + 1]]
			var v2: Vector3 = frag.positions[frag.indices[t * 3 + 2]]
			var cross := (v1 - v0).cross(v2 - v0)
			if cross.length_squared() > 0.000000001:
				var dot := frag.normals[0].dot(cross.normalized())
				assert_lt(dot, 0.0, "Right side triangle must be CW-from-outside, got %.3f" % dot)
			else:
				print("DEGENERATE TRIANGLE on right side: v0=%s v1=%s v2=%s" % [v0, v1, v2])
	print("Left side tris: ", left_tris, " Right side tris: ", right_tris)

func test_stairs_treads_and_risers_subdivide():
	var stairs := PBShapeComplex.create_stairs(Vector3(2.5, 3.0, 5.0), 8)
	# 8 steps = 8 risers + 8 treads = 16 step faces + 2 side walls + 1 back wall = 19 faces
	assert_eq(stairs.faces.size(), 19)

	for fi in range(16):
		var face: PBFace = stairs.faces[fi]
		var n := PBMath.normal_from_positions(stairs.positions, face.get_indexes())
		var frags := PBFaceSubdivider.subdivide_face(stairs, face, fi, true, 1.0)
		print("Stairs face %d (n=%s) frags: %d" % [fi, n, frags.size()])
		assert_gt(frags.size(), 0, "Stairs step face %d must produce at least 1 fragment" % fi)
		var total_tris := 0
		for frag in frags:
			total_tris += frag.indices.size() / 3
		assert_gt(total_tris, 0, "Stairs step face %d must have triangles" % fi)

func test_showcase_stairs_in_glb():
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var glb_path := "res://exports/showcase_retro_baked.glb" if FileAccess.file_exists("res://exports/showcase_retro_baked.glb") else "res://test_scenes/showcase_retro_baked.glb"
	var err := doc.append_from_file(glb_path, state)
	var scene := doc.generate_scene(state)
	assert_not_null(scene)
	autofree(scene)

	var stairs_mi := scene.get_node_or_null("TerraceStairs") as MeshInstance3D
	assert_not_null(stairs_mi, "TerraceStairs must exist in exported GLB")
	print("TerraceStairs transform: ", stairs_mi.transform)
	print("TerraceStairs surface count: ", stairs_mi.mesh.get_surface_count())

	for s in range(stairs_mi.mesh.get_surface_count()):
		var mat = stairs_mi.mesh.surface_get_material(s)
		var arrays = stairs_mi.mesh.surface_get_arrays(s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var min_p := Vector3(INF, INF, INF)
		var max_p := Vector3(-INF, -INF, -INF)
		for p in pos:
			min_p.x = minf(min_p.x, p.x); max_p.x = maxf(max_p.x, p.x)
			min_p.y = minf(min_p.y, p.y); max_p.y = maxf(max_p.y, p.y)
			min_p.z = minf(min_p.z, p.z); max_p.z = maxf(max_p.z, p.z)
		print("   Surf %d: mat=%s verts=%d tris=%d aabb=[min=%s max=%s]" % [s, mat.resource_name if mat else "null", pos.size(), idx.size() / 3, min_p, max_p])
		var cw_count := 0
		var ccw_count := 0
		var degen_count := 0
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for t in range(idx.size() / 3):
			var i0 := idx[t * 3]
			var i1 := idx[t * 3 + 1]
			var i2 := idx[t * 3 + 2]
			var v0 := pos[i0]
			var v1 := pos[i1]
			var v2 := pos[i2]
			var n := norms[i0]
			var cross := (v1 - v0).cross(v2 - v0)
			if cross.length_squared() < 0.00000001:
				degen_count += 1
			else:
				var dot := n.dot(cross.normalized())
				if dot < 0.0:
					cw_count += 1
				else:
					ccw_count += 1
		print("   Surf %d winding stats: CW(visible)=%d CCW(culled)=%d Degen=%d" % [s, cw_count, ccw_count, degen_count])
