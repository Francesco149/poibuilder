## PBColliderAudit — static integrity audit for generated physics colliders.
##
## Headless-safe (no editor classes). Built after the curved-stairs ramp bug
## (v0.9.28): the wedge was wound inward, so ConcavePolygonShape3D's one-sided
## collision let characters walk INTO the shell and then trapped them. Existing
## tests only asserted "collided", which passes for inverted shells — these
## checks measure the collider's actual geometry and physics behavior instead.
##
## Conventions: Godot physics collides with the FRONT of a concave triangle
## (the side the winding normal points out of, (a-c)x(a-b)); for a closed
## solid every front must face EXTERIOR. signed_volume() is negative for a
## shell wound that way (CW-from-outside under the right-hand rule).
@tool
class_name PBColliderAudit
extends RefCounted

## Right-hand-rule signed volume of the triangle soup (sum of
## dot(a, cross(b-a, c-a))/6). NEGATIVE for a correctly wound Godot shell
## (CW-from-outside), positive when globally inverted. Magnitude is the
## enclosed volume, so it also catches grossly misplaced faces.
static func signed_volume(faces: PackedVector3Array) -> float:
	var vol := 0.0
	for i in range(0, faces.size() - 2, 3):
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		vol += a.dot((b - a).cross(c - a)) / 6.0
	return vol

## Geometric front normal of one triangle (Godot convention): points out of
## the collidable FRONT side. Zero vector for degenerate triangles.
static func tri_front_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (a - c).cross(a - b)
	if n.length_squared() < 1e-14:
		return Vector3.ZERO
	return n.normalized()

## Edge pairing report for a closed-shell check. A consistently wound closed
## shell has every directed edge matched by its exact reverse from the
## neighboring face. `open` edges have no reverse (shell boundary — expected
## only for intentionally open colliders like a sides=false ramp sheet);
## `conflicts` are same-direction duplicates (locally inconsistent winding or
## doubled faces). Positions are quantized to 1e-4, matching
## PBShapeComplex._build_shared_vertices tolerance.
static func edge_pairing_report(faces: PackedVector3Array) -> Dictionary:
	var directed := {} # "ax,ay,az>bx,by,bz" -> count
	for i in range(0, faces.size() - 2, 3):
		for e in range(3):
			var p: Vector3 = faces[i + e]
			var q: Vector3 = faces[i + (e + 1) % 3]
			var key := _edge_key(p, q)
			directed[key] = int(directed.get(key, 0)) + 1
	var open_edges: Array = []
	var conflicts: Array = []
	for key_v in directed:
		var key: String = key_v
		# Reverse key = swap the two endpoint groups — pure string surgery,
		# NEVER re-quantize parsed floats (double-rounding breaks matching).
		var halves := key.split(">")
		var rev := halves[1] + ">" + halves[0]
		if not directed.has(rev):
			open_edges.append(key)
		elif int(directed[key]) > 1:
			conflicts.append(key)
	return {
		"total_unique_directed": directed.size(),
		"open": open_edges,
		"conflicts": conflicts,
	}

## Generalized winding number of the triangle soup at point p: the solid-angle
## sum over all triangles, divided by 4*pi. For a CLOSED shell it is ~0 for
## outside points and ~+/-1 for inside points (magnitude, regardless of which
## side the fronts face). O(N) per query; typical audit cost O(N^2) over a
## collider's own faces — trivial at collider triangle counts.
static func winding_number(faces: PackedVector3Array, p: Vector3) -> float:
	var w := 0.0
	for i in range(0, faces.size() - 2, 3):
		var a := faces[i] - p
		var b := faces[i + 1] - p
		var c := faces[i + 2] - p
		var la := a.length()
		var lb := b.length()
		var lc := c.length()
		if la < 1e-9 or lb < 1e-9 or lc < 1e-9:
			continue # p sits on a vertex; caller offsets off-surface
		var denom := la * lb * lc + a.dot(b) * lc + a.dot(c) * lb + b.dot(c) * la
		w += 2.0 * atan2(a.dot(b.cross(c)), denom)
	return w / (4.0 * PI)

