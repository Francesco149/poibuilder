## PBTrimWallsTool — Trim swept along the walls you click, with mitred corners.
##
## The interactive session (arm → click wall faces → commit) is driven by the
## plugin from viewport input; everything here is pure logic + geometry so it
## stays headless-testable. Session shape (Unibuilder spec):
##   - Arm it and the trim's parameters appear in the adjust panel straight
##     away; walls are picked while the trim previews live.
##   - Click wall faces (on any PBMesh) in any order; a wall highlights teal
##     under the cursor and amber once chosen. Clicking a chosen wall again
##     drops it; Backspace drops the last; Enter / double-click / panel Apply
##     commits; Esc / Cancel abandons.
##   - The strip sits where the wall meets the room: a wall cube reaching
##     below the floor slab still gets its skirting ON the slab's surface
##     (the caller probes the slab through `floor_probe`), and a cornice
##     tucks under the ceiling slab (`ceiling_probe`). Placement Bottom puts
##     the strip along the walls' bottom edge, Top hangs it from their top;
##     Offset slides it up or down.
##   - Walls meeting at a corner join with a clean mitre at any angle, walls
##     that overlap only carry trim on their visible run (colinear overlaps
##     merge into one interval), and a perimeter closes into a ring. A
##     doorway cut through a wall breaks the run at the jambs (the run
##     follows the clicked face's own boundary at the trim height).
##   - The result is ONE PBMeshData; `last_paths` records the swept path(s)
##     so Edit Params can rebuild the same run with new parameters.
@tool
class_name PBTrimWallsTool
extends RefCounted

enum State { INACTIVE, ARMED }

## Endpoints closer than this are the same joint (metres).
const JOINT_TOLERANCE := 0.05
## A mitre may extend a segment's end by at most this factor of its own
## length (acute corners otherwise shoot the mitre off to infinity).
const MAX_MITRE_FACTOR := 2.0
## Runs chain into one mitred path only when their endpoints are this close
## (metres) — nearby wall pieces of ONE room join; a wall across the room
## never leaches onto the chain.
const CHAIN_REACH := 1.5

var state: State = State.INACTIVE

## The chosen walls, in click order: {"mesh": PBMesh, "face": int}.
var walls: Array[Dictionary] = []

## Live trim parameters (mirrors the adjust panel; see PBShapeParams defs
## for &"trim_walls").
var params: Dictionary = {
	"profile": 1.0,
	"depth": 0.05,
	"height": 0.1,
	"arc_segments": 4.0,
	"top": 0.0,
	"offset": 0.0,
	"upside_down": 0.0,
	"smooth": 1.0,
}

## The world-space path(s) the last build() swept — recorded into the
## committed shape's shape_params so Edit Params can rebuild the same run.
var last_paths: Array[Dictionary] = []

# ── Session ──────────────────────────────────────────────────────────────────

func arm() -> void:
	state = State.ARMED
	walls.clear()
	last_paths.clear()

func disarm() -> void:
	state = State.INACTIVE
	walls.clear()
	last_paths.clear()

func is_active() -> bool:
	return state != State.INACTIVE

## Adds the wall face, or drops it when already chosen. Returns true when the
## face is chosen after the call. `room_normal` is the camera-facing normal
## from the pick — inward-wound meshes (GLB sources) yield the flipped
## geometric normal, and the trim must protrude into the ROOM, never into
## the wall, so the pick's correction wins over the raw geometric one.
func toggle_wall(mesh: PBMesh, face: int, room_normal := Vector3.ZERO) -> bool:
	for i in range(walls.size()):
		var w: Dictionary = walls[i]
		if w["mesh"] == mesh and int(w["face"]) == face:
			walls.remove_at(i)
			return false
	walls.append({"mesh": mesh, "face": face, "normal": room_normal})
	return true

func drop_last() -> bool:
	if walls.is_empty():
		return false
	walls.remove_at(walls.size() - 1)
	return true

func clear_walls() -> void:
	walls.clear()

func is_chosen(mesh: PBMesh, face: int) -> bool:
	for w in walls:
		if w["mesh"] == mesh and int(w["face"]) == face:
			return true
	return false

func wall_count() -> int:
	return walls.size()

# ── Geometry ─────────────────────────────────────────────────────────────────

