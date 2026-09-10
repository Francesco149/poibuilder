## PBMapExporter — Exports PoiBuilder scenes to GLB for retro and modern engines.
##
## Primary workflow: Retro Engine Export (Fully Baked Map):
## - Faces subdivided into triangulated quads aligned to the texture tiling grid.
## - Lighting (direct, shadows, and AO) baked into vertex colors.
## - Billboards affected by vertex lighting if marked 'lit'.
## - Texture splatting and stamps baked into discrete tile textures (tile-map style:
##   painted tiles generate unique textures, unpainted tiles reuse the base texture).
##
## Modern Engine Export:
## - Preserves native geometry without forced subdivision.
## - Encodes stamps and splat data as GLTF extras / metadata.
## - Names entities cleanly (e.g. Collider_* for collision meshes).
@tool
class_name PBMapExporter
extends RefCounted

## Export mode selector.
enum ExportMode {
	RETRO = 0,
	MODERN = 1,
}

const PBM_MAGIC := 0x314D4250 # "PBM1"
const PBM_VERSION := 1

const PBM_TEX_FMT_RGBA8888 := 0
const PBM_TEX_FMT_RGBA5551 := 1
## Configuration settings for map export.
class ExportSettings extends RefCounted:
	var export_mode: ExportMode = ExportMode.RETRO
	var subdivide_quads: bool = true
	var grid_size: float = 1.0
	var bake_lighting: bool = true
	var bake_shadows: bool = true
	var bake_ao: bool = true
	var ao_samples: int = 16
	var ao_distance: float = 1.5
	var ao_intensity: float = 0.4
	var ambient_color: Color = Color(0.42, 0.42, 0.46)
	var bake_textures: bool = true
	var tile_resolution: int = 128
	var max_texture_size: int = 512
	var enforce_power_of_two: bool = true
	var export_billboards: bool = true
	var export_colliders: bool = true
	var export_lights: bool = true
	var cleanup_intermediate_files: bool = true
## Cancellation token for aborting an in-progress async export.
class CancellationToken extends RefCounted:
	var cancelled: bool = false

	func cancel() -> void:
		cancelled = true

# ==============================================================================
# Public API
# ==============================================================================

## Ensures the export directory exists on disk and creates a .gdignore file
## if it is inside res:// to prevent Godot from auto-importing exported assets.
static func ensure_export_dir(file_path: String) -> void:
	var base_dir := file_path.get_base_dir()
	if base_dir.is_empty() or base_dir == "res://" or base_dir == "res:":
		return
	if not DirAccess.dir_exists_absolute(base_dir):
		DirAccess.make_dir_recursive_absolute(base_dir)
	var gdignore_path := base_dir.path_join(".gdignore")
	if not FileAccess.file_exists(gdignore_path):
		var f := FileAccess.open(gdignore_path, FileAccess.WRITE)
		if f != null:
			f.store_string("")
			f.close()

## Removes unnecessary loose intermediate texture files (e.g. extracted .png textures
## and .import files) produced during or following map export.
## Can be disabled by setting settings.cleanup_intermediate_files = false
## or environment variable POIBUILDER_KEEP_INTERMEDIATE=1 for debugging.
static func cleanup_intermediate_files(file_path: String) -> int:
	var base_dir := file_path.get_base_dir()
	var base_name := file_path.get_file().get_basename()
	var cleaned := 0
	cleaned += _cleanup_intermediate_in_dir(base_dir, base_name)
	if base_dir != "res://" and base_dir != "res:":
		cleaned += _cleanup_intermediate_in_dir("res://", base_name)
	return cleaned

static func _cleanup_intermediate_in_dir(dir_path: String, base_name: String) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	var cleaned := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	var prefix := base_name + "_"
	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			var is_intermediate := false
			if file_name.begins_with(prefix):
				if lower.ends_with(".png") or lower.ends_with(".png.import") or (lower.ends_with(".import") and not lower.ends_with(".glb.import") and not lower.ends_with(".gltf.import")):
					is_intermediate = true
			elif file_name.contains("_BakedTile_") or file_name.contains("BakedTile_"):
				if lower.ends_with(".png") or lower.ends_with(".png.import"):
					is_intermediate = true
			if is_intermediate:
				var full_path := dir_path.path_join(file_name)
				DirAccess.remove_absolute(full_path)
				cleaned += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	return cleaned

