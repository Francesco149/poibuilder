## PBGrid — PoiBuilder's own grid + snapping state (runtime-safe, headless-testable).
##
## PoiBuilder manages its OWN grid, independent of the editor's 3D grid and
## snap settings (those still govern engine-side node drags in OBJECT mode
## and non-PB nodes). The model is ProBuilder/ProGrids-inspired:
##
## - `unit` is the MAJOR grid size (default 1m); `subdivisions` splits it,
##   so the effective snap step is `unit / subdivisions` (default 0.2m).
## - `origin` offsets the whole grid (origin.y acts as the grid ELEVATION:
##   `[`/`]` raise/lower it by one step for drawing on a floating plane).
## - Snapping quantizes to `step * round(v / step)` with offset from origin
##   (ProBuilder's ProBuilderSnapping.Snap) — axes with a ~0 step pass through.
##
## Application points (wired by the plugin/editor layer):
## - Element MOVE drags: the drag DELTA snaps per-component in WORLD space
##   (incremental/relative mode — preserves intra-selection offsets and works
##   for arbitrarily rotated/scaled nodes).
## - EXTRUDE gestures: the cap distance along the extrude normal snaps.
## - ROTATE drags: the delivered rotation angle snaps to `rotate_step_deg`
##   (15°, engine default).
## - SCALE and INSET drags: intentionally unsnapped (ProBuilder parity).
## - Shape creation: the press point snaps to the grid MASKED by the surface
##   normal (only on cardinal surfaces — ProBuilder's on-grid detection);
##   the base extents and height quantize; `draw_on_grid` routes creation to
##   the grid plane at `origin.y` instead of clicked surfaces.
@tool
class_name PBGrid
extends RefCounted

# ==============================================================================
# Signals
# ==============================================================================

## Any grid parameter changed (persistence + UI refresh + overlay redraw).
signal changed

# ==============================================================================
# State
# ==============================================================================

## Whether PoiBuilder snapping applies to element drags and creation.
var enabled: bool = true:
	set(v):
		if enabled == v:
			return
		enabled = v
		changed.emit()

## Major grid line spacing in meters (the "unit").
var unit: float = 1.0:
	set(v):
		var cv := clampf(v, 0.001, 1024.0)
		if is_equal_approx(unit, cv):
			return
		unit = cv
		changed.emit()

## Subdivisions per unit; snap step = unit / subdivisions (ProGrids model).
var subdivisions: int = 5:
	set(v):
		var cv := clampi(v, 1, 128)
		if subdivisions == cv:
			return
		subdivisions = cv
		changed.emit()

## World-space origin of the grid. `y` doubles as the grid ELEVATION: the
## drawing plane and the Y snap offset live here; x/z offset the grid too.
var origin: Vector3 = Vector3.ZERO:
	set(v):
		if origin.is_equal_approx(v):
			return
		origin = v
		changed.emit()

## NEW shapes are always drawn on the grid plane (y = origin.y) instead of
## the surface under the cursor. Opt-in: some blocking workflows prefer
## planar grid drawing over surface-aligned drawing.
var draw_on_grid: bool = false:
	set(v):
		if draw_on_grid == v:
			return
		draw_on_grid = v
		changed.emit()

## The PoiBuilder viewport grid overlay is drawn (independent from the
## editor's own grid, which keeps rendering regardless).
var show_grid: bool = true:
	set(v):
		if show_grid == v:
			return
		show_grid = v
		changed.emit()

## Rotation snap step in degrees (matches the engine's 15° default).
var rotate_step_deg: float = 15.0:
	set(v):
		var cv := clampf(v, 0.0, 180.0)
		if is_equal_approx(rotate_step_deg, cv):
			return
		rotate_step_deg = cv
		changed.emit()

# ==============================================================================
# Derived values
# ==============================================================================

## The effective snap step in meters (unit / subdivisions).
func step() -> float:
	return unit / float(subdivisions)

## The grid elevation (== origin.y).
func elevation() -> float:
	return origin.y

## The drawing plane for on-grid creation and the floor fallback.
func grid_plane() -> Plane:
	return Plane(Vector3.UP, origin.y)

# ==============================================================================
# Scalar / vector snapping (ProBuilderSnapping.Snap)
# ==============================================================================

## Nearest multiple of step, or `v` unchanged when snapping is off.
func snap_val(v: float) -> float:
	if not enabled:
		return v
	return snap_val_exact(v, step())

## Raw: nearest multiple of `p_step` (0 step passes through, ProBuilder parity).
static func snap_val_exact(v: float, p_step: float) -> float:
	if absf(p_step) < 0.0001:
		return v
	return p_step * roundf(v / p_step)

