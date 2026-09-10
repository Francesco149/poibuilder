## PBLightBaker — Bakes direct lighting, shadows, and ambient occlusion into vertex colors.
##
## Used by the retro export pipeline to provide rich lighting and contact shadows
## without dynamic GPU lighting passes. Works with DirectionalLight3D, OmniLight3D,
## SpotLight3D, and ambient light. Evaluates billboards based on their 'lit' property.
@tool
class_name PBLightBaker
extends RefCounted

## Golden angle in radians for Fibonacci hemisphere sampling.
const GOLDEN_ANGLE := 2.399963229728653

## Triangle with AABB for spatial acceleration.
class Tri:
	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var aabb: AABB

	func _init(p0: Vector3, p1: Vector3, p2: Vector3) -> void:
		v0 = p0
		v1 = p1
		v2 = p2
		var min_p := Vector3(minf(p0.x, minf(p1.x, p2.x)), minf(p0.y, minf(p1.y, p2.y)), minf(p0.z, minf(p1.z, p2.z)))
		var max_p := Vector3(maxf(p0.x, maxf(p1.x, p2.x)), maxf(p0.y, maxf(p1.y, p2.y)), maxf(p0.z, maxf(p1.z, p2.z)))
		aabb = AABB(min_p, max_p - min_p)

## Spatial grid acceleration structure for fast ray queries.
class SpatialGrid:
	var cell_size: float = 2.0
	var inv_cell: float = 0.5
	var cells: Dictionary = {} # Vector3i -> Array[Tri]
	var all_triangles: Array[Tri] = []
	var scene_aabb := AABB()
	var has_aabb: bool = false

	func _init(p_cell_size: float = 2.0) -> void:
		cell_size = p_cell_size
		inv_cell = 1.0 / p_cell_size

	func add_triangle(p0: Vector3, p1: Vector3, p2: Vector3) -> void:
		var tri := Tri.new(p0, p1, p2)
		all_triangles.append(tri)
		if not has_aabb:
			scene_aabb = tri.aabb
			has_aabb = true
		else:
			scene_aabb = scene_aabb.merge(tri.aabb)

		var min_c := Vector3i(int(floor(tri.aabb.position.x * inv_cell)), int(floor(tri.aabb.position.y * inv_cell)), int(floor(tri.aabb.position.z * inv_cell)))
		var max_c := Vector3i(int(floor((tri.aabb.position.x + tri.aabb.size.x) * inv_cell)), int(floor((tri.aabb.position.y + tri.aabb.size.y) * inv_cell)), int(floor((tri.aabb.position.z + tri.aabb.size.z) * inv_cell)))

		for cz in range(min_c.z, max_c.z + 1):
			for cy in range(min_c.y, max_c.y + 1):
				for cx in range(min_c.x, max_c.x + 1):
					var key := Vector3i(cx, cy, cz)
					if not cells.has(key):
						cells[key] = [] as Array[Tri]
					cells[key].append(tri)

	func cast_ray(origin: Vector3, dir: Vector3, max_dist: float, early_exit: bool = false) -> float:
		if all_triangles.is_empty():
			return max_dist

		var dir_norm := dir.normalized()
		var ray_len := max_dist

		# Fast rejection against scene bounds
		if has_aabb:
			var exp_aabb := scene_aabb.grow(0.1)
			if not exp_aabb.has_point(origin):
				var enter_pt = exp_aabb.intersects_segment(origin, origin + dir_norm * ray_len)
				if enter_pt == null:
					return max_dist
			else:
				var exit_d := _ray_box_exit(origin, dir_norm, exp_aabb, ray_len)
				ray_len = minf(ray_len, exit_d)

		var cur_cell := Vector3i(int(floor(origin.x * inv_cell)), int(floor(origin.y * inv_cell)), int(floor(origin.z * inv_cell)))
		var step_x := 1 if dir_norm.x >= 0.0 else -1
		var step_y := 1 if dir_norm.y >= 0.0 else -1
		var step_z := 1 if dir_norm.z >= 0.0 else -1

		var t_delta_x := absf(cell_size / dir_norm.x) if absf(dir_norm.x) > 0.000001 else INF
		var t_delta_y := absf(cell_size / dir_norm.y) if absf(dir_norm.y) > 0.000001 else INF
		var t_delta_z := absf(cell_size / dir_norm.z) if absf(dir_norm.z) > 0.000001 else INF

		var next_bx := float(cur_cell.x + (1 if step_x > 0 else 0)) * cell_size
		var next_by := float(cur_cell.y + (1 if step_y > 0 else 0)) * cell_size
		var next_bz := float(cur_cell.z + (1 if step_z > 0 else 0)) * cell_size

		var t_max_x := absf((next_bx - origin.x) / dir_norm.x) if absf(dir_norm.x) > 0.000001 else INF
		var t_max_y := absf((next_by - origin.y) / dir_norm.y) if absf(dir_norm.y) > 0.000001 else INF
		var t_max_z := absf((next_bz - origin.z) / dir_norm.z) if absf(dir_norm.z) > 0.000001 else INF
		var closest_d := max_dist
		var seen := {}

		while true:
			if cells.has(cur_cell):
				var tri_list: Array = cells[cur_cell]
				for tri: Tri in tri_list:
					if seen.has(tri):
						continue
					seen[tri] = true

					var hit: Dictionary = PBMath.ray_intersects_triangle(origin, dir_norm, tri.v0, tri.v1, tri.v2)
					if hit.get("hit", false):
						var d: float = hit.get("distance", INF)
						if d > 0.001 and d < closest_d:
							if early_exit:
								return d
							closest_d = d

			var t_next := minf(t_max_x, minf(t_max_y, t_max_z))
			if closest_d <= t_next or t_next > ray_len:
				break

			if t_max_x < t_max_y:
				if t_max_x < t_max_z:
					cur_cell.x += step_x
					t_max_x += t_delta_x
				else:
					cur_cell.z += step_z
					t_max_z += t_delta_z
			else:
				if t_max_y < t_max_z:
					cur_cell.y += step_y
					t_max_y += t_delta_y
				else:
					cur_cell.z += step_z
					t_max_z += t_delta_z

		return closest_d

	func _ray_box_exit(orig: Vector3, d_norm: Vector3, aabb: AABB, fallback: float) -> float:
		var t_exit := fallback
		if absf(d_norm.x) > 0.000001:
			var bound_x := aabb.position.x + aabb.size.x if d_norm.x > 0.0 else aabb.position.x
			var tx := (bound_x - orig.x) / d_norm.x
			if tx > 0.0001:
				t_exit = minf(t_exit, tx)
		if absf(d_norm.y) > 0.000001:
			var bound_y := aabb.position.y + aabb.size.y if d_norm.y > 0.0 else aabb.position.y
			var ty := (bound_y - orig.y) / d_norm.y
			if ty > 0.0001:
				t_exit = minf(t_exit, ty)
		if absf(d_norm.z) > 0.000001:
			var bound_z := aabb.position.z + aabb.size.z if d_norm.z > 0.0 else aabb.position.z
			var tz := (bound_z - orig.z) / d_norm.z
			if tz > 0.0001:
				t_exit = minf(t_exit, tz)
		return t_exit