## Exports the given scene root to a .glb or .gltf file on disk synchronously.
static func export_map(root: Node, file_path: String, settings: ExportSettings = null) -> Error:
	if root == null or file_path.is_empty():
		return ERR_INVALID_PARAMETER

	if file_path.to_lower().ends_with(".pbm"):
		return export_retro_pbm(root, file_path, settings)
	if settings == null:
		settings = ExportSettings.new()

	ensure_export_dir(file_path)

	var export_tree := build_export_tree(root, settings)
	if export_tree == null:
		return ERR_CANT_CREATE

	var doc := GLTFDocument.new()
	var state := GLTFState.new()

	var err := doc.append_from_scene(export_tree, state)
	if err != OK:
		export_tree.free()
		return err

	err = doc.write_to_filesystem(state, file_path)
	export_tree.free()

	var should_cleanup: bool = settings.cleanup_intermediate_files if settings != null else true
	if OS.has_environment("POIBUILDER_KEEP_INTERMEDIATE") and OS.get_environment("POIBUILDER_KEEP_INTERMEDIATE") != "0":
		should_cleanup = false
	if should_cleanup and err == OK:
		cleanup_intermediate_files(file_path)

	return err
## Asynchronous export with frame-by-frame progress reporting and cancellation support.
## Yields frames via `await Engine.get_main_loop().process_frame` so editor UI stays 100% interactive.
static func export_map_async(root: Node, file_path: String, settings: ExportSettings = null,
		progress_cb: Callable = Callable(), cancel_token: CancellationToken = null) -> Error:
	if root == null or file_path.is_empty():
		return ERR_INVALID_PARAMETER

	if settings == null:
		settings = ExportSettings.new()

	ensure_export_dir(file_path)
	if progress_cb.is_valid():
		progress_cb.call(0.02, "Collecting scene geometry & lights...", "")
	if Engine.get_main_loop() != null:
		await Engine.get_main_loop().process_frame

	var export_root := Node3D.new()
	export_root.name = "Map"

	var lights := PBLightBaker.collect_scene_lights(root)
	var grid := PBLightBaker.build_spatial_grid(root)
	var base_material_cache: Dictionary = {}

	var nodes_to_export: Array[Node] = []
	_collect_export_nodes_recursive(root, nodes_to_export)

	var total_nodes := nodes_to_export.size()
	for ni in range(total_nodes):
		if cancel_token != null and cancel_token.cancelled:
			export_root.free()
			return ERR_SKIP

		var n := nodes_to_export[ni]
		var pct := 0.05 + (float(ni) / maxf(float(total_nodes), 1.0)) * 0.85
		if progress_cb.is_valid():
			progress_cb.call(pct, "Baking %s (%d/%d)" % [n.name, ni + 1, total_nodes], "")
		if Engine.get_main_loop() != null:
			await Engine.get_main_loop().process_frame

		_export_single_node(n, export_root, lights, grid, base_material_cache, settings)

	if cancel_token != null and cancel_token.cancelled:
		export_root.free()
		return ERR_SKIP

	# In the Godot Editor (Engine.is_editor_hint()), GLTFDocument.append_from_scene
	# skips any descendant node whose owner is null. Recursively set owner = export_root
	# so that all exported meshes, materials, and colliders are written to glTF.
	_set_owner_recursive(export_root, export_root)

	if file_path.to_lower().ends_with(".pbm"):
		if progress_cb.is_valid():
			progress_cb.call(0.92, "Writing PBM binary file to disk...", file_path.get_file())
		if Engine.get_main_loop() != null:
			await Engine.get_main_loop().process_frame
		var err := _write_pbm_from_tree(export_root, file_path, settings)
		export_root.free()
		if progress_cb.is_valid():
			progress_cb.call(1.0, "Export complete!", file_path.get_file())
		return err

	if progress_cb.is_valid():
		progress_cb.call(0.92, "Writing GLB file to disk...", file_path.get_file())
	if Engine.get_main_loop() != null:
		await Engine.get_main_loop().process_frame

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(export_root, state)
	if err != OK:
		export_root.free()
		return err

	err = doc.write_to_filesystem(state, file_path)
	export_root.free()
	var should_cleanup: bool = settings.cleanup_intermediate_files if settings != null else true
	if OS.has_environment("POIBUILDER_KEEP_INTERMEDIATE") and OS.get_environment("POIBUILDER_KEEP_INTERMEDIATE") != "0":
		should_cleanup = false
	if should_cleanup and err == OK:
		cleanup_intermediate_files(file_path)

	if progress_cb.is_valid():
		progress_cb.call(1.0, "Export complete!", file_path.get_file())

	return err

