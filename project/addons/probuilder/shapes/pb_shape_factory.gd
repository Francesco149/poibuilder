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
	match id:

		&"cube":
			return PBShapeGenerators.create_box(size)

		&"stair":
			return PBShapeComplex.create_stairs(size)

		&"curved_stair":
			# Curved stairs with default 180° sweep.
			return PBShapeComplex.create_stairs(size, 8, true)

		&"prism":
			return PBShapeGenerators.create_prism(size)

		&"cylinder":
			var r: float = minf(size.x, size.z) * 0.5
			return PBShapeCylinder.create_cylinder(r, size.y)

		&"plane":
			return PBShapeGenerators.create_plane(size.x, size.z)

		&"door":
			return PBShapeComplex.create_door(size.x, size.y, size.y * 0.75, size.x * 0.2, size.z)

		&"pipe":
			var r: float = minf(size.x, size.z) * 0.5
			var t: float = maxf(0.01, r * 0.25)
			return PBShapeCylinder.create_pipe(r, size.y, t)

		&"cone":
			var r: float = minf(size.x, size.z) * 0.5
			return PBShapeCylinder.create_cone(r, size.y)

		&"sprite":
			return PBShapeGenerators.create_sprite(size.x, size.z)

		&"arch":
			var r: float = size.x * 0.5
			var t: float = maxf(0.01, r * 0.3)
			return PBShapeComplex.create_arch(r, size.z, t)

		&"sphere":
			return PBShapeComplex.create_sphere(size.x * 0.5)

		&"torus":
			var outer_r: float = maxf(0.1, size.x * 0.5)
			var tube_r: float = clampf(outer_r * 0.3, 0.01, outer_r - 0.01)
			return PBShapeComplex.create_torus(outer_r - tube_r, tube_r)

		_:
			push_warning("[PBShapeFactory] Unknown shape ID: %s" % id)
			return null
