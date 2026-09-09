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

## Cancellation token for aborting an in-progress async export.
class CancellationToken extends RefCounted:
	var cancelled: bool = false

	func cancel() -> void:
		cancelled = true

# ==============================================================================
# Public API
# ==============================================================================

## Exports the given scene root to a .glb or .gltf file on disk synchronously.
static func export_map(root: Node, file_path: String, settings: ExportSettings = null) -> Error:
	if root == null or file_path.is_empty():
		return ERR_INVALID_PARAMETER

	if settings == null:
		settings = ExportSettings.new()

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
	return err

## Asynchronous export with frame-by-frame progress reporting and cancellation support.
## Yields frames via `await Engine.get_main_loop().process_frame` so editor UI stays 100% interactive.
static func export_map_async(root: Node, file_path: String, settings: ExportSettings = null,
		progress_cb: Callable = Callable(), cancel_token: CancellationToken = null) -> Error:
	if root == null or file_path.is_empty():
		return ERR_INVALID_PARAMETER

	if settings == null:
		settings = ExportSettings.new()

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

static func _collect_export_nodes_recursive(source_node: Node, out: Array[Node]) -> void:
	if source_node == null:
		return

	var node_name := source_node.name
	if node_name == "PBStamps" or node_name.begins_with("Collider"):
		return
	if source_node is CollisionShape3D:
		return

	if source_node is PBMesh:
		var pb := source_node as PBMesh
		if pb.pb_mesh_data != null and not pb.pb_mesh_data.faces.is_empty():
			out.append(source_node)
	elif source_node is MeshInstance3D and (source_node.name.begins_with("Sprite") or source_node.has_meta("is_billboard")):
		out.append(source_node)
	elif source_node is Light3D:
		out.append(source_node)

	for child in source_node.get_children():
		_collect_export_nodes_recursive(child, out)

static func _export_single_node(source_node: Node, parent_export_node: Node,
		lights: Array[Light3D], grid: PBLightBaker.SpatialGrid,
		base_material_cache: Dictionary, settings: ExportSettings) -> void:
	if source_node is PBMesh:
		var pb := source_node as PBMesh
		if pb.pb_mesh_data != null and not pb.pb_mesh_data.faces.is_empty():
			if settings.export_mode == ExportMode.RETRO:
				_export_retro_pb_mesh(pb, parent_export_node, lights, grid, base_material_cache, settings)
			else:
				_export_modern_pb_mesh(pb, parent_export_node, lights, grid, base_material_cache, settings)

	elif source_node is MeshInstance3D and (source_node.name.begins_with("Sprite") or source_node.has_meta("is_billboard")):
		if settings.export_billboards:
			_export_billboard(source_node as MeshInstance3D, parent_export_node, lights, grid, settings)

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
	col_mi.mesh = pb.pb_mesh_data.to_array_mesh()
	col_mi.transform = pb.transform
	col_mi.visible = false # Colliders default to hidden
	parent.add_child(col_mi)

## Exports a billboard sprite node with optional vertex lighting.
static func _export_billboard(mi: MeshInstance3D, parent: Node, lights: Array[Light3D],
		grid: PBLightBaker.SpatialGrid, settings: ExportSettings) -> void:
	var export_mi := MeshInstance3D.new()
	export_mi.name = mi.name
	export_mi.transform = mi.transform

	var src_mesh := mi.mesh
	if src_mesh != null:
		var am := ArrayMesh.new()
		for s in range(src_mesh.get_surface_count()):
			var arrays := src_mesh.surface_get_arrays(s)
			if settings.bake_lighting:
				var cols := PBLightBaker.bake_billboard_colors(mi, lights, grid, true,
					settings.bake_shadows, settings.ambient_color)
				arrays[Mesh.ARRAY_COLOR] = cols

			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mat := mi.material_override
			if mat == null and src_mesh is ArrayMesh:
				mat = (src_mesh as ArrayMesh).surface_get_material(s)
			if mat is StandardMaterial3D:
				var sm := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
				if settings.export_mode == ExportMode.RETRO and settings.enforce_power_of_two and sm.albedo_texture != null:
					sm.albedo_texture = PBTileBaker.enforce_pot_texture(sm.albedo_texture, settings.max_texture_size)
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