## Builds an in-memory Node3D scene tree representing the exported map.
static func build_export_tree(root: Node, settings: ExportSettings = null) -> Node3D:
	if root == null:
		return null

	if settings == null:
		settings = ExportSettings.new()

	var export_root := Node3D.new()
	export_root.name = "Map"

	# Collect scene lights and solid geometry
	var lights := PBLightBaker.collect_scene_lights(root)
	var grid := PBLightBaker.build_spatial_grid(root)

	var base_material_cache: Dictionary = {}

	# Process nodes recursively
	_export_node_recursive(root, export_root, lights, grid, base_material_cache, settings)

	# Set owner recursively so GLTFDocument in editor mode exports all descendant nodes
	_set_owner_recursive(export_root, export_root)

	return export_root

# ==============================================================================
# Internal Scene Tree Construction
# ==============================================================================

static func _set_owner_recursive(node: Node, new_owner: Node) -> void:
	if node != new_owner:
		node.owner = new_owner
	for child in node.get_children():
		_set_owner_recursive(child, new_owner)

static func _is_billboard(node: Node) -> bool:
	if node == null:
		return false
	if node.has_meta("is_billboard") and bool(node.get_meta("is_billboard")):
		return true
	if node is PBMesh:
		var pb := node as PBMesh
		if pb.pb_mesh_data != null and pb.pb_mesh_data.faces.size() == 1:
			if pb.pb_mesh_data.shape_id == &"sprite":
				return true
			if pb.pb_mesh_data.shape_params.has("billboard") and float(pb.pb_mesh_data.shape_params["billboard"]) > 0.5:
				return true
	elif node is MeshInstance3D:
		var name_str := node.name.to_lower()
		if name_str.begins_with("sprite") or name_str.begins_with("billboard") or name_str.begins_with("tree") or name_str.begins_with("bush") or name_str.begins_with("wildflower") or name_str.begins_with("flower"):
			return true
	return false

static func _collect_export_nodes_recursive(source_node: Node, out: Array[Node]) -> void:
	if source_node == null:
		return

	var node_name := source_node.name
	if node_name == "PBStamps" or node_name.begins_with("Collider"):
		return
	if source_node is CollisionShape3D:
		return

	if _is_billboard(source_node):
		out.append(source_node)
	elif source_node is PBMesh:
		var pb := source_node as PBMesh
		if pb.pb_mesh_data != null and not pb.pb_mesh_data.faces.is_empty():
			out.append(source_node)
	elif source_node is Light3D:
		out.append(source_node)

	for child in source_node.get_children():
		_collect_export_nodes_recursive(child, out)

static func _export_single_node(source_node: Node, parent_export_node: Node,
		lights: Array[Light3D], grid: PBLightBaker.SpatialGrid,
		base_material_cache: Dictionary, settings: ExportSettings) -> void:
	if _is_billboard(source_node):
		if settings.export_billboards and source_node is MeshInstance3D:
			_export_billboard(source_node as MeshInstance3D, parent_export_node, lights, grid, settings)
	elif source_node is PBMesh:
		var pb := source_node as PBMesh
		if pb.pb_mesh_data != null and not pb.pb_mesh_data.faces.is_empty():
			if settings.export_mode == ExportMode.RETRO:
				_export_retro_pb_mesh(pb, parent_export_node, lights, grid, base_material_cache, settings)
			else:
				_export_modern_pb_mesh(pb, parent_export_node, lights, grid, base_material_cache, settings)

	elif source_node is Light3D:
		if settings.export_lights:
			_export_light(source_node as Light3D, parent_export_node)