## Per-face front-exterior audit for CLOSED shells (pure math — no physics
## server needed, so it can run on factory output before a scene exists).
## For each face, compare the winding number slightly in FRONT of the face
## (wa) and slightly BEHIND it (wb): a correctly wound face separating
## exterior from interior has |wa| ~ 0 outside and |wb| ~ 1 inside; an inverted
## face swaps them. Robust for any closed, consistently-wound-elsewhere shell,
## including concavities and holes — unlike ray probes, nothing can hide.
## Returns failures with per-face detail. Skip open shells (w is not 0/1 there;
## see edge_pairing_report to verify closure first).
##
## SLIVER-EXEMPTION: faces whose inradius is below ~1% of the shell diagonal
## (e.g. the vertical sheets around a pie stair's 5cm pole hole) are reported
## separately under "slivers", NOT failures: their facet planes curve away
## under the probe epsilon, so the winding number cannot classify them. That
## is SOUND — in a closed shell a reversed sliver shares every edge with
## correctly-wound neighbors in the SAME direction, which edge_pairing_report
## flags as a conflict. Slivers are thus orientation-covered by closure +
## consistency; this audit covers the rest.
static func front_exterior_report(faces: PackedVector3Array) -> Dictionary:
	var aabb := AABB()
	for p in faces:
		aabb = aabb.expand(p)
	var diag: float = aabb.size.length()
	var eps: float = maxf(0.002, diag * 0.002)
	var sliver_limit: float = maxf(0.005, diag * 0.01)

	var failures: Array[Dictionary] = []
	var slivers: Array[int] = []
	var degenerate: Array[int] = []
	var tri_count := 0
	for i in range(0, faces.size() - 2, 3):
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		var n := tri_front_normal(a, b, c)
		var tri_idx := i / 3
		if n == Vector3.ZERO:
			degenerate.append(tri_idx)
			continue
		tri_count += 1
		var centroid := (a + b + c) / 3.0
		# Per-face epsilon: never probe farther than ~the face's own inradius,
		# or narrow slivers (e.g. the pole-hole inner wall on pie stairs) read
		# as false inversions.
		var perim: float = (b - a).length() + (c - b).length() + (a - c).length()
		var area2: float = (b - a).cross(c - a).length() # 2x area
		var inradius: float = area2 / maxf(perim, 1e-9)
		if inradius < sliver_limit:
			slivers.append(tri_idx)
			continue
		var eps_f: float = minf(eps, inradius * 0.4)
		var wa := winding_number(faces, centroid + n * eps_f)
		var wb := winding_number(faces, centroid - n * eps_f)
		# Correct: front side outside (|wa| -> 0), back side inside (|wb| -> 1).
		# Margins are loose: the jump across a face is exactly 1 in the limit,
		# and distant-face contributions decay smoothly.
		if absf(wa) > 0.35 or absf(wb) < 0.65:
			failures.append({
				"tri": tri_idx,
				"centroid": centroid,
				"normal": n,
				"w_front": wa,
				"w_back": wb,
			})
	return {
		"triangles": tri_count,
		"degenerate": degenerate,
		"slivers": slivers,
		"failures": failures,
	}

## NOTE on walkability: there is NO sound facet-slope cap for a tessellated
## helicoidal ramp — facets containing the short inner chord have a structural
## gradient >= the design slope at the inner radius no matter how fine the
## tessellation, and crease direction (not facet slope) decides whether a
## character wedges. Character climb/containment tests in
## test_pb_collider_audit.gd are the behavioral regression lock for that.

## Extracts the audit triangle soup from a collider shape: the raw faces for
## ConcavePolygonShape3D (winding as the physics server sees them), the debug
## mesh surface for anything else (convex/box/sphere debug meshes are already
## outward-wound; convex shapes are volumetric so winding is cosmetic anyway).
## Returns an empty array for null/unhandled shapes.
static func shape_faces(shape: Shape3D) -> PackedVector3Array:
	if shape == null:
		return PackedVector3Array()
	if shape is ConcavePolygonShape3D:
		return (shape as ConcavePolygonShape3D).get_faces()
	var debug_mesh := shape.get_debug_mesh()
	if debug_mesh == null or debug_mesh.get_surface_count() == 0:
		return PackedVector3Array()
	return debug_mesh.get_faces()

static func _edge_key(a: Vector3, b: Vector3) -> String:
	return "%d,%d,%d>%d,%d,%d" % [
		int(round(a.x * 10000.0)), int(round(a.y * 10000.0)), int(round(a.z * 10000.0)),
		int(round(b.x * 10000.0)), int(round(b.y * 10000.0)), int(round(b.z * 10000.0))]