## The clicked face's polygon in WORLD space (works on nodes outside the
## tree, where global_transform falls back to transform — headless tests).
static func face_world_polygon(mesh: PBMesh, face: int) -> PackedVector3Array:
	if mesh == null or mesh.pb_mesh_data == null:
		return PackedVector3Array()
	if face < 0 or face >= mesh.pb_mesh_data.faces.size():
		return PackedVector3Array()
	var xf: Transform3D = mesh.global_transform if mesh.is_inside_tree() else mesh.transform
	var out := PackedVector3Array()
	for p in mesh.pb_mesh_data.get_face_positions(face):
		out.append(xf * p)
	return out

## The face's world-space normal (room side — the face the user clicked).
static func face_world_normal(mesh: PBMesh, face: int) -> Vector3:
	if mesh == null or mesh.pb_mesh_data == null:
		return Vector3.ZERO
	if face < 0 or face >= mesh.pb_mesh_data.faces.size():
		return Vector3.ZERO
	var xf: Transform3D = mesh.global_transform if mesh.is_inside_tree() else mesh.transform
	var n := PBMath.normal_from_positions(
		mesh.pb_mesh_data.positions, mesh.pb_mesh_data.faces[face].get_indexes())
	return (xf.basis * n).normalized()

## Horizontal cross-sections of a (possibly concave) wall polygon at
## `base_y`. Each output Dictionary: {"a", "b", "dir"} (a→b unit horizontal).
## A doorway cut through the wall shows up as multiple segments — the run
## breaks at the jambs. Returns [] when the polygon never crosses base_y.
static func run_segments_at_height(poly: PackedVector3Array, base_y: float) -> Array:
	var out: Array = []
	var n := poly.size()
	if n < 3:
		return out
	var xs: Array = []
	for i in range(n):
		var p0: Vector3 = poly[i]
		var p1: Vector3 = poly[(i + 1) % n]
		if (p0.y > base_y) == (p1.y > base_y):
			continue
		var t: float = (base_y - p0.y) / (p1.y - p0.y)
		xs.append(p0.lerp(p1, t))
	for i in range(0, xs.size() - 1, 2):
		var a: Vector3 = xs[i]
		var b: Vector3 = xs[i + 1]
		if a.distance_to(b) < JOINT_TOLERANCE:
			continue
		out.append({"a": a, "b": b, "dir": (b - a).normalized()})
	# Longest first, so a complex section keeps its main run primary.
	out.sort_custom(func(x, y):
		return (x["a"] as Vector3).distance_to(x["b"]) > (y["a"] as Vector3).distance_to(y["b"]))
	return out

## Merges colinear overlapping runs — two wall cubes in a line carry trim on
## their VISIBLE run only, never doubled up.
static func merge_colinear(segments: Array) -> Array:
	var normalized: Array = []
	for s in segments:
		var dir: Vector3 = s["dir"]
		var a: Vector3 = s["a"]
		var b: Vector3 = s["b"]
		if dir.dot(b - a) < 0.0:
			dir = -dir
			var t: Vector3 = a
			a = b
			b = t
		normalized.append({"a": a, "b": b, "dir": dir})
	var used: Array = []
	for i in range(normalized.size()):
		used.append(false)
	var out: Array = []
	for i in range(normalized.size()):
		if used[i]:
			continue
		used[i] = true
		var run_a: Vector3 = normalized[i]["a"]
		var run_b: Vector3 = normalized[i]["b"]
		var dir: Vector3 = normalized[i]["dir"]
		var lo := 0.0
		var hi := dir.dot(run_b - run_a)
		for j in range(i + 1, normalized.size()):
			if used[j]:
				continue
			var o: Dictionary = normalized[j]
			if o["dir"].dot(dir) < 0.9999:
				continue
			var o_perp: Vector3 = (o["a"] as Vector3) - run_a
			if o_perp.length() - absf(o_perp.dot(dir)) > JOINT_TOLERANCE:
				continue
			var lo1: float = dir.dot(o["a"] - run_a)
			var hi1: float = dir.dot(o["b"] - run_a)
			if hi1 < lo - JOINT_TOLERANCE or lo1 > hi + JOINT_TOLERANCE:
				continue
			lo = minf(lo, lo1)
			hi = maxf(hi, hi1)
			run_a = run_a + dir * lo
			run_b = run_a + dir * (hi - lo)
			used[j] = true
		out.append({"a": run_a, "b": run_b, "dir": dir, "y": normalized[i].get("y", 0.0)})
	return out

