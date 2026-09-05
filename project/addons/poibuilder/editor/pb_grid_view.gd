## PBGridView — Computes PoiBuilder's grid line soup; the PBGizmoPlugin draws
## it on the ACTIVE mesh's gizmo (node gizmos are the one render channel that
## always re-renders when it changes).
##
## World→drawn placement: lines are built in WORLD space (the grid is a
## world concept) and transformed into the active node's local space by the
## gizmo draw — a rotated/scaled mesh still sees a world-aligned grid.
##
## Visual language: stock-grid topology (minor lines, major unit lines, axis
## stripes through the grid origin) in a cyan palette, vertex colors carry a
## distance fade — stock grids dissolve toward the horizon instead of
## degenerating into a moiré band. Depth-tested (occluded by geometry).
@tool
class_name PBGridView
extends RefCounted

## Cyan palette against the editor's warm-gray stock grid.
const COLOR_MINOR := Color(0.45, 0.78, 0.95, 0.20)
const COLOR_MAJOR := Color(0.55, 0.88, 1.0, 0.5)
const COLOR_AXIS_X := Color(0.95, 0.5, 0.4, 0.85)
const COLOR_AXIS_Z := Color(0.45, 0.7, 1.0, 0.85)

## Focus movement that still reuses the cached line soup (grid steps).
const REBUILD_MOVE_DIST := 4.0

var grid: PBGrid = null
var logger: PBLogger = null

## Cached vertex-color line soup (WORLD space).
var _lines: PackedVector3Array = PackedVector3Array()
var _colors: PackedColorArray = PackedColorArray()

var _dirty := true
var _last_focus := Vector3(INF, INF, INF)
var _last_cam_height := INF

## Number of rebuilds — the plugin's driver heartbeat (the GUI harness
## asserts this advances with camera/grid changes).
var update_ticks := 0

func _init(p_grid: PBGrid) -> void:
	grid = p_grid
	if grid != null and not grid.changed.is_connected(mark_dirty):
		grid.changed.connect(mark_dirty)

func mark_dirty() -> void:
	_dirty = true

## Returns true when the cached lines are stale (settings, elevation, focus
## change, zoom level) — the caller then redraws the active node gizmo.
func update(cam: Camera3D) -> bool:
	if cam == null or grid == null:
		return false
	var xf := _cam_transform(cam)
	var elev := grid.origin.y
	var focus := _focus_cam(xf, elev)
	var height := absf(xf.origin.y - elev)
	if not _dirty \
		and focus.distance_squared_to(_last_focus) < REBUILD_MOVE_DIST * REBUILD_MOVE_DIST \
		and absf(height - _last_cam_height) < 0.5 * REBUILD_MOVE_DIST:
		return false
	_rebuild(focus, elev, height)
	_dirty = false
	_last_focus = focus
	_last_cam_height = height
	update_ticks += 1
	return true

## Appends the cached lines (world space → node's local space) to the gizmo.
func draw_onto(gizmo, node: PBMesh, gizmo_plugin: PBGizmoPlugin) -> void:
	if grid == null or _lines.size() < 2:
		return
	var xf := node.global_transform.affine_inverse()
	var local := PackedVector3Array()
	local.resize(_lines.size())
	for i in range(_lines.size()):
		local[i] = xf * _lines[i]
	gizmo.add_lines(local, gizmo_plugin.get_material("pb_grid", gizmo))

# ==============================================================================
# Internals
# ==============================================================================

## Camera transform that ALSO works for off-tree cameras (tests): the global
## transform errors on nodes outside the tree — the local transform is used
## as the fallback.
static func _cam_transform(cam: Camera3D) -> Transform3D:
	if cam.is_inside_tree():
		return cam.global_transform
	return cam.transform