static func _export_node_recursive(source_node: Node, parent_export_node: Node,
		lights: Array[Light3D], grid: PBLightBaker.SpatialGrid,
		base_material_cache: Dictionary, settings: ExportSettings) -> void:
	if source_node == null:
		return

	var node_name := source_node.name
	if node_name == "PBStamps" or node_name.begins_with("Collider"):
		return
	if source_node is CollisionShape3D:
		return

	_export_single_node(source_node, parent_export_node, lights, grid, base_material_cache, settings)

	for child in source_node.get_children():
		_export_node_recursive(child, parent_export_node, lights, grid, base_material_cache, settings)

## Exports a PBMesh in Retro Baked mode.
static func _export_retro_pb_mesh(pb: PBMesh, parent: Node, lights: Array[Light3D],
		grid: PBLightBaker.SpatialGrid, base_material_cache: Dictionary,
		settings: ExportSettings) -> void:
	var mesh_data := pb.pb_mesh_data
	var node_xf := _get_world_transform(pb)

	# Collect all tile fragments across all faces
	var all_fragments: Array[PBFaceSubdivider.TileFragment] = []
	var frag_materials: Dictionary = {} # TileFragment -> Material

	for fi in range(mesh_data.faces.size()):
		var face: PBFace = mesh_data.faces[fi]
		if face == null or face.get_indexes().is_empty():
			continue

		var frags := PBFaceSubdivider.subdivide_face(mesh_data, face, fi, settings.subdivide_quads, settings.grid_size)
		var baked := PBTileBaker.bake_face_tiles(pb, mesh_data, face, fi, frags, settings.bake_textures, settings.tile_resolution, base_material_cache, settings.max_texture_size)

		for frag in frags:
			all_fragments.append(frag)
			var mat: Material = baked.tile_materials.get(frag, null)
			if mat == null:
				mat = PBTileBaker._get_or_create_base_material(mesh_data.get_face_material(face), base_material_cache, settings.max_texture_size)
			frag_materials[frag] = mat

	if all_fragments.is_empty():
		return

	# Group fragments by Material to generate surfaces
	var mat_groups: Dictionary = {} # Material -> Array[TileFragment]
	for frag in all_fragments:
		var mat: Material = frag_materials[frag]
		if not mat_groups.has(mat):
			mat_groups[mat] = [] as Array[PBFaceSubdivider.TileFragment]
		mat_groups[mat].append(frag)

	var array_mesh := ArrayMesh.new()

	for mat: Material in mat_groups:
		var group_frags: Array = mat_groups[mat]
		var surf_positions := PackedVector3Array()
		var surf_normals := PackedVector3Array()
		var surf_uvs := PackedVector2Array()
		var surf_indices := PackedInt32Array()

		for frag: PBFaceSubdivider.TileFragment in group_frags:
			var base_idx := surf_positions.size()
			for i in range(frag.positions.size()):
				# Vertices in node local space
				surf_positions.append(frag.positions[i])
				surf_normals.append(frag.normals[i])
				surf_uvs.append(frag.uvs[i])

			for idx in frag.indices:
				surf_indices.append(base_idx + idx)

		# Bake vertex colors for this surface
		var surf_colors := PBLightBaker.bake_vertex_colors(surf_positions, surf_normals,
			node_xf, lights, grid, settings.bake_lighting, settings.bake_shadows,
			settings.bake_ao, settings.ao_samples, settings.ao_distance,
			settings.ao_intensity, settings.ambient_color)

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surf_positions
		arrays[Mesh.ARRAY_NORMAL] = surf_normals
		arrays[Mesh.ARRAY_TEX_UV] = surf_uvs
		arrays[Mesh.ARRAY_COLOR] = surf_colors
		arrays[Mesh.ARRAY_INDEX] = surf_indices

		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var surf_idx := array_mesh.get_surface_count() - 1
		array_mesh.surface_set_material(surf_idx, mat)

	var export_mi := MeshInstance3D.new()
	export_mi.name = pb.name
	export_mi.mesh = array_mesh
	export_mi.transform = pb.transform
	parent.add_child(export_mi)

	# Export separate collider mesh if enabled
	if settings.export_colliders and pb.collider_type != PBMesh.ColliderType.OFF:
		_export_collider_mesh(pb, parent)

