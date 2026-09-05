## PBGridView — Procedural infinite 3D editor grid for PoiBuilder.
##
## Visual language: matches the stock Godot grid (subdivisions, major unit lines,
## colored axis lines, distance fading, and grazing-angle fading), in PoiBuilder's
## crisp cyan palette. Rendered to the infinite horizon via an unshaded spatial
## shader on a camera-following quad in the editor's World3D scenario.
##
## Key features:
## - Arms immediately upon plugin activation (scenario-attached, node-independent).
## - Renders to the infinite horizon using smooth distance and angle fading.
## - Exactly lines up with PoiBuilder's snap step (cell_size) and unit (unit_size).
## - Screen-space 1px line thickness via fwidth anti-aliasing; zero moiré.
## - Elevation-aware: instance transform follows camera on XZ and grid.origin.y in Y.
## - Depth-tested: properly occluded by 3D scene geometry.
@tool
class_name PBGridView
extends RefCounted

## Cyan palette against the editor's warm-gray stock grid.
const COLOR_MINOR := Color(0.35, 0.78, 0.95, 0.25)
const COLOR_MAJOR := Color(0.45, 0.88, 1.00, 0.65)
const COLOR_AXIS_X := Color(0.95, 0.35, 0.35, 0.85)
const COLOR_AXIS_Z := Color(0.35, 0.55, 1.00, 0.85)

const GRID_QUAD_HALF_SIZE := 2000.0

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_disabled, fog_disabled;

uniform vec2 grid_origin = vec2(0.0);
uniform float cell_size = 0.2;
uniform float unit_size = 1.0;
uniform float line_width_pixels = 1.0;
uniform vec4 minor_color : source_color = vec4(0.35, 0.78, 0.95, 0.25);
uniform vec4 major_color : source_color = vec4(0.45, 0.88, 1.00, 0.65);
uniform vec4 axis_x_color : source_color = vec4(0.95, 0.35, 0.35, 0.85);
uniform vec4 axis_z_color : source_color = vec4(0.35, 0.55, 1.00, 0.85);
uniform float fade_distance = 800.0;
uniform bool orthogonal = false;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float get_line_alpha(vec2 pos, float step_size, float width_px) {
	vec2 coord = pos / step_size;
	vec2 pixel_size = max(abs(dFdx(coord)) + abs(dFdy(coord)), vec2(0.00001));
	vec2 dist_to_line = min(fract(coord), 1.0 - fract(coord));
	vec2 dist_px = dist_to_line / pixel_size;
	float half_width = max(width_px, 0.25) * 0.5;
	vec2 coverage = 1.0 - smoothstep(vec2(max(half_width - 0.5, 0.0)), vec2(half_width + 0.5), dist_px);
	return max(coverage.x, coverage.y);
}

float get_axis_alpha(float coord, float width_px) {
	float pixel_size = max(abs(dFdx(coord)) + abs(dFdy(coord)), 0.00001);
	float dist_px = abs(coord) / pixel_size;
	float half_width = max(width_px, 0.25) * 0.5;
	return 1.0 - smoothstep(max(half_width - 0.5, 0.0), half_width + 0.5, dist_px);
}

