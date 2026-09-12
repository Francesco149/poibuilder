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
		&"stair":
			var defs := _size_defs()
			defs.append(_count_def("steps", "Steps", 1, 64, 6))
			defs.append(_bool_def("sides", "Sides", true))
			return defs
		&"curved_stair":
			return [
				_value_def("stair_width", "Stair Width", 0.1, 50.0, 1.5, "m"),
				_value_def("height", "Height", 0.1, 100.0, 2.0, "m"),
				_value_def("inner_radius", "Inner Radius", 0.0, 50.0, 0.5, "m"),
				_value_def("curvature", "Curvature", -360.0, 360.0, 180.0, "°"),
				_count_def("steps", "Steps", 1, 64, 8),
				_bool_def("sides", "Sides", true),
			]
		&"prism":
			return _size_defs()
		&"cylinder":
			return [
				_value_def("radius", "Radius", 0.1, 50.0, 0.5, "m"),
				_value_def("height", "Height", 0.1, 100.0, 1.0, "m"),
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
				_value_def("depth", "Depth", 0.1, 50.0, 1.0, "m"),
				_value_def("opening_height", "Opening Height", 0.1, 100.0, 2.0, "m"),
				_value_def("leg_width", "Frame Width", 0.1, 50.0, 0.5, "m"),
				_bool_def("arched", "Arched", true),
				_count_def("arch_segments", "Arch Segments", 1, 32, 6),
			]
		&"pipe":
			return [
				_value_def("radius", "Radius", 0.1, 50.0, 0.5, "m"),
				_value_def("height", "Height", 0.1, 100.0, 1.0, "m"),
				_value_def("thickness", "Thickness", 0.01, 25.0, 0.125, "m"),
				_count_def("sides", "Sides", 3, 64, 8),
			]
		&"cone":
			return [
				_value_def("radius", "Radius", 0.1, 50.0, 0.5, "m"),
				_value_def("height", "Height", 0.1, 100.0, 1.0, "m"),
				_count_def("sides", "Sides", 3, 64, 8),
			]
		&"sprite":
			return [
				_value_def("width", "Width", 0.1, 100.0, 1.0, "m"),
				_value_def("height", "Height", 0.1, 100.0, 1.0, "m"),
				_bool_def("lit", "Lit (Shaded)", false),
				_bool_def("cast_shadow", "Cast Shadows", true),
				_bool_def("billboard", "Auto Orient To Camera", true),
			]
		&"arch":
			return [
				_value_def("radius", "Radius", 0.1, 50.0, 1.0, "m"),
				_value_def("depth", "Depth", 0.1, 50.0, 0.5, "m"),
				_value_def("thickness", "Thickness", 0.01, 25.0, 0.3, "m"),
				_count_def("sides", "Sides", 3, 64, 8),
				_value_def("sweep", "Sweep", 30.0, 360.0, 180.0, "°"),
			]
		&"sphere":
			return [
				_value_def("radius", "Radius", 0.1, 50.0, 0.5, "m"),
				_count_def("subdivisions", "Subdivisions", 1, 4, 2),
			]
		&"torus":
			return [
				_value_def("outer_radius", "Outer Radius", 0.1, 50.0, 0.5, "m"),
				_value_def("tube_radius", "Tube Radius", 0.01, 25.0, 0.15, "m"),
			]
		&"ngon":
			return [
				_value_def("radius", "Radius", 0.1, 50.0, 1.0, "m"),
				_value_def("height", "Height", 0.1, 100.0, 2.0, "m"),
				_count_def("sides", "Sides", 3, 64, 6),
			]
	return []

## Default value per parameter name (defaults live with the defs so the
## modal, the rebuild, and the creation flow always agree).
static func get_default_values(shape_id: StringName) -> Dictionary:
	var out := {}
	for def in get_param_defs(shape_id):
		out[def["name"]] = float(def["default"])
	if shape_id == &"sprite" and not out.has("depth"):
		out["depth"] = out.get("height", 1.0)
	return out