## Exports a PBMesh in Modern mode with metadata/extras and decals.
static func _export_modern_pb_mesh(pb: PBMesh, parent: Node, lights: Array[Light3D],
		grid: PBLightBaker.SpatialGrid, base_material_cache: Dictionary,
		settings: ExportSettings) -> void:
	var mesh_data := pb.pb_mesh_data
	var node_xf := _get_world_transform(pb)

	var am: ArrayMesh = mesh_data.to_array_mesh()

	# If bake lighting is toggled on, bake vertex colors directly onto the ArrayMesh surfaces
	if settings.bake_lighting:
		var new_am := ArrayMesh.new()
		for s in range(am.get_surface_count()):
			var arrays := am.surface_get_arrays(s)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var norm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var cols := PBLightBaker.bake_vertex_colors(pos, norm, node_xf, lights, grid,
				true, settings.bake_shadows, settings.bake_ao, settings.ao_samples,
				settings.ao_distance, settings.ao_intensity, settings.ambient_color)
			arrays[Mesh.ARRAY_COLOR] = cols
			new_am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			new_am.surface_set_material(s, am.surface_get_material(s))
		am = new_am

	var export_mi := MeshInstance3D.new()
	export_mi.name = pb.name
	export_mi.mesh = am
	export_mi.transform = pb.transform

	# Encode stamp placements and paint state as metadata
	var stamps := PBSplat.collect_stamp_data(pb)
	if not stamps.is_empty():
		export_mi.set_meta("poi_stamps", stamps)

	parent.add_child(export_mi)

	# Also export stamps as explicit child decal quad nodes for universal engine support
	var stamps_container := pb.get_node_or_null("PBStamps")
	if stamps_container != null:
		var export_stamps := Node3D.new()
		export_stamps.name = "PBStamps"
		export_mi.add_child(export_stamps)

		for stamp in stamps_container.get_children():
			if stamp is MeshInstance3D:
				var mi := stamp as MeshInstance3D
				var dup := MeshInstance3D.new()
				dup.name = mi.name
				dup.mesh = mi.mesh if mi.mesh != null else QuadMesh.new()
				dup.material_override = mi.material_override
				dup.transform = mi.transform
				export_stamps.add_child(dup)

	# Export separate collider mesh if enabled
	if settings.export_colliders and pb.collider_type != PBMesh.ColliderType.OFF:
		_export_collider_mesh(pb, parent)

## Exports a collider mesh named Collider_<Name>.
static func _export_collider_mesh(pb: PBMesh, parent: Node) -> void:
	var col_mi := MeshInstance3D.new()
	col_mi.name = "Collider_" + pb.name
	col_mi.mesh = _get_collider_mesh(pb)
	col_mi.transform = pb.transform
	col_mi.visible = false # Colliders default to hidden
	parent.add_child(col_mi)

## Gets the mesh used for collider export, respecting RAMP collider shapes on stairs.
static func _get_collider_mesh(pb: PBMesh) -> Mesh:
	if pb == null:
		return null

	if pb.collider_type == PBMesh.ColliderType.RAMP and pb.is_stairs():
		var shape := pb._build_stairs_ramp_shape()
		if shape is ConcavePolygonShape3D:
			var faces: PackedVector3Array = (shape as ConcavePolygonShape3D).get_faces()
			if not faces.is_empty():
				var am := ArrayMesh.new()
				var arrs: Array = []
				arrs.resize(Mesh.ARRAY_MAX)
				arrs[Mesh.ARRAY_VERTEX] = faces
				am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
				return am
		elif shape is ConvexPolygonShape3D:
			var pts: PackedVector3Array = (shape as ConvexPolygonShape3D).points
			if pts.size() == 6:
				var prism_tris := PackedVector3Array([
					pts[0], pts[1], pts[5],
					pts[0], pts[5], pts[4],
					pts[0], pts[3], pts[2],
					pts[0], pts[2], pts[1],
					pts[3], pts[4], pts[5],
					pts[3], pts[5], pts[2],
					pts[0], pts[4], pts[3],
					pts[1], pts[2], pts[5],
				])
				var am := ArrayMesh.new()
				var arrs: Array = []
				arrs.resize(Mesh.ARRAY_MAX)
				arrs[Mesh.ARRAY_VERTEX] = prism_tris
				am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
				return am

	if pb.mesh != null:
		return pb.mesh
	elif pb.pb_mesh_data != null:
		return pb.pb_mesh_data.to_array_mesh()
	return null