void fragment() {
	vec2 uv = world_pos.xz - grid_origin;

	// Cell line coverage in screen pixels
	float minor_alpha = get_line_alpha(uv, max(cell_size, 0.0001), line_width_pixels);
	float major_alpha = get_line_alpha(uv, max(unit_size, 0.0001), line_width_pixels * 1.25);

	// Fade minor lines out when they become too dense on screen (sub-pixel anti-moiré)
	vec2 minor_pixel_size = fwidth(uv / max(cell_size, 0.0001));
	float density_fade = 1.0 - smoothstep(0.25, 0.75, max(minor_pixel_size.x, minor_pixel_size.y));
	minor_alpha *= density_fade;

	// Axis lines (X axis along Z = 0 -> uv.y == 0; Z axis along X = 0 -> uv.x == 0)
	float axis_x_alpha = get_axis_alpha(uv.y, line_width_pixels * 1.5);
	float axis_z_alpha = get_axis_alpha(uv.x, line_width_pixels * 1.5);

	// Color blending: minor -> major -> axes
	vec4 col = minor_color;
	float a = minor_alpha * minor_color.a;

	if (major_alpha > 0.0) {
		float ma = major_alpha * major_color.a;
		col = mix(col, major_color, ma / max(a + ma, 0.0001));
		a = max(a, ma);
	}

	if (axis_x_alpha > 0.0) {
		float aa = axis_x_alpha * axis_x_color.a;
		col = mix(col, axis_x_color, aa);
		a = max(a, aa);
	}
	if (axis_z_alpha > 0.0) {
		float aa = axis_z_alpha * axis_z_color.a;
		col = mix(col, axis_z_color, aa);
		a = max(a, aa);
	}

	// Distance and grazing-angle fading (stock Godot style)
	float angle_fade = 1.0;
	if (!orthogonal) {
		vec3 view_dir = normalize(CAMERA_POSITION_WORLD - world_pos);
		angle_fade = smoothstep(0.03, 0.20, abs(dot(view_dir, vec3(0.0, 1.0, 0.0))));
	}

	float cam_dist = length(CAMERA_POSITION_WORLD - world_pos);
	float dist_fade = 1.0 - smoothstep(fade_distance * 0.4, fade_distance, cam_dist);

	a *= angle_fade * dist_fade;

	if (a <= 0.001) {
		discard;
	}

	ALBEDO = col.rgb;
	ALPHA = a;
}
"""

var grid: PBGrid = null
var logger: PBLogger = null

## RenderingServer resource IDs
var _mesh_rid: RID = RID()
var _shader_rid: RID = RID()
var _material_rid: RID = RID()
var _instance_rid: RID = RID()
var _scenario_rid: RID = RID()

## Cached line soup (for tests / inspection)
var _lines: PackedVector3Array = PackedVector3Array()
var _colors: PackedColorArray = PackedColorArray()

var _dirty := true
var _last_cam_pos := Vector3(INF, INF, INF)
var _last_cam_height := INF
var _visible := false

var update_ticks := 0

func _init(p_grid: PBGrid) -> void:
	grid = p_grid
	if grid != null and not grid.changed.is_connected(mark_dirty):
		grid.changed.connect(mark_dirty)

func mark_dirty() -> void:
	_dirty = true

## Attaches the grid instance to a World3D scenario (e.g. the editor viewport's).
func attach_scenario(scenario: RID) -> void:
	if _scenario_rid == scenario and _instance_rid.is_valid():
		return
	detach_scenario()
	_scenario_rid = scenario
	_ensure_resources()
	if _instance_rid.is_valid() and _scenario_rid.is_valid():
		RenderingServer.instance_set_scenario(_instance_rid, _scenario_rid)
		RenderingServer.instance_set_visible(_instance_rid, _visible)

## Cleans up the RenderingServer instance and resources.
func detach_scenario() -> void:
	if _instance_rid.is_valid():
		RenderingServer.free_rid(_instance_rid)
		_instance_rid = RID()
	if _mesh_rid.is_valid():
		RenderingServer.free_rid(_mesh_rid)
		_mesh_rid = RID()
	if _material_rid.is_valid():
		RenderingServer.free_rid(_material_rid)
		_material_rid = RID()
	if _shader_rid.is_valid():
		RenderingServer.free_rid(_shader_rid)
		_shader_rid = RID()
	_scenario_rid = RID()

func set_visible(visible: bool) -> void:
	_visible = visible
	if _instance_rid.is_valid():
		RenderingServer.instance_set_visible(_instance_rid, _visible)

func is_visible() -> bool:
	return _visible and _instance_rid.is_valid()

func is_active() -> bool:
	return _instance_rid.is_valid()

## Updates the grid position and shader parameters from the camera.
func update(cam: Camera3D) -> bool:
	if cam == null or grid == null:
		return false
	var xf := _cam_transform(cam)
	var cam_pos := xf.origin
	var elev := grid.origin.y
	var height := absf(cam_pos.y - elev)

	var moved := _dirty or cam_pos.distance_squared_to(_last_cam_pos) > 1.0 or absf(height - _last_cam_height) > 0.5
	if not moved and _instance_rid.is_valid():
		return false

	_ensure_resources()
	if _instance_rid.is_valid():
		# The quad follows the camera on XZ so it always reaches the horizon,
		# positioned at elevation Y in world space.
		var xform := Transform3D(Basis(), Vector3(cam_pos.x, elev, cam_pos.z))
		RenderingServer.instance_set_transform(_instance_rid, xform)

		# Update shader uniforms
		RenderingServer.material_set_param(_material_rid, &"grid_origin", Vector2(grid.origin.x, grid.origin.z))
		RenderingServer.material_set_param(_material_rid, &"cell_size", grid.step())
		RenderingServer.material_set_param(_material_rid, &"unit_size", grid.unit)
		RenderingServer.material_set_param(_material_rid, &"minor_color", COLOR_MINOR)
		RenderingServer.material_set_param(_material_rid, &"major_color", COLOR_MAJOR)
		RenderingServer.material_set_param(_material_rid, &"axis_x_color", COLOR_AXIS_X)
		RenderingServer.material_set_param(_material_rid, &"axis_z_color", COLOR_AXIS_Z)
		RenderingServer.material_set_param(_material_rid, &"orthogonal", cam.projection == Camera3D.PROJECTION_ORTHOGONAL)
		var fade_dist := clampf(cam.far, 300.0, 1500.0)
		RenderingServer.material_set_param(_material_rid, &"fade_distance", fade_dist)

	var focus := _focus_cam(xf, elev)
	_rebuild_lines(focus, elev, height)
	_dirty = false
	_last_cam_pos = cam_pos
	_last_cam_height = height
	update_ticks += 1
	return true

## Backward-compatible stub (no-op: the grid is drawn via RenderingServer directly).
func draw_onto(_gizmo, _node: PBMesh, _gizmo_plugin: PBGizmoPlugin) -> void:
	pass

# ==============================================================================
# Internals
# ==============================================================================

func _ensure_resources() -> void:
	if _instance_rid.is_valid():
		return

	_shader_rid = RenderingServer.shader_create()
	RenderingServer.shader_set_code(_shader_rid, SHADER_CODE)

	_material_rid = RenderingServer.material_create()
	RenderingServer.material_set_shader(_material_rid, _shader_rid)

	# 2-triangle quad spanning 4000m x 4000m
	var half := GRID_QUAD_HALF_SIZE
	var verts := PackedVector3Array([
		Vector3(-half, 0.0, -half),
		Vector3(half, 0.0, -half),
		Vector3(half, 0.0, half),
		Vector3(-half, 0.0, -half),
		Vector3(half, 0.0, half),
		Vector3(-half, 0.0, half),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts

	_mesh_rid = RenderingServer.mesh_create()
	RenderingServer.mesh_add_surface_from_arrays(_mesh_rid, RenderingServer.PRIMITIVE_TRIANGLES, arrays)
	RenderingServer.mesh_surface_set_material(_mesh_rid, 0, _material_rid)

	_instance_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_base(_instance_rid, _mesh_rid)
	RenderingServer.instance_set_layer_mask(_instance_rid, 1) # Layer 1 is always visible in editor viewports
	RenderingServer.instance_geometry_set_cast_shadows_setting(_instance_rid, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_geometry_set_flag(_instance_rid, RenderingServer.INSTANCE_FLAG_IGNORE_OCCLUSION_CULLING, true)
	RenderingServer.instance_geometry_set_flag(_instance_rid, RenderingServer.INSTANCE_FLAG_USE_BAKED_LIGHT, false)

	if _scenario_rid.is_valid():
		RenderingServer.instance_set_scenario(_instance_rid, _scenario_rid)
		RenderingServer.instance_set_visible(_instance_rid, _visible)

static func _cam_transform(cam: Camera3D) -> Transform3D:
	if cam.is_inside_tree():
		return cam.global_transform
	return cam.transform

static func _focus_cam(xform: Transform3D, elev: float) -> Vector3:
	var dir := -xform.basis.z
	if absf(dir.y) > 0.001:
		var t := (elev - xform.origin.y) / dir.y
		if t > 0.0:
			return xform.origin + dir * t
	return Vector3(xform.origin.x, elev, xform.origin.z)

## Rebuilds the CPU line cache (for tests and headless inspection).
func _rebuild_lines(focus: Vector3, elev: float, cam_height: float) -> void:
	_lines.clear()
	_colors.clear()
	var step := grid.step()
	var unit_spacing := grid.unit
	var extent := clampf(cam_height * 4.0 + 16.0, 24.0, 256.0)

	var zc: float = focus.z
	var xc: float = focus.x
	var fade_inner := extent * 0.45
	var fade_outer := extent * 0.96

	var zi0 := int(floorf((zc - extent - grid.origin.z) / step))
	var zi1 := int(ceilf((zc + extent - grid.origin.z) / step))
	for i in range(zi0, zi1 + 1):
		var z: float = grid.origin.z + i * step
		var is_major: bool = is_zero_approx(fposmod(z - grid.origin.z, unit_spacing))
		_add_faded(xc, zc, fade_inner, fade_outer,
			Vector3(xc - extent, elev, z), Vector3(xc + extent, elev, z),
			COLOR_MAJOR if is_major else COLOR_MINOR)

	var xi0 := int(floorf((xc - extent - grid.origin.x) / step))
	var xi1 := int(ceilf((xc + extent - grid.origin.x) / step))
	for i in range(xi0, xi1 + 1):
		var x: float = grid.origin.x + i * step
		var is_major: bool = is_zero_approx(fposmod(x - grid.origin.x, unit_spacing))
		_add_faded(xc, zc, fade_inner, fade_outer,
			Vector3(x, elev, zc - extent), Vector3(x, elev, zc + extent),
			COLOR_MAJOR if is_major else COLOR_MINOR)

	# Axis stripes
	_add_faded(xc, zc, fade_inner, fade_outer,
		Vector3(xc - extent, elev, grid.origin.z), Vector3(xc + extent, elev, grid.origin.z), COLOR_AXIS_X)
	_add_faded(xc, zc, fade_inner, fade_outer,
		Vector3(grid.origin.x, elev, zc - extent), Vector3(grid.origin.x, elev, zc + extent), COLOR_AXIS_Z)

func _add_faded(xc: float, zc: float, inner: float, outer: float,
		a: Vector3, b: Vector3, color: Color) -> void:
	var dmid := Vector2((a.x + b.x) * 0.5 - xc, (a.z + b.z) * 0.5 - zc).length()
	var c: Color = color
	c.a *= 1.0 - smoothstep(inner, outer, dmid)
	if c.a < 0.006:
		return
	_lines.push_back(a)
	_lines.push_back(b)
	_colors.push_back(c)
	_colors.push_back(c)