## Snaps a world-space position onto the grid (origin-offset). Snapping for
## absolute positions accounts for the elevation: y snaps to origin.y + k·step.
func snap_point(p: Vector3) -> Vector3:
	if not enabled:
		return p
	var s := step()
	var local := p - origin
	return Vector3(snap_val_exact(local.x, s), snap_val_exact(local.y, s),
		snap_val_exact(local.z, s)) + origin

## Snaps a point onto the grid MASKED by the surface normal: the axis the
## surface normal aligns with (when cardinal) is left untouched — drawing on
## a wall at x = 3.35 keeps x exact instead of yanking the rect to the
## nearest grid x (ProBuilder GetSnappingMaskBasedOnNormalVector).
func snap_point_masked(p: Vector3, surface_normal: Vector3) -> Vector3:
	if not enabled:
		return p
	var n := surface_normal.normalized()
	var out := snap_point(p)
	if absf(absf(n.x) - 1.0) < 0.001:
		out.x = p.x
	if absf(absf(n.y) - 1.0) < 0.001:
		out.y = p.y
	if absf(absf(n.z) - 1.0) < 0.001:
		out.z = p.z
	return out

## True when the surface normal is world-axis aligned (only those surfaces
## get absolute press-point snapping — arbitrary surfaces keep the exact
## press and snap increments instead).
static func is_cardinal(n: Vector3) -> bool:
	var nn := n.normalized()
	return absf(absf(nn.x) - 1.0) < 0.001 \
		or absf(absf(nn.y) - 1.0) < 0.001 \
		or absf(absf(nn.z) - 1.0) < 0.001

## Snaps a TRANSLATION DELTA that lives in a node's local space to the world
## grid: converts through the node's rotation (and uniform scale), quantizes
## per world component, converts back. Incremental snapping — the landed
## positions keep their current grid offset relationship.
func snap_local_delta(node_basis: Basis, local_delta: Vector3) -> Vector3:
	if not enabled:
		return local_delta
	var world := node_basis * local_delta
	world = Vector3(snap_val_exact(world.x, step()),
		snap_val_exact(world.y, step()), snap_val_exact(world.z, step()))
	return node_basis.inverse() * world

## Snaps a world-space distance along an axis (extrude gestures): only the
## component along `axis` is quantized; tangential motion passes through.
func snap_distance_along(axis: Vector3, world_distance: float) -> float:
	if not enabled:
		return world_distance
	return snap_val_exact(world_distance, step())

## Snaps a pure-rotation basis (as delivered by the engine's rotate drags) to
## `rotate_step_deg` about its own axis. Non-rotational bases pass through.
func snap_rotation(b: Basis) -> Basis:
	if not enabled or rotate_step_deg < 0.01:
		return b
	var q := b.get_rotation_quaternion()
	var axis := q.get_axis()
	var angle := q.get_angle()
	if axis.length_squared() < 0.5 or absf(angle) < 0.000001:
		return b  # identity / no rotation
	var snapped_deg := snap_val_exact(rad_to_deg(angle), rotate_step_deg)
	return Basis(axis.normalized(), deg_to_rad(snapped_deg))

# ==============================================================================
# Grid parameter adjustments (keybinds + toolbar)
# ==============================================================================

## Finer snap: one more subdivision (step shrinks).
func subdivisions_up() -> void:
	subdivisions += 1

## Coarser snap: one fewer subdivision (clamped at 1).
func subdivisions_down() -> void:
	subdivisions -= 1

## Doubles the major grid unit (1m → 2m → 4m…).
func unit_up() -> void:
	unit *= 2.0

## Halves the major grid unit (1m → 0.5m).
func unit_down() -> void:
	unit *= 0.5

## Raises the grid elevation by one snap step.
func raise() -> void:
	origin = origin + Vector3.UP * step()

## Lowers the grid elevation by one snap step.
func lower() -> void:
	origin = origin - Vector3.UP * step()

## Resets the grid origin to the world origin.
func reset_origin() -> void:
	origin = Vector3.ZERO

# ==============================================================================
# Compact display strings (toolbar readouts)
# ==============================================================================

## "1m / 5 → 0.2m" style summary of the current grid.
func summary() -> String:
	return "%sm / %d = %sm" % [str(unit), subdivisions, str(step())]

## Elevation readout, "" on the zero plane.
func elevation_summary() -> String:
	if absf(origin.y) < 0.0001:
		return ""
	return "↕ " + str(snappedf(origin.y, 0.001))