## View focus = the camera-center ray ∩ the grid plane (or straight down).
static func _focus_cam(xform: Transform3D, elev: float) -> Vector3:
	var dir := -xform.basis.z
	if absf(dir.y) > 0.001:
		var t := (elev - xform.origin.y) / dir.y
		if t > 0.0:
			return xform.origin + dir * t
	return Vector3(xform.origin.x, elev, xform.origin.z)

func _rebuild(focus: Vector3, elev: float, cam_height: float) -> void:
	_lines.clear()
	_colors.clear()
	var step := grid.step()
	# Extent scales with viewing distance — reaches the horizon when zoomed
	# out, focuses the work area when zoomed in.
	var extent := clampf(cam_height * 4.0 + 16.0, 24.0, 512.0)

	# Thin lines by powers of two when the budget overflows.
	var spacing := step
	while 2.0 * extent / spacing > 200.0:
		spacing *= 2.0
	var unit_spacing := grid.unit
	while 2.0 * extent / unit_spacing > 200.0:
		unit_spacing *= 2.0

	var zc: float = focus.z
	var xc: float = focus.x
	# Subdivision (minor) lines live LOCALLY around the focus — a hard
	# ProGrids-style radius of ~40 subdivisions; drawing them to the horizon
	# would instantly read as a white moiré field. Major (unit) lines fade
	# in with distance and dissolve before the horizon.
	var minor_radius := minf(step * 40.0, extent)
	var fade_inner := extent * 0.45
	var fade_outer := extent * 0.96

	var zi0 := int(floorf((zc - extent - grid.origin.z) / spacing))
	var zi1 := int(ceilf((zc + extent - grid.origin.z) / spacing))
	for i in range(zi0, zi1 + 1):
		var z: float = grid.origin.z + i * spacing
		var is_major: bool = is_zero_approx(fposmod(z - grid.origin.z, unit_spacing))
		if is_major:
			_add_faded(xc, zc, fade_inner, fade_outer,
				Vector3(xc - extent, elev, z), Vector3(xc + extent, elev, z), COLOR_MAJOR)
		elif absf(z - zc) <= minor_radius:
			_add_faded(xc, zc, minor_radius * 0.7, minor_radius,
				Vector3(maxf(xc - minor_radius, xc - extent), elev, z),
				Vector3(minf(xc + minor_radius, xc + extent), elev, z), COLOR_MINOR)

	var xi0 := int(floorf((xc - extent - grid.origin.x) / spacing))
	var xi1 := int(ceilf((xc + extent - grid.origin.x) / spacing))
	for i in range(xi0, xi1 + 1):
		var x: float = grid.origin.x + i * spacing
		var is_major: bool = is_zero_approx(fposmod(x - grid.origin.x, unit_spacing))
		if is_major:
			_add_faded(xc, zc, fade_inner, fade_outer,
				Vector3(x, elev, zc - extent), Vector3(x, elev, zc + extent), COLOR_MAJOR)
		elif absf(x - xc) <= minor_radius:
			_add_faded(xc, zc, minor_radius * 0.7, minor_radius,
				Vector3(x, elev, maxf(zc - minor_radius, zc - extent)),
				Vector3(x, elev, minf(zc + minor_radius, zc + extent)), COLOR_MINOR)

	# Axis stripes through the grid origin — engine grid language.
	_add_faded(xc, zc, fade_inner, fade_outer,
		Vector3(xc - extent, elev, grid.origin.z), Vector3(xc + extent, elev, grid.origin.z), COLOR_AXIS_X)
	_add_faded(xc, zc, fade_inner, fade_outer,
		Vector3(grid.origin.x, elev, zc - extent), Vector3(grid.origin.x, elev, zc + extent), COLOR_AXIS_Z)

## Radial fade by SEGMENT MIDPOINT: a line crossing the focus must stay
## solid end-to-end (per-vertex fade against the focus zeroed every
## line's far endpoints and dropped the whole line soup). Uniform per-line
## alpha by how far the line sits from the focus, engine-grid style.
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
