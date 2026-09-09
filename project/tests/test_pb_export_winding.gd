## Test winding of subdivided faces
extends GutTest

func test_subdivided_faces_match_godot_cw_convention():
	var shapes := [
		PBMeshData.create_cube(2.0),
		PBShapeComplex.create_stairs(Vector3(2.5, 3.0, 5.0), 8),
		PBShapeComplex.create_door(4.0, 4.0, 1.0, 2.0, 2.5, true, 8),
		PBShapeGenerators.create_prism(Vector3(2.0, 2.0, 4.0)),
		PBShapeComplex.create_curved_stairs(1.5, 2.0, 0.5, 180.0, 8, true),
		PBShapeCylinder.create_cylinder(0.5, 2.0, 8),
		PBShapeComplex.create_arch(2.0, 2.0, 0.5, 0.5, 8),
	]

	for data in shapes:
		for fi in range(data.faces.size()):
			var face: PBFace = data.faces[fi]
			var frags := PBFaceSubdivider.subdivide_face(data, face, fi, true, 1.0)
			for frag in frags:
				var tri_count := frag.indices.size() / 3
				for t in range(tri_count):
					var i0: int = frag.indices[t * 3]
					var i1: int = frag.indices[t * 3 + 1]
					var i2: int = frag.indices[t * 3 + 2]
					var v0: Vector3 = frag.positions[i0]
					var v1: Vector3 = frag.positions[i1]
					var v2: Vector3 = frag.positions[i2]
					var norm: Vector3 = frag.normals[i0]

					var cross: Vector3 = (v1 - v0).cross(v2 - v0)
					if cross.length_squared() > 0.000000001:
						var dot := norm.dot(cross.normalized())
						assert_lt(dot, 0.0, "Subdivided triangle must be CW-from-outside (dot < 0), but got dot=%.3f on face %d" % [dot, fi])