## Regenerates the shape's PBMeshData from a (possibly partial) values dict.
## Returns null for unknown shapes.
static func build(shape_id: StringName, values: Dictionary = {}) -> PBMeshData:
	var v := get_default_values(shape_id)
	for key in values:
		if v.has(key):
			v[key] = float(values[key])
	var data: PBMeshData = null
	match shape_id:
		&"cube":
			data = PBShapeGenerators.create_box(Vector3(v["width"], v["height"], v["depth"]))
		&"stair":
			var build_sides: bool = v["sides"] > 0.5 if v.has("sides") else true
			data = PBShapeComplex.create_stairs(Vector3(v["width"], v["height"], v["depth"]), int(v["steps"]), build_sides)
		&"curved_stair":
			var build_sides: bool = v["sides"] > 0.5 if v.has("sides") else true
			data = PBShapeComplex.create_curved_stairs(v["stair_width"], v["height"], v["inner_radius"], v["curvature"], int(v["steps"]), build_sides)
		&"prism":
			data = PBShapeGenerators.create_prism(Vector3(v["width"], v["height"], v["depth"]))
		&"cylinder":
			data = PBShapeCylinder.create_cylinder(v["radius"], v["height"], int(v["sides"]))
		&"plane":
			data = PBShapeGenerators.create_plane(v["width"], v["depth"])
		&"door":
			data = PBShapeComplex.create_door(v["width"], v["height"], v["opening_height"],
				v["leg_width"], v["depth"], v["arched"] > 0.5, int(v["arch_segments"]))
		&"pipe":
			data = PBShapeCylinder.create_pipe(v["radius"], v["height"], v["thickness"], int(v["sides"]))
		&"cone":
			data = PBShapeCylinder.create_cone(v["radius"], v["height"], int(v["sides"]))
		&"sprite":
			var sw: float = float(v.get("width", 1.0))
			var sh: float = float(v.get("height", v.get("depth", 1.0)))
			data = PBShapeGenerators.create_sprite(sw, sh)
		&"arch":
			data = PBShapeComplex.create_arch(v["radius"], v["depth"], v["thickness"], int(v["sides"]), v["sweep"])
		&"sphere":
			data = PBShapeComplex.create_sphere(v["radius"], int(v["subdivisions"]))
		&"torus":
			var inner: float = maxf(0.01, v["outer_radius"] - v["tube_radius"])
			data = PBShapeComplex.create_torus(inner, v["tube_radius"])
		&"ngon":
			var sides: int = int(v["sides"]) if v.has("sides") else 6
			var radius: float = float(v["radius"]) if v.has("radius") else 1.0
			var height: float = float(v["height"]) if v.has("height") else 2.0
			var poly := PackedVector3Array()
			for i in range(sides):
				var angle: float = float(i) * TAU / float(sides)
				poly.append(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
			data = PBShapeComplex.create_ngon_prism(poly, height, Vector3.UP)
	if data != null:
		data.shape_id = shape_id
		data.shape_params = v.duplicate()
		data.shape_edited = false
		data.get_texture_anchor()
		if data.materials.is_empty():
			var def_mat := PBMeshData.get_default_material()
			if def_mat != null:
				data.materials.append(def_mat)
	return data

## True when the shape has parameters the creation drag cannot express
## (steps, sides, thickness, sweep...). Simple size-only shapes (cube,
## prism, plane, sprite) skip the placement modal entirely — the shape is
## finalized at the confirming click; Edit Params can always be used later.
static func needs_params_modal(shape_id: StringName) -> bool:
	if shape_id == &"sprite":
		return false
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
		&"stair", &"curved_stair", &"door", &"arch":
			return Vector3(0, 0, 1)
	return Vector3.ZERO

## True when the shape's facing naturally aligns with the shorter base dimension
## (doors and arches: the opening spans the longer dimension, the depth/facing
## is the shorter wall thickness — the arc of an arch lies in the shape's local
## XY plane, exactly like a door's opening). False when facing aligns with the
## longer dimension (stairs: run/steps climb along the longer dimension).
static func facing_prefers_shorter(shape_id: StringName) -> bool:
	return shape_id == &"door" or shape_id == &"arch"

## Backward-compatible alias for facing_prefers_shorter.
static func facing_across_dominant(shape_id: StringName) -> bool:
	return facing_prefers_shorter(shape_id)
## The parameter the height drag drives for shapes WITHOUT a height param
## (sphere / torus / arch — their vertical size IS a radius), relative to the
## value the base drag left: value = base_value + rate * height. The rate is
## chosen so the shape's topmost point follows the cursor 1:1 (sphere top =
## 2·radius → 0.5; arch top = radius → 1.0). Empty for shapes with a real
## height param (absolute mapping) and for the sprite (offset flow).
static func height_drag_param(shape_id: StringName) -> Dictionary:
	match shape_id:
		&"sphere":
			return {"param": "radius", "rate": 0.5, "min": 0.1}
		&"torus":
			return {"param": "tube_radius", "rate": 0.5, "min": 0.01}
		&"arch":
			return {"param": "radius", "rate": 1.0, "min": 0.1}
	return {}

## True when the shape must stay sitting ON the surface no matter which way
## the height drag goes (round shapes shrink instead of growing below; the
## sprite and the plane ride the normal). Shapes with a real height param keep
## ProBuilder's negative-height "grow below the surface" behavior.
static func stays_on_surface(shape_id: StringName) -> bool:
	return height_drags_offset(shape_id) or not height_drag_param(shape_id).is_empty()

## True for shapes whose IN-PLANE orientation is fixed by the WORLD rather than
## by the drag: a stand-off plane is a sheet of something (falling water, a
## sign, a poster) and its texture axes have to be predictable — a sheet laid
## out along the drag's own direction put the waterfall's V axis HORIZONTAL on
## a wall and the pool's sideways on the floor, so the water ran sideways
## instead of falling and the churn ran across instead of away from the wall
## (the "scrolling textures flowing the wrong way" report from the map act).
static func world_aligned_in_plane(shape_id: StringName) -> bool:
	return shape_id == &"plane"

## The in-plane direction such a shape's V axis (its texture flow, local +Z)
## runs: DOWN on a wall or a slope, +Z (BACK) on a floor or a ceiling. This is
## the shipped showcase map's own convention — its water sheets run down the
## wall, its pool and foam run away from the wall — so a sheet built through
## the creation flow animates exactly like the one the device plays.
static func plane_flow_axis(normal: Vector3) -> Vector3:
	var n := normal.normalized()
	var down := Vector3.DOWN
	var projected: Vector3 = down - n * n.dot(down)
	if projected.length_squared() < 0.0001:
		return Vector3.BACK
	return projected.normalized()

## True when the creation height drag displaces the shape along the surface
## normal instead of resizing it — i.e. the third dimension is a STAND-OFF, not
## a size. Two shapes work this way:
##   - sprite: click to anchor (no base drag), mouse to push off the surface.
##   - plane:  drag the sheet out parallel to the surface, then mouse to lift
##     it clear of that surface (a waterfall sheet hanging in front of a wall,
##     a sign board, a floating decal plane).
## For both, the drag/offset is clamped at >= 0: the plane never sinks into
## the surface it was drawn on, and its size comes entirely from the base drag.
static func height_drags_offset(shape_id: StringName) -> bool:
	return shape_id == &"sprite" or shape_id == &"plane"

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
	if values.has("height") and height_known:
		# The drag's SIGN is carried by the PLACEMENT, not by the parameter:
		# placement_transform anchors the shape's TOP face to the drag plane
		# when the drag went below it (ProBuilder's "drag down to grow below").
		# So the parameter is the magnitude of the drag — clamping the signed
		# value here turned a courtyard floor dragged 0.5 m downward into a
		# 1 cm wafer sitting inside the grid ("the floor is placed with zero
		# height, z-fighting the grid").
		values["height"] = maxf(0.1, absf(height))
	if values.has("depth"):
		values["depth"] = maxf(0.1, v_size)
	if values.has("width"):
		if values.has("opening_height"):
			# Door: extends to the selected base area bounds.
			# When the door opening is smaller because it's not tall enough for the arc,
			# the outer frame legs are extended so the side faces reach the bounds of the base area.
			var dh: float = float(values["height"]) if (height_known and height > 0.0) else float(values.get("height", 2.5))
			if height_known and height > 0.0:
				values["opening_height"] = clampf(dh * 0.8, 0.5, dh - 0.2)
			values["width"] = maxf(0.5, u_size)
			var max_opening_w: float = maxf(2.0, dh * 1.5 - 1.0)
			if values["width"] > max_opening_w + 1.0:
				values["leg_width"] = (values["width"] - max_opening_w) * 0.5
			else:
				values["leg_width"] = clampf(0.5, 0.1, (values["width"] - 0.2) * 0.5)
		else:
			values["width"] = maxf(0.1, u_size)
	if values.has("stair_width"):
		var max_dim: float = maxf(u_size, v_size)
		var in_r: float = float(values.get("inner_radius", 0.5))
		values["stair_width"] = maxf(0.1, max_dim * 0.5 - in_r)
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
		values["radius"] = maxf(0.1, footprint * 0.5)
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
		_value_def("width", "Width", 0.1, 100.0, 1.0, "m"),
		_value_def("height", "Height", 0.1, 100.0, 1.0, "m"),
		_value_def("depth", "Depth", 0.1, 100.0, 1.0, "m"),
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
	if span <= 100.0:
		return 0.1
	return 1.0