## Builds the full trim mesh data for the current walls (null when nothing
## usable is chosen — floors/ceilings don't count as walls).
func build(floor_probe := Callable(), ceiling_probe := Callable()) -> PBMeshData:
	last_paths.clear()
	if walls.is_empty():
		return null

	# 1. World runs: every chosen face's horizontal cross-section at its base
	# height, oriented so that UP × run points into the room.
	var segments: Array = []
	for w in walls:
		var mesh: PBMesh = w["mesh"]
		var face: int = int(w["face"])
		var poly := face_world_polygon(mesh, face)
		if poly.size() < 3:
			continue
		var normal: Vector3 = w.get("normal", Vector3.ZERO)
		if normal.length_squared() < 0.5:
			normal = face_world_normal(mesh, face)
		if absf(normal.dot(Vector3.UP)) > 0.7:
			continue  # not a wall (a floor/ceiling face was clicked)
		var base_y := _base_height_for(poly, normal, floor_probe, ceiling_probe)
		for seg in run_segments_at_height(poly, base_y):
			var dir: Vector3 = seg["dir"]
			var room_dir: Vector3 = normal.cross(Vector3.UP).normalized()
			if dir.dot(room_dir) < 0.0:
				var t: Vector3 = seg["a"]
				seg["a"] = seg["b"]
				seg["b"] = t
				seg["dir"] = -dir
			seg["y"] = base_y
			segments.append(seg)
	if segments.is_empty():
		return null

	# 2. Visible-run rule: colinear overlaps merge before chaining.
	var merged := merge_colinear(segments)

	# 3. Chain + mitre.
	var paths := _chain_and_mitre(merged)

	# 4. Sweep every chain into ONE PBMeshData.
	var out: PBMeshData = null
	for path_info in paths:
		var pts: PackedVector3Array = path_info["points"]
		if pts.size() < 2:
			continue
		last_paths.append({"points": pts, "closed": path_info["closed"]})
		var swept: PBMeshData = _sweep_path(pts, bool(path_info["closed"]))
		if swept == null:
			continue
		if out == null:
			out = swept
		else:
			_append_data(out, swept)
	return out

## Placement height for one wall face: Bottom probes the room floor under the
## run (a wall cube reaching below the slab still gets its skirting ON the
## slab); Top probes the ceiling and hangs the strip under it. Offset slides
## the result up or down. Probes are optional; the face's own edges are the
## fallback.
func _base_height_for(poly: PackedVector3Array, normal: Vector3,
		floor_probe: Callable, ceiling_probe: Callable) -> float:
	var lo := INF
	var hi := -INF
	var mid_sum := Vector3.ZERO
	for p in poly:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
		mid_sum += p
	var mid: Vector3 = mid_sum / float(poly.size()) + normal * 0.05
	var height := maxf(0.02, float(params.get("height", 0.1)))
	var offset := float(params.get("offset", 0.0))
	var base_y: float
	if float(params.get("top", 0.0)) > 0.5:
		var top_y := hi
		if ceiling_probe.is_valid():
			var found: float = ceiling_probe.call(mid - Vector3.UP * 0.05)
			if not is_nan(found):
				top_y = minf(top_y, found)
		base_y = top_y - height
	else:
		base_y = lo
		if floor_probe.is_valid():
			var found: float = floor_probe.call(mid + Vector3.UP * 0.05)
			if not is_nan(found):
				base_y = maxf(base_y, found)
	return base_y + offset

## Sweeps the trim profile along one mitred path (already at its base height,
## run-oriented into the room).
func _sweep_path(pts: PackedVector3Array, closed: bool) -> PBMeshData:
	var profile := PBShapeTrim.get_profile_points(
		int(params.get("profile", 1.0)) as PBShapeTrim.ProfileType,
		maxf(0.005, float(params.get("depth", 0.05))),
		maxf(0.01, float(params.get("height", 0.1))),
		int(params.get("arc_segments", 4.0)),
		float(params.get("upside_down", 0.0)) > 0.5,
		false)
	var md := PBShapeTrim.extrude_profile_along_path(profile, pts, Vector3.UP, closed, true)
	if md != null and float(params.get("smooth", 1.0)) > 0.5:
		for f in md.faces:
			f.smoothing_group = 1
		md.calculate_normals()
	if md != null and md.materials.is_empty():
		var def := PBMeshData.get_default_material()
		if def != null:
			md.materials.append(def)
	return md

