## PBSceneBaker — bakes a PBMesh into ordinary MeshInstance3D geometry that
## stays in the edited scene. PBMapExporter writes a FILE; this writes nodes.
##
## Two bakes:
##   AS_IS  the render mesh exactly as the viewport shows it. Painted faces
##          keep their splat ShaderMaterial, which Godot renders natively, so
##          inside the engine this loses nothing.
##   BAKED  the modern-GLB treatment: painted faces composited down into plain
##          StandardMaterial3D textures, so the result carries no PoiBuilder
##          shader. That bake works entirely in memory (ImageTexture, no file
##          I/O), which is what lets it embed straight into the scene.
@tool
class_name PBSceneBaker
extends RefCounted

enum BakeMode {
	AS_IS = 0,
	BAKED = 1,
}

const BAKE_SUFFIX := "_Baked"

static func mode_label(mode: BakeMode) -> String:
	return "baked textures" if mode == BakeMode.BAKED else "as-is"

## Builds the replacement nodes for `pb` and returns them UNPARENTED, so the
## caller can insert them inside its own undo action. Their transforms are in
## `pb`'s parent space: inserted as siblings of `pb`, the geometry stays put.
static func build_baked_nodes(pb: PBMesh, mode: BakeMode,
		scene_root: Node = null) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if pb == null or pb.pb_mesh_data == null or pb.pb_mesh_data.faces.is_empty():
		return out

	if mode == BakeMode.BAKED:
		out = _build_baked_nodes(pb, scene_root)
	if out.is_empty():
		out = _build_as_is_nodes(pb)

	for i in range(out.size()):
		out[i].name = _bake_name(pb, i, out.size())
		_copy_render_flags(pb, out[i])
		out[i].set_meta("poi_baked_from", String(pb.name))

	# One body for the whole bake, parented to the first node. The BAKED path
	# can split geometry across several meshes to stay under the surface cap,
	# but the collider is built from the source mesh as a whole, so giving each
	# chunk a copy would stack identical collision shapes on top of each other.
	var body := build_collider_body(pb)
	if body != null:
		out[0].add_child(body)
	return out

## Builds the baked object's physics body, or null when the source authored no
## collision. PBMesh generates its own `StaticBody3D` child with `owner = null`,
## so that one is runtime-only and never reaches the saved scene — a baked mesh
## that is meant to stand on its own needs real, owned collision nodes.
static func build_collider_body(pb: PBMesh) -> StaticBody3D:
	if pb == null or pb.collider_type == PBMesh.ColliderType.OFF:
		return null

	var shape := _collider_shape(pb)
	if shape == null:
		return null

	var body := StaticBody3D.new()
	body.name = PBMesh.COLLIDER_BODY_NAME
	var col_shape := CollisionShape3D.new()
	col_shape.name = PBMesh.COLLIDER_SHAPE_NAME
	col_shape.shape = shape
	body.add_child(col_shape)

	# Carry the source body's physics setup when it exists, so a bake does not
	# silently reset layers the user had changed on the PBMesh.
	var src := pb.get_collider_body()
	if src != null:
		body.collision_layer = src.collision_layer
		body.collision_mask = src.collision_mask
		body.physics_material_override = src.physics_material_override
	return body

## The shape to bake. The source's live shape is preferred because it already
## reflects `collider_type` (a stairs RAMP is a cheap convex prism, not a
## trimesh); a DUPLICATE, since PBMesh assigns a brand-new shape on every
## rebuild and a shared resource would also be serialized twice.
static func _collider_shape(pb: PBMesh) -> Shape3D:
	var src := pb.get_collider_body()
	if src != null:
		var src_shape := src.get_node_or_null(NodePath(PBMesh.COLLIDER_SHAPE_NAME)) as CollisionShape3D
		if src_shape != null and src_shape.shape != null:
			return src_shape.shape.duplicate() as Shape3D
	# No live collider (collision enabled but the node was never in a tree):
	# fall back to a trimesh of the WHOLE source mesh, not of one baked chunk.
	var full: Mesh = pb.mesh if pb.mesh != null else pb.pb_mesh_data.to_array_mesh()
	if full != null and full.get_surface_count() > 0:
		return full.create_trimesh_shape()
	return null

static func _build_as_is_nodes(pb: PBMesh) -> Array[MeshInstance3D]:
	# A FRESH compile rather than `pb.mesh`: handing over the live ArrayMesh
	# would make the baked node follow every later PBMesh rebuild, so the
	# "bake" would not actually be frozen.
	var mi := MeshInstance3D.new()
	mi.mesh = pb.pb_mesh_data.to_array_mesh()
	mi.transform = pb.transform
	var out: Array[MeshInstance3D] = []
	out.append(mi)
	return out

static func _build_baked_nodes(pb: PBMesh, scene_root: Node) -> Array[MeshInstance3D]:
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	settings.splat_mode = PBMapExporter.ExportSettings.SplatMode.BAKE
	# An in-scene object is lit by the engine's own lights, so vertex-light
	# baking stays off — the same call the modern GLB preset makes. Colliders
	# are off because the exporter's are hidden `Collider_*` MESHES, a transport
	# detail for the PBM/GLB consumers; a scene bake wants real physics nodes,
	# which build_collider_body() produces.
	settings.bake_lighting = false
	settings.export_colliders = false

	var lights: Array[Light3D] = []
	if scene_root != null:
		lights = PBLightBaker.collect_scene_lights(scene_root)

	# The exporter attaches into a parent and stamps WORLD transforms, because
	# its own export root is flat. Catch the nodes in a throwaway holder and
	# re-base them into the source's parent space.
	var holder := Node3D.new()
	PBMapExporter._export_modern_pb_mesh(pb, holder, lights, null, {}, settings)

	var to_local := Transform3D.IDENTITY
	var parent := pb.get_parent()
	if parent is Node3D and (parent as Node3D).is_inside_tree():
		to_local = (parent as Node3D).global_transform.affine_inverse()

	var out: Array[MeshInstance3D] = []
	for child in holder.get_children():
		var mi := child as MeshInstance3D
		if mi != null:
			out.append(mi)
	for mi in out:
		mi.transform = to_local * mi.transform
		holder.remove_child(mi)
	holder.free()
	return out

static func _copy_render_flags(pb: PBMesh, mi: MeshInstance3D) -> void:
	mi.layers = pb.layers
	mi.cast_shadow = pb.cast_shadow
	mi.gi_mode = pb.gi_mode
	mi.material_override = pb.material_override
	mi.material_overlay = pb.material_overlay

static func _bake_name(pb: PBMesh, index: int, total: int) -> String:
	var base := "%s%s" % [pb.name, BAKE_SUFFIX]
	return base if total <= 1 else "%s_%d" % [base, index + 1]