# Public API
# ==============================================================================

## Collects all Light3D nodes in the given scene branch.
static func collect_scene_lights(root: Node) -> Array[Light3D]:
	var lights: Array[Light3D] = []
	_find_lights_recursive(root, lights)
	return lights

## Builds a SpatialGrid containing all solid triangles in the scene.
static func build_spatial_grid(root: Node) -> SpatialGrid:
	var grid := SpatialGrid.new(2.0)
	_collect_triangles_recursive(root, grid)
	return grid

## Bakes vertex colors for a set of vertices given their positions, normals, and world transform.
static func bake_vertex_colors(positions: PackedVector3Array, normals: PackedVector3Array,
		world_transform: Transform3D, lights: Array[Light3D], grid: SpatialGrid,
		bake_lighting: bool = true, bake_shadows: bool = true, bake_ao: bool = true,
		ao_samples: int = 16, ao_distance: float = 1.5, ao_intensity: float = 0.7,
		ambient_color: Color = Color(0.22, 0.22, 0.26)) -> PackedColorArray:
	var count := positions.size()
	var out := PackedColorArray()
	out.resize(count)

	# If lighting bake is disabled, return solid white
	if not bake_lighting:
		for i in range(count):
			out[i] = Color.WHITE
		return out

	for i in range(count):
		var p_world: Vector3 = world_transform * positions[i]
		var n_world: Vector3 = (world_transform.basis * normals[i]).normalized()
		if n_world.length_squared() < 0.0001:
			n_world = Vector3.UP

		# Step 1: Ambient Occlusion
		var ao_factor := 1.0
		if bake_ao and grid != null:
			ao_factor = _calculate_ao(p_world, n_world, grid, ao_samples, ao_distance, ao_intensity)

		# Step 2: Hemispheric Ambient Light
		var sky_bounce := clampf(n_world.y * 0.5 + 0.5, 0.0, 1.0)
		var ambient := ambient_color * lerpf(0.7, 1.1, sky_bounce) * ao_factor

		# Step 3: Direct Lights (Directional, Omni, Spot)
		var direct := Color.BLACK
		for light in lights:
			if light == null or not light.visible or (light.is_inside_tree() and not light.is_visible_in_tree()):
				continue
			var light_col := _evaluate_light(p_world, n_world, light, grid, bake_shadows)
			direct += light_col

		# Final color = ambient + direct
		var final_col := ambient + direct
		# Preserve chromaticity / light hue when combined light exceeds 1.0
		var max_comp := maxf(final_col.r, maxf(final_col.g, final_col.b))
		if max_comp > 1.0:
			var mapped_max := max_comp / (1.0 + max_comp * 0.35)
			final_col = final_col * (mapped_max / max_comp)
		out[i] = Color(clampf(final_col.r, 0.0, 1.0), clampf(final_col.g, 0.0, 1.0), clampf(final_col.b, 0.0, 1.0), 1.0)
	return out