## Appends `extra`'s geometry into `base` (one object out of many chains).
static func _append_data(base: PBMeshData, extra: PBMeshData) -> void:
	var offset := base.positions.size()
	for p in extra.positions:
		base.positions.append(p)
	if extra.textures0.size() == extra.positions.size():
		for uv in extra.textures0:
			base.textures0.append(uv)
	else:
		for i in range(extra.positions.size()):
			base.textures0.append(Vector2.ZERO)
	for face in extra.faces:
		if face == null:
			continue
		var clone := face.duplicate_face()
		var shifted := PackedInt32Array()
		for idx in clone.get_indexes():
			shifted.append(idx + offset)
		clone.set_indexes(shifted)
		clone.invalidate_cache()
		base.faces.append(clone)
	base.invalidate_caches()
	base.rebuild_welds()
	base.calculate_normals()
	base.shape_edited = true

# ── Chaining & mitres ────────────────────────────────────────────────────────

## Greedy head-to-tail chaining with mitred corners. Runs only chain when
## their endpoints are within CHAIN_REACH; the corner is the supporting
## lines' intersection (bounded), so any angle gets a clean mitre. A chain
## whose start meets its end closes into a ring. Consecutive runs of a chain
## must be head-to-tail oriented — build() guarantees that (run direction =
## room normal × UP circulates around a room).
static func _chain_and_mitre(segments: Array) -> Array[Dictionary]:
	var paths: Array[Dictionary] = []
	var remaining: Array = []
	for s in segments:
		remaining.append(s.duplicate())
	while not remaining.is_empty():
		var chain: Array = [remaining.pop_front()]
		var grew := true
		while grew:
			grew = false
			for k in range(remaining.size()):
				var cand: Dictionary = remaining[k]
				var tail: Dictionary = chain[chain.size() - 1]
				var head: Dictionary = chain[0]
				var join_t := _mitre_join(tail, cand)
				if not join_t.is_empty():
					tail["mitred_end"] = join_t["corner"]
					cand["mitred_start"] = join_t["corner"]
					chain.append(cand)
					remaining.remove_at(k)
					grew = true
					break
				var join_h := _mitre_join(cand, head)
				if not join_h.is_empty():
					cand["mitred_end"] = join_h["corner"]
					head["mitred_start"] = join_h["corner"]
					chain.push_front(cand)
					remaining.remove_at(k)
					grew = true
					break
		var pts := PackedVector3Array()
		var first: Dictionary = chain[0]
		var last: Dictionary = chain[chain.size() - 1]
		pts.append(first.get("mitred_start", first["a"]))
		for i in range(chain.size() - 1):
			pts.append(chain[i].get("mitred_end", chain[i]["b"]))
		pts.append(last.get("mitred_end", last["b"]))
		var closed: bool = pts[0].distance_to(pts[pts.size() - 1]) <= JOINT_TOLERANCE
		if closed:
			pts[pts.size() - 1] = pts[0]
		paths.append({"points": pts, "closed": closed})
	return paths

## Head-to-tail join between `seg`'s end and `next_seg`'s start: the corner
## is the two supporting lines' intersection (XZ), height-averaged, bounded
## by the segment lengths and CHAIN_REACH. Parallel runs butt-join only when
## their endpoints actually touch. Returns {"corner": Vector3} or {}.
static func _mitre_join(seg: Dictionary, next_seg: Dictionary) -> Dictionary:
	var a: Vector3 = seg["b"]
	var b: Vector3 = next_seg["a"]
	var d1: Vector3 = seg["dir"]
	var d2: Vector3 = next_seg["dir"]
	var flat_gap := Vector2(b.x - a.x, b.z - a.z).length()
	if flat_gap > CHAIN_REACH:
		return {}
	var denom: float = d1.x * d2.z - d1.z * d2.x
	if absf(denom) < 0.0001:
		# Parallel (colinear runs were merged; side-by-side walls butt only
		# when the endpoints really touch).
		if flat_gap <= JOINT_TOLERANCE:
			return {"corner": Vector3(b.x, (float(seg.get("y", 0.0)) + float(next_seg.get("y", 0.0))) * 0.5, b.z)}
		return {}
	var t: float = ((b.x - a.x) * d2.z - (b.z - a.z) * d2.x) / denom
	var corner := a + d1 * t
	var len1: float = (seg["a"] as Vector3).distance_to(a)
	var len2: float = b.distance_to(next_seg["b"] as Vector3)
	if corner.distance_to(a) > MAX_MITRE_FACTOR * maxf(len1, CHAIN_REACH) \
			or corner.distance_to(b) > MAX_MITRE_FACTOR * maxf(len2, CHAIN_REACH):
		return {}
	corner.y = (float(seg.get("y", 0.0)) + float(next_seg.get("y", 0.0))) * 0.5
	return {"corner": corner}
