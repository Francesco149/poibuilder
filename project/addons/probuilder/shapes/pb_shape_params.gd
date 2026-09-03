## PBShapeParams — Per-shape parameter definitions, defaults, and rebuild.
##
## Every factory shape declares the parameters its generator accepts (size
## dims, integer counts, plain values). The creation flow and the Edit Params
## modal are generic over these definitions: the overlay renders one control
## per def, and build() regenerates the PBMeshData from a values dictionary.
##
## Headless-testable (no editor classes).
@tool
class_name PBShapeParams
extends RefCounted

const KIND_SIZE := "size"    ## width/height/depth — mapped onto the creation drag
const KIND_COUNT := "count"  ## integer parameter (SpinBox step 1)
const KIND_VALUE := "value"  ## plain float parameter
const KIND_BOOL := "bool"    ## toggle (CheckBox; stored as 0.0 / 1.0)

## One entry per parameter: {name, label, min, max, step, suffix, kind}.
## Order defines the modal's row order.
static func get_param_defs(shape_id: StringName) -> Array:
	match shape_id:
		&"cube":
			return _size_defs()
		&"stair", &"curved_stair":
			var defs := _size_defs()
			defs.append(_count_def("steps", "Steps", 1, 64, 6))
			return defs
		&"prism":
			return _size_defs()
		&"cylinder":
			return [
				_value_def("radius", "Radius", 0.05, 50.0, 0.5, "m"),
				_value_def("height", "Height", 0.05, 100.0, 1.0, "m"),
				_count_def("sides", "Sides", 3, 64, 8),
			]
		&"plane":
			return [
				_value_def("width", "Width", 0.1, 100.0, 1.0, "m"),
				_value_def("depth", "Depth", 0.1, 100.0, 1.0, "m"),
			]
		&"door":
			return [
				_value_def("width", "Width", 0.1, 100.0, 3.0, "m"),
				_value_def("height", "Height", 0.1, 100.0, 2.5, "m"),
				_value_def("depth", "Depth", 0.05, 50.0, 1.0, "m"),
				_value_def("opening_height", "Opening Height", 0.1, 100.0, 2.0, "m"),
				_value_def("leg_width", "Frame Width", 0.05, 50.0, 0.5, "m"),
				_bool_def("arched", "Arched", true),
				_count_def("arch_segments", "Arch Segments", 1, 32, 6),
			]
		&"pipe":
			return [
				_value_def("radius", "Radius", 0.05, 50.0, 0.5, "m"),
				_value_def("height", "Height", 0.05, 100.0, 1.0, "m"),
				_value_def("thickness", "Thickness", 0.01, 25.0, 0.125, "m"),
				_count_def("sides", "Sides", 3, 64, 8),
			]
		&"cone":
			return [
				_value_def("radius", "Radius", 0.05, 50.0, 0.5, "m"),
				_value_def("height", "Height", 0.05, 100.0, 1.0, "m"),
				_count_def("sides", "Sides", 3, 64, 8),
			]
		&"sprite":
			return [
				_value_def("width", "Width", 0.1, 100.0, 1.0, "m"),
				_value_def("depth", "Depth", 0.1, 100.0, 1.0, "m"),
			]
		&"arch":
			return [
				_value_def("radius", "Radius", 0.1, 50.0, 1.0, "m"),
				_value_def("depth", "Depth", 0.05, 50.0, 0.5, "m"),
				_value_def("thickness", "Thickness", 0.01, 25.0, 0.3, "m"),
				_count_def("sides", "Sides", 3, 64, 8),
				_value_def("sweep", "Sweep", 30.0, 360.0, 180.0, "°"),
			]
		&"sphere":
			return [
				_value_def("radius", "Radius", 0.05, 50.0, 0.5, "m"),
				_count_def("subdivisions", "Subdivisions", 1, 4, 2),
			]
		&"torus":
			return [
				_value_def("outer_radius", "Outer Radius", 0.1, 50.0, 0.5, "m"),
				_value_def("tube_radius", "Tube Radius", 0.01, 25.0, 0.15, "m"),
			]
	return []

## Default value per parameter name (defaults live with the defs so the
## modal, the rebuild, and the creation flow always agree).
static func get_default_values(shape_id: StringName) -> Dictionary:
	var out := {}
	for def in get_param_defs(shape_id):
		out[def["name"]] = float(def["default"])
	return out