## Bakes vertex colors for a billboard (sprite) node.
## If is_lit is true, computes ambient + direct light at billboard position.
## If is_lit is false, returns Color.WHITE (unshaded).
static func bake_billboard_colors(node: Node, lights: Array[Light3D], grid: SpatialGrid,
		bake_lighting: bool = true, bake_shadows: bool = true,
		ambient_color: Color = Color(0.22, 0.22, 0.26)) -> PackedColorArray:
	var out := PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	if not bake_lighting or node == null:
		return out
	# Check if billboard is lit
	var is_lit := _is_billboard_lit(node)
	if not is_lit:
		return out

	var pos := _get_world_transform(node as Node3D).origin if node is Node3D else Vector3.ZERO
	# Use an upward-angled normal for omnidirectional diffuse billboard lighting
	var normal := Vector3(0.0, 0.7071, 0.7071).normalized()

	var ambient := ambient_color
	var direct := Color.BLACK
	for light in lights:
		if light == null or not light.visible or (light.is_inside_tree() and not light.is_visible_in_tree()):
			continue
		direct += _evaluate_light(pos, normal, light, grid, bake_shadows)

	var final_col := ambient + direct
	var col := Color(clampf(final_col.r, 0.0, 1.0), clampf(final_col.g, 0.0, 1.0), clampf(final_col.b, 0.0, 1.0), 1.0)
	for i in range(4):
		out[i] = col
	return out

# ==============================================================================
# Internal Lighting Calculations
# ==============================================================================

static func _evaluate_light(p: Vector3, n: Vector3, light: Light3D, grid: SpatialGrid,
		bake_shadows: bool) -> Color:
	var l_xf := _get_world_transform(light)
	var l_color: Color = light.light_color * light.light_energy

	if light is DirectionalLight3D:
		var to_light := l_xf.basis.z.normalized()
		var n_dot_l := n.dot(to_light)
		if n_dot_l <= 0.0:
			return Color.BLACK

		if bake_shadows and grid != null:
			var hit_dist := grid.cast_ray(p + n * 0.05, to_light, 100.0, true)
			if hit_dist < 99.0:
				return Color.BLACK # Occluded

		return l_color * n_dot_l

	elif light is OmniLight3D:
		var o_light := light as OmniLight3D
		var light_pos := l_xf.origin
		var to_light := light_pos - p
		var dist := to_light.length()
		var r := o_light.omni_range
		if dist > r or dist < 0.001:
			return Color.BLACK

		var l_dir := to_light / dist
		var n_dot_l := n.dot(l_dir)
		if n_dot_l <= 0.0:
			return Color.BLACK

		# Spot light cone angle
		if light is SpotLight3D:
			var s_light := light as SpotLight3D
			var spot_fwd := -l_xf.basis.z.normalized()
			var spot_cos := (-l_dir).dot(spot_fwd)
			var angle_rad := deg_to_rad(s_light.spot_angle)
			var cutoff := cos(angle_rad)
			if spot_cos < cutoff:
				return Color.BLACK
			var cone_factor := clampf((spot_cos - cutoff) / maxf(1.0 - cutoff, 0.0001), 0.0, 1.0)
			l_color *= pow(cone_factor, s_light.spot_attenuation)

		# Distance attenuation
		var norm_d := clampf(dist / r, 0.0, 1.0)
		var att := pow(1.0 - norm_d, o_light.omni_attenuation)

		# Shadow test
		if bake_shadows and grid != null:
			var hit_dist := grid.cast_ray(p + n * 0.02, l_dir, dist - 0.03, true)
			if hit_dist < dist - 0.04:
				return Color.BLACK # Occluded

		return l_color * (att * n_dot_l)

	return Color.BLACK

