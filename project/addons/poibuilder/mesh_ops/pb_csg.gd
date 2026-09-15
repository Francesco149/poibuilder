## PBCsg — Constructive Solid Geometry Boolean operations for PoiBuilder.
##
## Supports Union, Subtract, and Intersect operations between two PBMeshData operands
## using Godot's CSG kernel with clean conversion back to PBMeshData.
@tool
class_name PBCsg
extends RefCounted

enum BooleanOp {
	UNION,
	INTERSECT,
	SUBTRACT,
}

## Performs a CSG Boolean operation between mesh_a and mesh_b (with relative transform applied to b).
## Returns a Dictionary with:
## - "success": bool
## - "mesh_data": PBMeshData (on success)
## - "error": String (on failure)
static func perform_boolean(mesh_a: PBMeshData, mesh_b: PBMeshData, op: BooleanOp,
		rel_transform_b: Transform3D = Transform3D.IDENTITY,
		tree: SceneTree = null) -> Dictionary:
	if mesh_a == null or mesh_a.faces.is_empty():
		return {"success": false, "error": "Mesh A is empty or null"}
	if mesh_b == null or mesh_b.faces.is_empty():
		return {"success": false, "error": "Mesh B is empty or null"}

	# Pre-flight watertightness check
	var boundary_a := PBSelectionOps.select_boundary_edges(mesh_a)
	var boundary_b := PBSelectionOps.select_boundary_edges(mesh_b)
	if not boundary_a.is_empty():
		return {"success": false, "error": "Mesh A is non-manifold (has %d open boundary edges)" % boundary_a.size()}
	if not boundary_b.is_empty():
		return {"success": false, "error": "Mesh B is non-manifold (has %d open boundary edges)" % boundary_b.size()}

	var csg := CSGCombiner3D.new()

	var csg_a := CSGMesh3D.new()
	csg_a.mesh = mesh_a.to_array_mesh()
	csg.add_child(csg_a)

	var csg_b := CSGMesh3D.new()
	csg_b.mesh = mesh_b.to_array_mesh()
	csg_b.transform = rel_transform_b

	match op:
		BooleanOp.UNION:
			csg_b.operation = CSGShape3D.OPERATION_UNION
		BooleanOp.INTERSECT:
			csg_b.operation = CSGShape3D.OPERATION_INTERSECTION
		BooleanOp.SUBTRACT:
			csg_b.operation = CSGShape3D.OPERATION_SUBTRACTION

	csg.add_child(csg_b)

	# CSG shapes require being inside the scene tree to evaluate their brushes
	var cleanup_parent: Node = null
	if tree != null and tree.root != null:
		tree.root.add_child(csg)
		cleanup_parent = tree.root
	elif Engine.get_main_loop() is SceneTree:
		var st := Engine.get_main_loop() as SceneTree
		if st.root != null:
			st.root.add_child(csg)
			cleanup_parent = st.root

	csg._update_shape()
	var baked: ArrayMesh = csg.bake_static_mesh()

	if cleanup_parent != null:
		cleanup_parent.remove_child(csg)
	csg_a.free()
	csg_b.free()
	csg.free()

	if baked == null or baked.get_surface_count() == 0:
		return {"success": false, "error": "CSG operation produced empty geometry"}

	var dummy := MeshInstance3D.new()
	dummy.mesh = baked
	var converted: PBMesh = PBObjectOps.probuilderize(dummy)
	dummy.free()

	if converted == null or converted.pb_mesh_data == null:
		return {"success": false, "error": "Failed to convert CSG result to PBMeshData"}

	var result_data: PBMeshData = converted.pb_mesh_data
	converted.free()
	return {"success": true, "mesh_data": result_data}