## Regenerates the shape's PBMeshData from a (possibly partial) values dict.
## Returns null for unknown shapes.
static func build(shape_id: StringName, values: Dictionary = {}) -> PBMeshData:
	var v := get_default_values(shape_id)
	for key in values:
		if v.has(key):
			v[key] = float(values[key])
	match shape_id:
		&"cube":
			return PBShapeGenerators.create_box(Vector3(v["width"], v["height"], v["depth"]))
		&"stair":
			return PBShapeComplex.create_stairs(Vector3(v["width"], v["height"], v["depth"]), int(v["steps"]), true)
		&"curved_stair":
			return PBShapeComplex.create_stairs(Vector3(v["width"], v["height"], v["depth"]), int(v["steps"]), true)
		&"prism":
			return PBShapeGenerators.create_prism(Vector3(v["width"], v["height"], v["depth"]))
		&"cylinder":
			return PBShapeCylinder.create_cylinder(v["radius"], v["height"], int(v["sides"]))
		&"plane":
			return PBShapeGenerators.create_plane(v["width"], v["depth"])
		&"door":
			return PBShapeComplex.create_door(v["width"], v["height"], v["opening_height"],
				v["leg_width"], v["depth"], v["arched"] > 0.5, int(v["arch_segments"]))
		&"pipe":
			return PBShapeCylinder.create_pipe(v["radius"], v["height"], v["thickness"], int(v["sides"]))
		&"cone":
			return PBShapeCylinder.create_cone(v["radius"], v["height"], int(v["sides"]))
		&"sprite":
			return PBShapeGenerators.create_sprite(v["width"], v["depth"])
		&"arch":
			return PBShapeComplex.create_arch(v["radius"], v["depth"], v["thickness"], int(v["sides"]), v["sweep"])
		&"sphere":
			return PBShapeComplex.create_sphere(v["radius"], int(v["subdivisions"]))
		&"torus":
			var inner: float = maxf(0.01, v["outer_radius"] - v["tube_radius"])
			return PBShapeComplex.create_torus(inner, v["tube_radius"])
	return null

## True when the shape has parameters the creation drag cannot express
## (steps, sides, thickness, sweep...). Simple size-only shapes (cube,
## prism, plane, sprite) skip the placement modal entirely — the shape is
## finalized at the confirming click; Edit Params can always be used later.
static func needs_params_modal(shape_id: StringName) -> bool:
	for def in get_param_defs(shape_id):
		if not (def["name"] in ["width", "height", "depth", "radius", "outer_radius"]):
			return true
	return false

## The shape's facing direction in LOCAL space (the orange creation arrow),
## or Vector3.ZERO when the shape is symmetric enough that an arrow would be
## noise. Stairs rise toward +Z (their generator stacks steps along +Z); the
## door's front face is its local +Z.
static func facing_direction(shape_id: StringName) -> Vector3:
	match shape_id:
		&"stair", &"curved_stair", &"door":
			return Vector3(0, 0, 1)
	return Vector3.ZERO

## The parameter the height drag drives for shapes WITHOUT a height param
## (sphere / torus / arch — their vertical size IS a radius), relative to the
## value the base drag left: value = base_value + rate * height. The rate is
## chosen so the shape's topmost point follows the cursor 1:1 (sphere top =
## 2·radius → 0.5; arch top = radius → 1.0). Empty for shapes with a real
## height param (absolute mapping) and for the sprite (offset flow).
static func height_drag_param(shape_id: StringName) -> Dictionary:
	match shape_id:
		&"sphere":
			return {"param": "radius", "rate": 0.5, "min": 0.05}
		&"torus":
			return {"param": "tube_radius", "rate": 0.5, "min": 0.01}
		&"arch":
			return {"param": "radius", "rate": 1.0, "min": 0.05}
	return {}

## True when the shape must stay sitting ON the surface no matter which way
## the height drag goes (round shapes shrink instead of growing below; the
## sprite rides the normal). Shapes with a real height param keep ProBuilder's
## negative-height "grow below the surface" behavior.
static func stays_on_surface(shape_id: StringName) -> bool:
	return shape_id == &"sprite" or not height_drag_param(shape_id).is_empty()

## True when the creation height drag displaces the shape along the surface
## normal instead of resizing it (the sprite placement flow: click to anchor,
## mouse to push off the surface, click to confirm).
static func height_drags_offset(shape_id: StringName) -> bool:
	return shape_id == &"sprite"