## Exports a billboard sprite node with optional vertex lighting.
static func _export_billboard(mi: MeshInstance3D, parent: Node, lights: Array[Light3D],
		grid: PBLightBaker.SpatialGrid, settings: ExportSettings) -> void:
	var export_mi := MeshInstance3D.new()
	export_mi.name = mi.name
	export_mi.transform = mi.transform

	var src_mesh: Mesh = null
	if mi is PBMesh:
		var pb := mi as PBMesh
		if pb.mesh != null:
			src_mesh = pb.mesh
		elif pb.pb_mesh_data != null:
			src_mesh = pb.pb_mesh_data.to_array_mesh()
	else:
		src_mesh = mi.mesh

	if src_mesh != null:
		var am := ArrayMesh.new()
		for s in range(src_mesh.get_surface_count()):
			var arrays := src_mesh.surface_get_arrays(s)
			if settings.bake_lighting:
				var cols := PBLightBaker.bake_billboard_colors(mi, lights, grid, true,
					settings.bake_shadows, settings.ambient_color)
				var v_count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				if cols.size() != v_count:
					var new_cols := PackedColorArray()
					new_cols.resize(v_count)
					var fallback_col: Color = cols[0] if not cols.is_empty() else Color.WHITE
					for ci in range(v_count):
						new_cols[ci] = cols[ci] if ci < cols.size() else fallback_col
					cols = new_cols
				arrays[Mesh.ARRAY_COLOR] = cols

			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mat := mi.material_override
			if mat == null and src_mesh is ArrayMesh:
				mat = (src_mesh as ArrayMesh).surface_get_material(s)
			if mat == null and mi is PBMesh:
				var pb := mi as PBMesh
				if pb.pb_mesh_data != null and not pb.pb_mesh_data.faces.is_empty():
					mat = pb.pb_mesh_data.get_face_material(pb.pb_mesh_data.faces[0])
			if mat is StandardMaterial3D:
				var sm := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
				if settings.export_mode == ExportMode.RETRO and settings.enforce_power_of_two and sm.albedo_texture != null:
					sm.albedo_texture = PBTileBaker.enforce_pot_texture(sm.albedo_texture, settings.max_texture_size)
				if sm.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
					sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				sm.cull_mode = BaseMaterial3D.CULL_DISABLED
				sm.texture_repeat = false
				sm.vertex_color_use_as_albedo = true
				am.surface_set_material(s, sm)
		export_mi.mesh = am

	parent.add_child(export_mi)

## Exports a light node.
static func _export_light(light: Light3D, parent: Node) -> void:
	var dup := light.duplicate() as Light3D
	parent.add_child(dup)

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

## Exports the given scene root to a .pbm (PoiBuilder Retro Map) binary file on disk.
static func export_retro_pbm(root: Node, file_path: String, settings: ExportSettings = null) -> Error:
	if root == null or file_path.is_empty():
		return ERR_INVALID_PARAMETER
	if settings == null:
		settings = ExportSettings.new()

	ensure_export_dir(file_path)

	var export_tree := build_export_tree(root, settings)
	if export_tree == null:
		return ERR_CANT_CREATE

	var err := _write_pbm_from_tree(export_tree, file_path, settings)
	export_tree.free()
	return err