static func _calculate_ao(p: Vector3, n: Vector3, grid: SpatialGrid,
		samples: int, max_dist: float, intensity: float) -> float:
	if samples <= 0 or grid == null:
		return 1.0

	# Orthonormal basis (tangent, bitangent, normal)
	var t: Vector3 = Vector3.UP.cross(n).normalized()
	if t.length_squared() < 0.0001:
		t = Vector3.RIGHT.cross(n).normalized()
	var b: Vector3 = n.cross(t).normalized()

	var total_occlusion := 0.0
	for i in range(samples):
		# Fibonacci hemisphere sampling
		var z := (float(i) + 0.5) / float(samples)
		var r := sqrt(maxf(0.0, 1.0 - z * z))
		var phi := float(i) * GOLDEN_ANGLE
		var x := r * cos(phi)
		var y := r * sin(phi)

		var ray_dir := (x * t + y * b + z * n).normalized()
		var hit_d := grid.cast_ray(p + n * 0.02, ray_dir, max_dist)
		if hit_d < max_dist:
			var occ := 1.0 - (hit_d / max_dist)
			total_occlusion += occ

	var avg_occ := total_occlusion / float(samples)
	return 1.0 - clampf(avg_occ * intensity, 0.0, 1.0)

# ==============================================================================
# Helper Methods
# ==============================================================================

static func _find_lights_recursive(node: Node, out: Array[Light3D]) -> void:
	if node == null:
		return
	if node is Light3D:
		out.append(node as Light3D)
	for child in node.get_children():
		_find_lights_recursive(child, out)

static func _collect_triangles_recursive(node: Node, grid: SpatialGrid) -> void:
	if node == null:
		return

	# Skip collision shapes, stamps container, billboards, transparent sprites, and hidden nodes
	if node.name == "PBStamps" or node.name.begins_with("Collider") or node is CollisionShape3D:
		return
	if node.has_meta("is_billboard") or node.name.begins_with("Sprite") or node.name.begins_with("Tree") or node.name.begins_with("Bush") or node.name.begins_with("Wildflower"):
		return
	if node is MeshInstance3D and (node as MeshInstance3D).material_override is StandardMaterial3D:
		var sm := (node as MeshInstance3D).material_override as StandardMaterial3D
		if sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return
	if node is Node3D and not (node as Node3D).visible:
		return

	if node is PBMesh and (node as PBMesh).pb_mesh_data != null:
		var pb := node as PBMesh
		var xf := _get_world_transform(pb)
		var md := pb.pb_mesh_data
		for face in md.faces:
			if face != null:
				var fi := face.get_indexes()
				for i in range(0, fi.size() - 2, 3):
					var p0: Vector3 = xf * md.positions[fi[i]]
					var p1: Vector3 = xf * md.positions[fi[i + 1]]
					var p2: Vector3 = xf * md.positions[fi[i + 2]]
					grid.add_triangle(p0, p1, p2)
	elif node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var m := mi.mesh
		if m != null:
			var xf := _get_world_transform(mi)
			for s in range(m.get_surface_count()):
				var arrays := m.surface_get_arrays(s)
				if arrays.size() > Mesh.ARRAY_VERTEX:
					var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX else PackedInt32Array()

					if not indices.is_empty():
						for i in range(0, indices.size() - 2, 3):
							var p0: Vector3 = xf * verts[indices[i]]
							var p1: Vector3 = xf * verts[indices[i + 1]]
							var p2: Vector3 = xf * verts[indices[i + 2]]
							grid.add_triangle(p0, p1, p2)
					elif not verts.is_empty():
						for i in range(0, verts.size() - 2, 3):
							var p0: Vector3 = xf * verts[i]
							var p1: Vector3 = xf * verts[i + 1]
							var p2: Vector3 = xf * verts[i + 2]
							grid.add_triangle(p0, p1, p2)

	for child in node.get_children():
		_collect_triangles_recursive(child, grid)

static func _get_world_transform(node: Node3D) -> Transform3D:
	if node == null:
		return Transform3D.IDENTITY
	if node.is_inside_tree():
		return node.global_transform
	var xf := node.transform
	var p := node.get_parent()
	while p != null and p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf

static func _is_billboard_lit(node: Node) -> bool:
	if node == null:
		return false
	if node.has_meta("is_lit"):
		return bool(node.get_meta("is_lit"))
	if node is PBMesh:
		var pb := node as PBMesh
		if pb.pb_mesh_data != null and pb.pb_mesh_data.shape_params.has("lit"):
			return bool(pb.pb_mesh_data.shape_params["lit"])
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mat := mi.material_override
		if mat is StandardMaterial3D:
			return (mat as StandardMaterial3D).shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED
	return false