## Maps a creation drag (base rect extents u/v in the surface plane + height
## along the normal) onto the shape's parameter values. The mapping is the
## same for EVERY surface because the placement basis already orients the
## data: u → width (local x), v → depth (local z), the normal extent →
## height (local y — along the face normal, horizontal on walls).
## `base_values` is the values snapshot at base release (empty during the
## base drag itself); shapes without a height param use it to apply the
## height drag RELATIVELY (height_drag_param) so the mouse drives the vertical
## size directly instead of competing with the base extents via max().
## `height = NAN` means "base drag only" — height-driven values keep their
## current values. (A NEGATIVE height is a real signed drag: cubes grow
## below the surface, round shapes shrink.)
static func apply_drag_extents(values: Dictionary, u_size: float, v_size: float,
		height: float, base_values: Dictionary = {}) -> void:
	var height_known := not is_nan(height)
	if values.has("width"):
		values["width"] = maxf(0.05, u_size)
	if values.has("depth"):
		values["depth"] = maxf(0.05, v_size)
	if values.has("height") and height_known:
		values["height"] = maxf(0.05, height)
	# Round-in-plan shapes: the footprint grows from the base rect only —
	# a rect footprint (the arch, which has a real depth) uses the width;
	# a circular one (cylinder, pipe, cone, sphere, torus) inscribes the
	# larger extent. This runs for height-param shapes (cylinder/pipe/cone)
	# too — the u/v extents persist through the height phase, so the radius
	# always tracks the base drag instead of sticking at the default.
	var footprint := maxf(u_size, v_size)
	if values.has("depth"):
		footprint = u_size
	if values.has("radius"):
		values["radius"] = maxf(0.05, footprint * 0.5)
	elif values.has("outer_radius"):
		values["outer_radius"] = maxf(0.1, footprint * 0.5)
	if not values.has("height"):
		# The height drag drives the vertical size parameter relative to the
		# base-release value, 1:1 with the cursor (see height_drag_param).
		if height_known and not base_values.is_empty():
			var mapping := height_drag_param(_shape_id_of_values(values))
			if not mapping.is_empty() and base_values.has(mapping["param"]):
				var param: String = mapping["param"]
				values[param] = maxf(mapping["min"],
					float(base_values[param]) + float(mapping["rate"]) * height)
			# The torus tube must never outgrow the ring.
			if values.has("tube_radius") and values.has("outer_radius"):
				values["tube_radius"] = minf(values["tube_radius"],
					values["outer_radius"] * 0.95)

## Best-effort reverse lookup for apply_drag_extents: the values keys encode
## which round shape this is (sphere radius / torus outer_radius).
static func _shape_id_of_values(values: Dictionary) -> StringName:
	if values.has("outer_radius") and values.has("tube_radius"):
		return &"torus"
	if values.has("subdivisions"):
		return &"sphere"
	if values.has("sweep"):
		return &"arch"
	return &""

# ── Def builders ─────────────────────────────────────────────────────────────

static func _size_defs() -> Array:
	return [
		_value_def("width", "Width", 0.05, 100.0, 1.0, "m"),
		_value_def("height", "Height", 0.05, 100.0, 1.0, "m"),
		_value_def("depth", "Depth", 0.05, 100.0, 1.0, "m"),
	]

static func _value_def(name: String, label: String, min_v: float, max_v: float,
		default_v: float, suffix := "") -> Dictionary:
	return {"name": name, "label": label, "min": min_v, "max": max_v,
		"step": _step_for(max_v - min_v), "suffix": suffix,
		"default": default_v, "kind": KIND_VALUE}

static func _count_def(name: String, label: String, min_v: int, max_v: int,
		default_v: int) -> Dictionary:
	return {"name": name, "label": label, "min": float(min_v), "max": float(max_v),
		"step": 1.0, "suffix": "", "default": float(default_v), "kind": KIND_COUNT}

static func _bool_def(name: String, label: String, default_v: bool) -> Dictionary:
	return {"name": name, "label": label, "min": 0.0, "max": 1.0,
		"step": 1.0, "suffix": "", "default": 1.0 if default_v else 0.0,
		"kind": KIND_BOOL}

## Keeps SpinBox steps human (0.1 for ranges spanning <10, 0.5 below 100,
## 1.0 beyond).
static func _step_for(span: float) -> float:
	if span <= 10.0:
		return 0.05
	if span <= 100.0:
		return 0.5
	return 1.0