static func _write_pbm_from_tree(export_tree: Node, file_path: String, settings: ExportSettings) -> Error:
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()

	var textures: Array[Dictionary] = []
	var tex_map: Dictionary = {} # RID/Resource -> int index

	var meshes: Array[Dictionary] = []
	var colliders: Array[Dictionary] = []

	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)

	var mesh_nodes: Array[MeshInstance3D] = []
	_collect_mesh_instances_recursive(export_tree, mesh_nodes)

	for mi in mesh_nodes:
		var name_str := mi.name
		var xf := _get_world_transform(mi)
		var mesh := mi.mesh
		if mesh == null:
			continue

		var is_collider := name_str.begins_with("Collider_") or name_str.begins_with("collider_")

		for s in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts.is_empty():
				continue

			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()

			if is_collider:
				var tris: PackedVector3Array = PackedVector3Array()
				if not indices.is_empty():
					for idx in indices:
						tris.append(xf * verts[idx])
				else:
					for v in verts:
						tris.append(xf * v)
				colliders.append({
					"name": name_str.substr(0, 31),
					"type": 2 if name_str.to_lower().contains("ramp") else (0 if name_str.to_lower().contains("box") else 1),
					"triangles": tris
				})
			else:
				var mat: Material = mi.material_override
				if mat == null:
					mat = mesh.surface_get_material(s)
				var tex_id := -1
				if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
					var albedo_tex: Texture2D = (mat as StandardMaterial3D).albedo_texture
					var tex_key = albedo_tex.get_rid()
					if tex_map.has(tex_key):
						tex_id = tex_map[tex_key]
					else:
						var img := albedo_tex.get_image()
						if img != null:
							if img.is_compressed():
								img.decompress()
							var w := img.get_width()
							var h := img.get_height()
							var pot_w := _next_pot(w)
							var pot_h := _next_pot(h)
							if pot_w != w or pot_h != h:
								img.resize(pot_w, pot_h, Image.INTERPOLATE_BILINEAR)
								w = pot_w
								h = pot_h

							var tex_data := PackedByteArray()
							tex_data.resize(w * h * 2)
							img.convert(Image.FORMAT_RGBA8)
							var raw_bytes := img.get_data()
							var has_alpha: int = 0
							for px_idx in range(w * h):
								var r: int = raw_bytes[px_idx * 4]
								var g: int = raw_bytes[px_idx * 4 + 1]
								var b: int = raw_bytes[px_idx * 4 + 2]
								var a: int = raw_bytes[px_idx * 4 + 3]
								if a < 250:
									has_alpha = 1
								var r5: int = (r >> 3) & 0x1F
								var g5: int = (g >> 3) & 0x1F
								var b5: int = (b >> 3) & 0x1F
								var a1: int = 1 if a > 127 else 0
								var p16: int = (a1 << 15) | (b5 << 10) | (g5 << 5) | r5
								tex_data[px_idx * 2] = p16 & 0xFF
								tex_data[px_idx * 2 + 1] = (p16 >> 8) & 0xFF

							tex_id = textures.size()
							textures.append({
								"name": albedo_tex.resource_name.substr(0, 31) if not albedo_tex.resource_name.is_empty() else "tex_%d" % tex_id,
								"width": w,
								"height": h,
								"format": PBM_TEX_FMT_RGBA5551,
								"has_alpha": has_alpha,
								"data": tex_data
							})
							tex_map[tex_key] = tex_id

				var tri_verts: Array[Dictionary] = []
				var idx_list: Array = []
				if not indices.is_empty():
					for idx in indices: idx_list.append(idx)
				else:
					for i in range(verts.size()): idx_list.append(i)

				for idx in idx_list:
					var wp: Vector3 = xf * verts[idx]
					bounds_min.x = minf(bounds_min.x, wp.x); bounds_max.x = maxf(bounds_max.x, wp.x)
					bounds_min.y = minf(bounds_min.y, wp.y); bounds_max.y = maxf(bounds_max.y, wp.y)
					bounds_min.z = minf(bounds_min.z, wp.z); bounds_max.z = maxf(bounds_max.z, wp.z)

					var uv: Vector2 = uvs[idx] if idx < uvs.size() else Vector2.ZERO
					var c: Color = colors[idx] if idx < colors.size() else Color.WHITE
					var r_b: int = int(clampf(c.r, 0.0, 1.0) * 255.0)
					var g_b: int = int(clampf(c.g, 0.0, 1.0) * 255.0)
					var b_b: int = int(clampf(c.b, 0.0, 1.0) * 255.0)
					var a_b: int = int(clampf(c.a, 0.0, 1.0) * 255.0)
					var c_int: int = r_b | (g_b << 8) | (b_b << 16) | (a_b << 24)

					tri_verts.append({
						"u": uv.x, "v": uv.y,
						"color": c_int,
						"x": wp.x, "y": wp.y, "z": wp.z
					})

				if not tri_verts.is_empty():
					meshes.append({
						"name": name_str.substr(0, 31),
						"texture_id": tex_id,
						"vertices": tri_verts
					})

	if bounds_min.x == INF:
		bounds_min = Vector3(-10, 0, -10)
		bounds_max = Vector3(10, 5, 10)

	var spawn := (bounds_min + bounds_max) * 0.5
	spawn.y = bounds_min.y + 1.6
	spawn.z = bounds_max.z + 4.0

	# Header
	f.store_32(PBM_MAGIC)
	f.store_32(PBM_VERSION)
	f.store_32(textures.size())
	f.store_32(meshes.size())
	f.store_32(colliders.size())
	f.store_float(spawn.x); f.store_float(spawn.y); f.store_float(spawn.z)
	f.store_float(0.0)
	f.store_float(bounds_min.x); f.store_float(bounds_min.y); f.store_float(bounds_min.z)
	f.store_float(bounds_max.x); f.store_float(bounds_max.y); f.store_float(bounds_max.z)

	# Textures
	for tex in textures:
		var name_bytes: PackedByteArray = (tex["name"] as String).to_ascii_buffer()
		name_bytes.resize(32)
		f.store_16(tex["width"])
		f.store_16(tex["height"])
		f.store_16(tex["format"])
		f.store_16(tex.get("has_alpha", 0))
		f.store_32((tex["data"] as PackedByteArray).size())
		f.store_buffer(tex["data"])

	# Meshes
	for m in meshes:
		var name_bytes: PackedByteArray = (m["name"] as String).to_ascii_buffer()
		name_bytes.resize(32)
		f.store_buffer(name_bytes)
		f.store_32(m["texture_id"])
		var v_list: Array = m["vertices"]
		f.store_32(v_list.size())
		var m_min := Vector3(INF, INF, INF)
		var m_max := Vector3(-INF, -INF, -INF)
		for v in v_list:
			m_min.x = minf(m_min.x, v["x"]); m_max.x = maxf(m_max.x, v["x"])
			m_min.y = minf(m_min.y, v["y"]); m_max.y = maxf(m_max.y, v["y"])
			m_min.z = minf(m_min.z, v["z"]); m_max.z = maxf(m_max.z, v["z"])
		f.store_float(m_min.x); f.store_float(m_min.y); f.store_float(m_min.z)
		f.store_float(m_max.x); f.store_float(m_max.y); f.store_float(m_max.z)

		for v in v_list:
			f.store_float(v["u"])
			f.store_float(v["v"])
			f.store_32(v["color"])
			f.store_float(v["x"])
			f.store_float(v["y"])
			f.store_float(v["z"])

	# Colliders
	for col in colliders:
		var name_bytes: PackedByteArray = (col["name"] as String).to_ascii_buffer()
		name_bytes.resize(32)
		f.store_buffer(name_bytes)
		f.store_32(col["type"])
		var tris: PackedVector3Array = col["triangles"]
		var c_min := Vector3(INF, INF, INF)
		var c_max := Vector3(-INF, -INF, -INF)
		for p in tris:
			c_min.x = minf(c_min.x, p.x); c_max.x = maxf(c_max.x, p.x)
			c_min.y = minf(c_min.y, p.y); c_max.y = maxf(c_max.y, p.y)
			c_min.z = minf(c_min.z, p.z); c_max.z = maxf(c_max.z, p.z)
		f.store_float(c_min.x); f.store_float(c_min.y); f.store_float(c_min.z)
		f.store_float(c_max.x); f.store_float(c_max.y); f.store_float(c_max.z)
		f.store_32(int(tris.size() / 3))
		for p in tris:
			f.store_float(p.x)
			f.store_float(p.y)
			f.store_float(p.z)

	f.close()
	return OK

static func _next_pot(x: int) -> int:
	if x <= 0: return 1
	var p := 1
	while p < x: p <<= 1
	return p

static func _collect_mesh_instances_recursive(node: Node, out: Array[MeshInstance3D]) -> void:
	if node == null:
		return
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_mesh_instances_recursive(child, out)
