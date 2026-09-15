extends GutTest

## Tests for PBCsg Boolean operations.

var box_a: PBMeshData
var box_b: PBMeshData

func before_each() -> void:
	box_a = PBMeshData.create_cube(2.0)
	box_b = PBMeshData.create_cube(2.0)

func test_csg_subtract_boxes() -> void:
	var offset := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))
	var res := PBCsg.perform_boolean(box_a, box_b, PBCsg.BooleanOp.SUBTRACT, offset, get_tree())
	assert_true(res["success"], "CSG subtraction should succeed: %s" % res.get("error", ""))
	var md: PBMeshData = res.get("mesh_data", null)
	assert_not_null(md, "Result mesh data should not be null")
	assert_gt(md.faces.size(), 0, "Result mesh should have faces")

	# Watertight check on output
	var boundaries := PBSelectionOps.select_boundary_edges(md)
	assert_eq(boundaries.size(), 0, "CSG boolean output should be watertight/manifold")

func test_csg_union_boxes() -> void:
	var offset := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))
	var res := PBCsg.perform_boolean(box_a, box_b, PBCsg.BooleanOp.UNION, offset, get_tree())
	assert_true(res["success"], "CSG union should succeed: %s" % res.get("error", ""))
	var md: PBMeshData = res.get("mesh_data", null)
	assert_not_null(md, "Result mesh data should not be null")
	assert_gt(md.faces.size(), 0, "Result mesh should have faces")

	var boundaries := PBSelectionOps.select_boundary_edges(md)
	assert_eq(boundaries.size(), 0, "CSG union output should be watertight")

func test_csg_intersect_boxes() -> void:
	var offset := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))
	var res := PBCsg.perform_boolean(box_a, box_b, PBCsg.BooleanOp.INTERSECT, offset, get_tree())
	assert_true(res["success"], "CSG intersection should succeed: %s" % res.get("error", ""))
	var md: PBMeshData = res.get("mesh_data", null)
	assert_not_null(md, "Result mesh data should not be null")
	assert_gt(md.faces.size(), 0, "Result mesh should have faces")

	var boundaries := PBSelectionOps.select_boundary_edges(md)
	assert_eq(boundaries.size(), 0, "CSG intersection output should be watertight")

func test_csg_preflight_non_manifold_rejection() -> void:
	# Delete face 0 on box A to make it non-manifold
	PBMeshOps.delete_faces(box_a, PackedInt32Array([0]))
	var offset := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))
	var res := PBCsg.perform_boolean(box_a, box_b, PBCsg.BooleanOp.SUBTRACT, offset, get_tree())
	assert_false(res["success"], "CSG should reject non-manifold mesh with boundary edges")
	assert_true(res["error"].contains("non-manifold"), "Error message should mention non-manifold")
