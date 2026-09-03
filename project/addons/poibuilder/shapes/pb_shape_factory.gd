## PBShapeFactory — Central factory: maps string shape IDs to PBMeshData generators.
##
## Mirrors ProBuilder's ShapeType enum and ShapeGenerator.CreateShape() dispatch.
@tool
class_name PBShapeFactory
extends RefCounted

## Shape type identifiers matching ProBuilder's ShapeType enum.
enum ShapeType {
	CUBE,
	STAIR,
	CURVED_STAIR,
	PRISM,
	CYLINDER,
	PLANE,
	DOOR,
	PIPE,
	CONE,
	SPRITE,
	ARCH,
	SPHERE,
	TORUS,
}

## All valid shape type string keys, ordered to match ShapeType enum.
const TYPE_NAMES: Array[StringName] = [
	&"cube",
	&"stair",
	&"curved_stair",
	&"prism",
	&"cylinder",
	&"plane",
	&"door",
	&"pipe",
	&"cone",
	&"sprite",
	&"arch",
	&"sphere",
	&"torus",
]

## Returns all available shape type identifiers.
static func get_shape_ids() -> Array[StringName]:
	return TYPE_NAMES.duplicate()

## Returns true if id resolves to a known shape generator.
static func is_valid_shape(id: StringName) -> bool:
	return id.to_lower() in TYPE_NAMES

## Creates a shape by string ID with the given overall size.
## Returns a valid PBMeshData, or null on unknown ID.
static func create_shape(id: StringName, size: Vector3 = Vector3.ONE) -> PBMeshData:
	var data: PBMeshData = null
	match id:
		&"cube":
			data = PBShapeGenerators.create_box(size)

		&"stair":
			data = PBShapeComplex.create_stairs(size)

		&"curved_stair":
			# Curved stairs with default 180° sweep.
			var max_w: float = minf(size.x, size.z)
			var inner_r: float = max_w * 0.25
			var stair_w: float = max_w * 0.75
			data = PBShapeComplex.create_curved_stairs(stair_w, size.y, inner_r, 180.0, 8, true)
			data.shape_params = {
				"stair_width": stair_w,
				"height": size.y,
				"inner_radius": inner_r,
				"curvature": 180.0,
				"steps": 8,
				"sides": 1.0,
			}

		&"prism":
			data = PBShapeGenerators.create_prism(size)

		&"cylinder":
			var r: float = minf(size.x, size.z) * 0.5
			data = PBShapeCylinder.create_cylinder(r, size.y)

		&"plane":
			data = PBShapeGenerators.create_plane(size.x, size.z)

		&"door":
			data = PBShapeComplex.create_door(size.x, size.y, size.y * 0.75, size.x * 0.2, size.z)

		&"pipe":
			var r: float = minf(size.x, size.z) * 0.5
			var t: float = maxf(0.01, r * 0.25)
			data = PBShapeCylinder.create_pipe(r, size.y, t)

		&"cone":
			var r: float = minf(size.x, size.z) * 0.5
			data = PBShapeCylinder.create_cone(r, size.y)

		&"sprite":
			data = PBShapeGenerators.create_sprite(size.x, size.z)

		&"arch":
			var r: float = size.x * 0.5
			var t: float = maxf(0.01, r * 0.3)
			data = PBShapeComplex.create_arch(r, size.z, t)

		&"sphere":
			data = PBShapeComplex.create_sphere(size.x * 0.5)

		&"torus":
			var outer_r: float = maxf(0.1, size.x * 0.5)
			var tube_r: float = clampf(outer_r * 0.3, 0.01, outer_r - 0.01)
			data = PBShapeComplex.create_torus(outer_r - tube_r, tube_r)

		_:
			push_warning("[PBShapeFactory] Unknown shape ID: %s" % id)
			return null
	if data != null:
		data.shape_id = id
	return data
