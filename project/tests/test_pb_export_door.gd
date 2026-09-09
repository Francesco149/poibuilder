## Test door subdivision and winding
extends GutTest

func test_door_all_faces_subdivide_and_face_outward():
	var door := PBShapeComplex.create_door(4.0, 4.0, 1.0, 2.0, 2.5, true, 8)
	assert_gt(door.faces.size(), 8)

	for fi in range(door.faces.size()):
		var face: PBFace = door.faces[fi]
		var n := PBMath.normal_from_positions(door.positions, face.get_indexes())
		assert_gt(n.length_squared(), 0.001, "Face %d must have valid normal" % fi)

		var frags := PBFaceSubdivider.subdivide_face(door, face, fi, true, 1.0)
		assert_gt(frags.size(), 0, "Face %d must subdivide into at least 1 fragment" % fi)

		var tri_count := 0
		for frag in frags:
			tri_count += frag.indices.size() / 3
			for t in range(frag.indices.size() / 3):
				var v0: Vector3 = frag.positions[frag.indices[t * 3]]
				var v1: Vector3 = frag.positions[frag.indices[t * 3 + 1]]
				var v2: Vector3 = frag.positions[frag.indices[t * 3 + 2]]
				var cross := (v1 - v0).cross(v2 - v0)
				if cross.length_squared() > 0.000000001:
					var dot := frag.normals[0].dot(cross.normalized())
					assert_lt(dot, 0.0, "Door face %d tri %d must be CW-from-outside, got %.3f" % [fi, t, dot])

		print("Door face %d (normal %s): %d triangles across %d frags" % [fi, n, tri_count, frags.size()])
