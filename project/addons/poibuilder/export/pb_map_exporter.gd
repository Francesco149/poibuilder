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

const PBM_MAGIC := 0x334D4250 # "PBM3"
const PBM_VERSION := 3

const PBM_META_RAW    := 0
const PBM_META_STRING := 1
const PBM_META_JSON   := 2
const PBM_META_ENTITY := 3
## Standard lump: particle emitters (SPEC_RETRO_FORMAT.md §8).
const PBM_META_EMITTER := 4
const PBM_ENTITY_PATROL_SPHERE := 1

## Particle emitter flags (PbmEmitter.flags).
const PBM_EMIT_ADDITIVE := 1
const PBM_EMIT_Y_LOCKED := 2
const PBM_EMIT_VEL_ALIGN := 4
const PBM_EMIT_PHASE_ALIGN := 8
## Binary layout of one PbmEmitter record (pbm.h / the specification).
const PBM_EMITTER_SIZE_BYTES := 176
## The runtime's per-emitter particle budget; a larger Godot `amount` is clamped
## at export so the file describes what will actually be drawn.
const PBM_EMIT_MAX_PER_EMITTER := 64
## The built-in emitter texture: a radial glow, RGB falloff with a solid alpha.
## Used when an emitter carries no texture (additive particles only).
const PBM_EMITTER_GLOW_TEXTURE := -1

const PBM_TEX_FMT_RGBA8888 := 0
const PBM_TEX_FMT_RGBA5551 := 1

## Alpha handling stored per texture (PBM v3). A texture may only carry the
## alpha its pixels were exported with: 5551 has ONE alpha bit, so anything
## that needs a soft, partial alpha has to travel as RGBA8888.
const PBM_ALPHA_NONE := 0
const PBM_ALPHA_CUTOUT := 1
const PBM_ALPHA_BLEND := 2
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
		var err := _write_pbm_from_tree(root, export_root, file_path, settings)
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
	elif source_node is GPUParticles3D:
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
	elif source_node is GPUParticles3D:
		_export_emitter_holder(source_node as GPUParticles3D, parent_export_node)

## The GLB is a transport for the converters, and glTF has no particle-emitter
## concept: the record rides in the node's `extras` (which Godot serializes
## verbatim) and the particle's texture rides on a zero-size holder quad, because
## an image only reaches a glTF file through a material that some primitive
## references. The holder is named `EmitterTex_*` and carries a
## `poi_emitter_holder` meta: both the direct PBM writer and the converters skip
## it, so it never becomes visible geometry — in the retro map or anywhere else.
static func _export_emitter_holder(node: GPUParticles3D, parent: Node) -> void:
	var holder := MeshInstance3D.new()
	holder.name = "EmitterTex_%s" % node.name
	holder.transform = node.transform
	var qm := QuadMesh.new()
	qm.size = Vector2(0.001, 0.001)
	holder.mesh = qm

	var src_mat: Material = node.material_override
	if src_mat == null and node.draw_pass_1 != null and node.draw_pass_1.get_surface_count() > 0:
		src_mat = node.draw_pass_1.surface_get_material(0)
	if src_mat != null:
		holder.mesh.surface_set_material(0, src_mat.duplicate())
	holder.set_meta("poi_emitter_holder", true)
	holder.set_meta("extras", make_emitter_extras(node))
	parent.add_child(holder)

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
				# A billboard's quad maps 0..1 across the sprite, so tiling is
				# off by default — but a SCROLLING sprite samples outside that
				# range every frame, and clamping would smear its edge texels.
				sm.texture_repeat = PBUv.has_scroll(mat)
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

	var err := _write_pbm_from_tree(root, export_tree, file_path, settings)
	export_tree.free()
	return err

## Convenience method: converts an exported GLB file to PBMv2 format directly via GDScript.
static func convert_glb_to_pbm(glb_path: String, pbm_path: String, format_16bit: bool = true) -> Error:
	return PBPbmConverter.convert_glb_to_pbm(glb_path, pbm_path, format_16bit)

## Registers one authored texture in the PBM texture table and returns its index.
## Shared by the mesh path and the particle path: a particle atlas is an ordinary
## texture entry and obeys exactly the same rules (power-of-two, 5551 unless the
## alpha has to be soft, deduplicated by resource and by pixels).
## `prefer_binary_5551` is the additive-emitter case: it keeps the 16-bit format
## when the art's alpha is genuinely 1-bit, and falls back to 8888 when it is not
## (a soft gradient quantised to one alpha bit would become a hard cutout).
static func _register_texture(textures: Array, tex_map: Dictionary, albedo_tex: Texture2D,
		alpha_mode: int, prefer_binary_5551: bool = false) -> int:
	if albedo_tex == null:
		return PBM_EMITTER_GLOW_TEXTURE
	var tex_key = albedo_tex.get_rid()
	if tex_map.has(tex_key):
		return tex_map[tex_key]
	var img := albedo_tex.get_image()
	if img == null:
		return PBM_EMITTER_GLOW_TEXTURE
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

	img.convert(Image.FORMAT_RGBA8)
	var raw_bytes := img.get_data()
	var tex_data := PackedByteArray()
	var tex_format := PBM_TEX_FMT_RGBA5551
	if alpha_mode == PBM_ALPHA_BLEND and not prefer_binary_5551:
		# A soft alpha needs the full 8 bits: 5551 carries one, which can only
		# cut a pixel out, not fade it.
		tex_data = raw_bytes.duplicate()
		tex_format = PBM_TEX_FMT_RGBA8888
	else:
		tex_data.resize(w * h * 2)
		var any_alpha := false
		var binary_alpha := true
		for px_idx in range(w * h):
			var r: int = raw_bytes[px_idx * 4]
			var g: int = raw_bytes[px_idx * 4 + 1]
			var b: int = raw_bytes[px_idx * 4 + 2]
			var a: int = raw_bytes[px_idx * 4 + 3]
			if a < 250:
				any_alpha = true
			if a > 4 and a < 250:
				binary_alpha = false
			var r5: int = (r >> 3) & 0x1F
			var g5: int = (g >> 3) & 0x1F
			var b5: int = (b >> 3) & 0x1F
			var a1: int = 1 if a > 127 else 0
			var p16: int = (a1 << 15) | (b5 << 10) | (g5 << 5) | r5
			tex_data[px_idx * 2] = p16 & 0xFF
			tex_data[px_idx * 2 + 1] = (p16 >> 8) & 0xFF
		if any_alpha and alpha_mode == PBM_ALPHA_NONE:
			# Opaque material, transparent art: the pixels still need the alpha
			# pass, as a cutout.
			alpha_mode = PBM_ALPHA_CUTOUT
		elif prefer_binary_5551:
			alpha_mode = PBM_ALPHA_CUTOUT if binary_alpha else PBM_ALPHA_BLEND
	if alpha_mode == PBM_ALPHA_BLEND and tex_format != PBM_TEX_FMT_RGBA8888:
		# 5551 was declined after all (soft alpha art): rebuild as RGBA8888.
		tex_data = raw_bytes.duplicate()
		tex_format = PBM_TEX_FMT_RGBA8888

	var data_hash: int = hash(tex_data)
	if tex_map.has(data_hash):
		var existing: int = tex_map[data_hash]
		tex_map[tex_key] = existing
		return existing
	var tex_id: int = textures.size()
	textures.append({
		"name": albedo_tex.resource_name.substr(0, 31) if not albedo_tex.resource_name.is_empty() else "tex_%d" % tex_id,
		"width": w,
		"height": h,
		"format": tex_format,
		"alpha_mode": alpha_mode,
		"data": tex_data
	})
	tex_map[tex_key] = tex_id
	tex_map[data_hash] = tex_id
	return tex_id

## The alpha handling a material's surface needs, from how the author set its
## transparency. Scissor/hash are hard-edged cutouts (foliage, decals); plain
## Alpha is a soft blend (water, glass, smoke).
static func material_alpha_mode(mat: Material) -> int:
	if mat is StandardMaterial3D:
		match (mat as StandardMaterial3D).transparency:
			BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, BaseMaterial3D.TRANSPARENCY_ALPHA_HASH:
				return PBM_ALPHA_CUTOUT
			BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				return PBM_ALPHA_BLEND
	return PBM_ALPHA_NONE

static func _write_pbm_from_tree(root: Node, export_tree: Node, file_path: String, settings: ExportSettings) -> Error:
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
		if mi.has_meta("poi_emitter_holder"):
			# A particle emitter's texture carrier, not geometry (see
			# _export_emitter_holder): it exists for the GLB converters.
			continue
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
				# Animated UV scroll travels with the material (see PBUv).
				var scroll := PBUv.get_scroll_speed(mat)
				var mat_alpha := material_alpha_mode(mat)
				var tex_id := -1
				if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
					tex_id = _register_texture(textures, tex_map,
						(mat as StandardMaterial3D).albedo_texture, mat_alpha)

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
					# Chunk large meshes into <= 384 vertices to eliminate near-plane clipping bottleneck
					var chunk_size := 384
					for ci in range(0, tri_verts.size(), chunk_size):
						var cverts: Array[Dictionary] = []
						for vi in range(ci, mini(ci + chunk_size, tri_verts.size())):
							cverts.append(tri_verts[vi])
						meshes.append({
							"name": ("%s_%d" % [name_str, ci / chunk_size]).substr(0, 31),
							"texture_id": tex_id,
							"uv_scroll": scroll,
							"vertices": cverts
						})
	if bounds_min.x == INF:
		bounds_min = Vector3(-10, 0, -10)
		bounds_max = Vector3(10, 5, 10)

	var spawn := (bounds_min + bounds_max) * 0.5
	spawn.y = bounds_min.y + 1.6
	spawn.z = bounds_max.z + 4.0

	# Dynamic Scene Entity & Metadata Discovery (PBM v2.0+)
	var metadata_entries := _collect_metadata_from_scene(root, export_tree, settings, bounds_min, bounds_max, spawn)

	# Particle emitters (standard lump "emitters"). Collected here rather than in
	# the metadata pass because each emitter's texture has to be registered in
	# the table above — a particle atlas is an ordinary texture entry.
	var emitter_nodes: Array[GPUParticles3D] = []
	_collect_emitters_recursive(root, emitter_nodes)
	if not emitter_nodes.is_empty():
		metadata_entries.append(_emitters_metadata_entry(emitter_nodes, textures, tex_map))


	# Header (64 bytes)
	f.store_32(PBM_MAGIC)
	f.store_32(PBM_VERSION)
	f.store_32(textures.size())
	f.store_32(meshes.size())
	f.store_32(colliders.size())
	f.store_32(metadata_entries.size())
	f.store_float(spawn.x); f.store_float(spawn.y); f.store_float(spawn.z)
	f.store_float(0.0)
	f.store_float(bounds_min.x); f.store_float(bounds_min.y); f.store_float(bounds_min.z)
	f.store_float(bounds_max.x); f.store_float(bounds_max.y); f.store_float(bounds_max.z)
	# Textures
	for tex in textures:
		var name_bytes: PackedByteArray = (tex["name"] as String).to_ascii_buffer()
		name_bytes.resize(32)
		f.store_buffer(name_bytes)
		f.store_16(tex["width"])
		f.store_16(tex["height"])
		f.store_16(tex["format"])
		f.store_16(tex.get("alpha_mode", 0))
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
		# PBM 2.1 animated UV scroll (was `reserved[2]`, always 0.0 before).
		var scroll: Vector2 = m.get("uv_scroll", Vector2.ZERO)
		f.store_float(scroll.x)
		f.store_float(scroll.y)

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


	# Metadata Chunk (v2.0+)
	for mentry in metadata_entries:
		var tag_b: PackedByteArray = (mentry["tag"] as String).to_ascii_buffer()
		tag_b.resize(32)
		f.store_buffer(tag_b)
		f.store_32(mentry["type"])
		var mdata: PackedByteArray = mentry["data"]
		f.store_32(mdata.size())
		f.store_buffer(mdata)
		var pad := (4 - (mdata.size() % 4)) % 4
		for pi in range(pad):
			f.store_8(0)
	f.close()
	return OK
## Recursively collects all child nodes into an array.
static func _collect_nodes_recursive(node: Node, out: Array[Node]) -> void:
	if node == null: return
	out.append(node)
	for child in node.get_children():
		_collect_nodes_recursive(child, out)

## Dynamically scans the authored Godot scene tree for entities, triggers, spawns, and custom metadata.
static func _collect_metadata_from_scene(root: Node, export_tree: Node, settings: ExportSettings,
		bounds_min: Vector3, bounds_max: Vector3, default_spawn: Vector3) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var all_nodes: Array[Node] = []
	if root != null:
		_collect_nodes_recursive(root, all_nodes)

	# 1. Map Name
	var map_name := "PoiRetro Courtyard Showcase"
	if root != null:
		if root.has_meta("map_name") and not str(root.get_meta("map_name")).is_empty():
			map_name = str(root.get_meta("map_name"))
		elif not root.name.is_empty() and root.name != "Node3D":
			map_name = root.name
	var map_name_bytes := map_name.to_utf8_buffer()
	map_name_bytes.append(0)
	entries.append({ "tag": "map_name", "type": PBM_META_STRING, "data": map_name_bytes })

	# 2. Player Spawn Point
	var spawn_pos := default_spawn
	var spawn_rot := 0.0
	var spawn_fov := 65.0
	var spawn_found := false

	var triggers_list: Array[Dictionary] = []
	var ball_pit_dict: Dictionary = {}
	var walkable_triangles: PackedVector3Array = PackedVector3Array()
	var custom_metadata_nodes: Array[Node] = []

	for node in all_nodes:
		var n_name := node.name
		var n_lower := n_name.to_lower()

		# Spawn Point Discovery
		if not spawn_found and (n_lower.begins_with("spawn") or n_lower.contains("playerspawn") or node.has_meta("poi_spawn")):
			if node is Node3D:
				var xf := _get_world_transform(node as Node3D)
				spawn_pos = xf.origin
				spawn_rot = (node as Node3D).rotation.y
				if node.has_meta("camera_fov"):
					spawn_fov = float(node.get_meta("camera_fov"))
				spawn_found = true

		# Walkable Mesh Discovery
		if (n_lower.begins_with("walkable") or n_lower.contains("navmesh") or node.has_meta("poi_walkable")) and node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.mesh != null:
				var xf := _get_world_transform(mi)
				for s in range(mi.mesh.get_surface_count()):
					var arrs := mi.mesh.surface_get_arrays(s)
					var v_arr: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
					var i_arr: PackedInt32Array = arrs[Mesh.ARRAY_INDEX] if arrs[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
					if not i_arr.is_empty():
						for idx in i_arr: walkable_triangles.append(xf * v_arr[idx])
					else:
						for v in v_arr: walkable_triangles.append(xf * v)

		# Trigger Area Discovery
		if n_lower.begins_with("trigger") or node.has_meta("poi_trigger"):
			var t_min := Vector3(-1, 0, -1)
			var t_max := Vector3(1, 2, 1)
			if node is Node3D:
				var xf := _get_world_transform(node as Node3D)
				var aabb := AABB(Vector3(-1, 0, -1), Vector3(2, 2, 2))
				if node is VisualInstance3D:
					aabb = (node as VisualInstance3D).get_aabb()
				var p0 := xf * aabb.position
				var p1 := xf * (aabb.position + aabb.size)
				t_min = Vector3(minf(p0.x, p1.x), minf(p0.y, p1.y), minf(p0.z, p1.z))
				t_max = Vector3(maxf(p0.x, p1.x), maxf(p0.y, p1.y), maxf(p0.z, p1.z))
			var t_entry: Dictionary = {
				"id": n_name,
				"event": str(node.get_meta("event")) if node.has_meta("event") else ("on_enter_" + n_name.to_lower()),
				"bounds_min": [t_min.x, t_min.y, t_min.z],
				"bounds_max": [t_max.x, t_max.y, t_max.z],
				"oneshot": bool(node.get_meta("oneshot")) if node.has_meta("oneshot") else true
			}
			for mkey in node.get_meta_list():
				if not mkey.begins_with("poi_") and not t_entry.has(mkey):
					t_entry[mkey] = node.get_meta(mkey)
			triggers_list.append(t_entry)

		# Ball Pit / Rigid Bodies Discovery
		if n_lower.contains("ballpit") or node.has_meta("poi_rigid_body") or node.has_meta("ball_pit"):
			ball_pit_dict = {
				"type": "ball_pit",
				"count": int(node.get_meta("count")) if node.has_meta("count") else 16,
				"radius": float(node.get_meta("radius")) if node.has_meta("radius") else 0.22,
				"mass": float(node.get_meta("mass")) if node.has_meta("mass") else 1.0,
				"restitution": float(node.get_meta("restitution")) if node.has_meta("restitution") else 0.75,
				"spawn_min": [-0.8, 2.0, -0.8],
				"spawn_max": [0.8, 4.0, 0.8]
			}
			if node is Node3D:
				var xf := _get_world_transform(node as Node3D)
				ball_pit_dict["spawn_min"] = [xf.origin.x - 0.8, xf.origin.y + 1.0, xf.origin.z - 0.8]
				ball_pit_dict["spawn_max"] = [xf.origin.x + 0.8, xf.origin.y + 3.0, xf.origin.z + 0.8]

		# Arbitrary Custom Node Metadata Tag
		if node.has_meta("poi_metadata_tag"):
			custom_metadata_nodes.append(node)

	# 2. Player Spawn JSON
	var spawn_json_bytes := JSON.stringify({
		"position": [spawn_pos.x, spawn_pos.y, spawn_pos.z],
		"yaw": spawn_rot,
		"camera_fov": spawn_fov
	}).to_utf8_buffer()
	spawn_json_bytes.append(0)
	entries.append({ "tag": "player_spawn", "type": PBM_META_JSON, "data": spawn_json_bytes })

	# 3. Walkable Mesh
	if walkable_triangles.is_empty():
		# Default ground floor quad
		walkable_triangles.append_array([
			Vector3(-4.0, 0.0, -5.5), Vector3(4.0, 0.0, -5.5), Vector3(4.0, 0.0, 5.0),
			Vector3(-4.0, 0.0, -5.5), Vector3(4.0, 0.0, 5.0),  Vector3(-4.0, 0.0, 5.0)
		])
	var walkable_buf := PackedByteArray()
	walkable_buf.resize(walkable_triangles.size() * 12)
	for wi in range(walkable_triangles.size()):
		var p: Vector3 = walkable_triangles[wi]
		walkable_buf.encode_float(wi * 12, p.x)
		walkable_buf.encode_float(wi * 12 + 4, p.y)
		walkable_buf.encode_float(wi * 12 + 8, p.z)
	entries.append({ "tag": "walkable_mesh", "type": PBM_META_ENTITY, "data": walkable_buf })

	# 4. Triggers
	if triggers_list.is_empty():
		triggers_list.append({
			"id": "cutscene_archway",
			"event": "on_enter_archway",
			"bounds_min": [-2.0, 0.0, -5.8],
			"bounds_max": [2.0, 3.5, -4.8],
			"oneshot": true
		})
	var triggers_json_bytes := JSON.stringify(triggers_list).to_utf8_buffer()
	triggers_json_bytes.append(0)
	entries.append({ "tag": "triggers", "type": PBM_META_JSON, "data": triggers_json_bytes })

	# 5. Rigid Bodies
	if ball_pit_dict.is_empty():
		ball_pit_dict = {
			"type": "ball_pit",
			"count": 16,
			"radius": 0.22,
			"mass": 1.0,
			"restitution": 0.75,
			"spawn_min": [-0.8, 2.0, -0.8],
			"spawn_max": [0.8, 4.0, 0.8]
		}
	var rigid_json_bytes := JSON.stringify(ball_pit_dict).to_utf8_buffer()
	rigid_json_bytes.append(0)
	entries.append({ "tag": "rigid_bodies", "type": PBM_META_JSON, "data": rigid_json_bytes })

	# 6. Arbitrary Custom Node Metadata Lumps
	for node in custom_metadata_nodes:
		var tag_name: String = str(node.get_meta("poi_metadata_tag"))
		var payload_bytes := PackedByteArray()
		var ptype := PBM_META_JSON
		if node.has_meta("poi_metadata_payload"):
			var raw_val = node.get_meta("poi_metadata_payload")
			if raw_val is PackedByteArray:
				payload_bytes = raw_val
				ptype = PBM_META_RAW
			elif raw_val is String:
				payload_bytes = (raw_val as String).to_utf8_buffer()
				payload_bytes.append(0)
				ptype = PBM_META_STRING
			else:
				payload_bytes = JSON.stringify(raw_val).to_utf8_buffer()
				payload_bytes.append(0)
				ptype = PBM_META_JSON
		else:
			var c_dict := { "name": node.name }
			if node is Node3D:
				var xf := _get_world_transform(node as Node3D)
				c_dict["position"] = [xf.origin.x, xf.origin.y, xf.origin.z]
			for k in node.get_meta_list():
				if not k.begins_with("poi_"):
					c_dict[k] = node.get_meta(k)
			payload_bytes = JSON.stringify(c_dict).to_utf8_buffer()
			payload_bytes.append(0)
			ptype = PBM_META_JSON
		entries.append({ "tag": tag_name.substr(0, 31), "type": ptype, "data": payload_bytes })

	# 7. Patrol Sphere Entity
	var ent_name_bytes := "PatrolSphere".to_ascii_buffer()
	ent_name_bytes.resize(32)
	var ent_buf := PackedByteArray()
	ent_buf.resize(88)
	for bi in range(32): ent_buf[bi] = ent_name_bytes[bi]
	ent_buf.encode_u32(32, PBM_ENTITY_PATROL_SPHERE)
	ent_buf.encode_float(36, 0.35)
	ent_buf.encode_u32(40, 0xFF00C8FF) # Gold
	ent_buf.encode_float(44, 2.5)
	ent_buf.encode_u32(48, 3)
	ent_buf.encode_float(52, -3.0); ent_buf.encode_float(56, 1.2); ent_buf.encode_float(60, -1.0)
	ent_buf.encode_float(64, 0.0);  ent_buf.encode_float(68, 2.2); ent_buf.encode_float(72, -4.5)
	ent_buf.encode_float(76, 3.0);  ent_buf.encode_float(80, 1.2); ent_buf.encode_float(84, 0.5)
	entries.append({ "tag": "entities", "type": PBM_META_ENTITY, "data": ent_buf })

	return entries

## ── Particle emitters (standard lump "emitters") ────────────────────────────
##
## An emitter is authored as an ordinary GPUParticles3D node. The exporter maps
## the ParticleProcessMaterial and the draw-pass quad onto the format's fields,
## so what the author previews in the editor is what the retro runtime plays
## back. Fields Godot has no concept for (a cylinder-locked billboard, the
## lateral wobble, the phase-aligned burst) are reachable as explicit `poi_*`
## node metadata — an override list, not a second authoring path:
##   poi_additive (bool)  force additive blending
##   poi_y_locked (bool)  cylinder billboard instead of camera-facing
##   poi_wobble_amp (float, m) / poi_wobble_freq (float, Hz)
##   poi_knee (float, 0..1)  where the size/colour mid key sits
##   poi_seed (int)          fixes the particle field
## Everything else comes from the node itself.
static func _collect_emitters_recursive(node: Node, out: Array[GPUParticles3D]) -> void:
	if node == null:
		return
	if node is GPUParticles3D:
		out.append(node as GPUParticles3D)
	for child in node.get_children():
		_collect_emitters_recursive(child, out)

## Samples a ParticleProcessMaterial curve texture (Godot 4 stores curves as
## CurveTexture/Curve) at t, falling back when the author set no curve.
static func _curve_at(tex: Texture2D, t: float, fallback: float) -> float:
	if tex is CurveTexture and (tex as CurveTexture).curve != null:
		return (tex as CurveTexture).curve.sample(clampf(t, 0.0, 1.0))
	return fallback

## Samples a colour ramp (GradientTexture1D) at t.
static func _ramp_at(tex: Texture2D, t: float, fallback: Color) -> Color:
	if tex is GradientTexture1D and (tex as GradientTexture1D).gradient != null:
		return (tex as GradientTexture1D).gradient.sample(clampf(t, 0.0, 1.0))
	return fallback

## Packs a Godot colour into the format's 0xAABBGGRR vertex-colour word.
static func _pack_rgba(c: Color) -> int:
	var r: int = int(clampf(c.r, 0.0, 1.0) * 255.0 + 0.5)
	var g: int = int(clampf(c.g, 0.0, 1.0) * 255.0 + 0.5)
	var b: int = int(clampf(c.b, 0.0, 1.0) * 255.0 + 0.5)
	var a: int = int(clampf(c.a, 0.0, 1.0) * 255.0 + 0.5)
	return r | (g << 8) | (b << 16) | (a << 24)

## Where the size/colour mid key sits: the alpha ramp's peak when there is one,
## otherwise the scale curve's peak, otherwise the middle. A particle that fades
## in and out peaks somewhere, and that is exactly the knee the two-segment
## interpolation wants.
static func _emitter_knee(mat: ParticleProcessMaterial) -> float:
	var ramp: Texture2D = mat.color_ramp if mat != null else null
	var best_t := 0.5
	var best_v := -1.0
	if ramp is GradientTexture1D and (ramp as GradientTexture1D).gradient != null:
		for i in range(33):
			var t := float(i) / 32.0
			var v := (ramp as GradientTexture1D).gradient.sample(t).a
			if v > best_v:
				best_v = v
				best_t = t
	else:
		var sc: Texture2D = mat.scale_curve if mat != null else null
		if sc is CurveTexture and (sc as CurveTexture).curve != null:
			for i in range(33):
				var t := float(i) / 32.0
				var v := (sc as CurveTexture).curve.sample(t)
				if v > best_v:
					best_v = v
					best_t = t
	return clampf(best_t, 0.05, 0.95)

## Maps one authored GPUParticles3D onto the format's emitter fields.
static func _emitter_from_node(node: GPUParticles3D) -> Dictionary:
	var mat := node.process_material as ParticleProcessMaterial
	var draw_mesh: Mesh = node.draw_pass_1
	var draw_mat: Material = node.material_override
	if draw_mat == null and draw_mesh != null and draw_mesh.get_surface_count() > 0:
		draw_mat = draw_mesh.surface_get_material(0)

	var albedo: Texture2D = null
	var alpha_mode := PBM_ALPHA_NONE
	var additive := false
	if draw_mat is StandardMaterial3D:
		var sm := draw_mat as StandardMaterial3D
		albedo = sm.albedo_texture
		alpha_mode = material_alpha_mode(sm)
		additive = sm.blend_mode == BaseMaterial3D.BLEND_MODE_ADD

	# Atlas: Godot animates a particle sprite sheet from the MATERIAL's frame
	# grid (`particles_anim_h_frames`/`_v_frames`, only honoured in the
	# BILLBOARD_PARTICLES mode), and `anim_speed` counts complete cycles over
	# one particle lifetime — which is the same unit the format's `anim_loops`
	# uses. A fractional speed below one cycle cannot be expressed (the runtime
	# walks a whole number of loops over the lifetime) and is rounded up to one.
	var cols := 1
	var rows := 1
	var anim_loops := 1
	if draw_mat is StandardMaterial3D:
		var sm := draw_mat as StandardMaterial3D
		if sm.billboard_mode == BaseMaterial3D.BILLBOARD_PARTICLES:
			cols = maxi(1, sm.particles_anim_h_frames)
			rows = maxi(1, sm.particles_anim_v_frames)
	if mat != null:
		var cycles := (mat.anim_speed_min + mat.anim_speed_max) * 0.5
		anim_loops = maxi(1, int(round(cycles)))

	# Quad geometry: the format describes the particle as a height plus an
	# aspect ratio, both in metres of world space.
	var quad_h := 0.5
	var aspect := 1.0
	if draw_mesh is QuadMesh:
		var qs: Vector2 = (draw_mesh as QuadMesh).size
		quad_h = maxf(qs.y, 0.0001)
		aspect = maxf(qs.x, 0.0001) / quad_h

	var knee := _emitter_knee(mat)
	var tint: Color = mat.color if mat != null else Color.WHITE
	var ramp: Texture2D = mat.color_ramp if mat != null else null
	var c_start := _ramp_at(ramp, 0.0, Color.WHITE) * tint
	var c_mid := _ramp_at(ramp, knee, Color.WHITE) * tint
	var c_end := _ramp_at(ramp, 1.0, Color.WHITE) * tint

	var scale_curve: Texture2D = mat.scale_curve if mat != null else null
	var s0 := _curve_at(scale_curve, 0.0, 1.0)
	var mid_scale := _curve_at(scale_curve, knee, s0)
	var end_scale := _curve_at(scale_curve, 1.0, s0)
	var base_scale: float = maxf(s0, 0.0001)

	var lifetime: float = maxf(node.lifetime, 0.01)
	var life_rand: float = clampf(mat.lifetime_randomness, 0.0, 0.95) if mat != null else 0.0
	var spread_deg: float = mat.spread if mat != null else 0.0
	var dir_local: Vector3 = mat.direction if mat != null else Vector3.RIGHT

	var xf := _get_world_transform(node)
	var dir_world := (xf.basis * dir_local)
	if dir_world.length_squared() < 0.000001:
		dir_world = Vector3.UP
	dir_world = dir_world.normalized()

	var flags := 0
	if additive:
		flags |= PBM_EMIT_ADDITIVE
	if node.has_meta("poi_additive") and bool(node.get_meta("poi_additive")):
		flags |= PBM_EMIT_ADDITIVE
	if mat != null and mat.particle_flag_align_y:
		flags |= PBM_EMIT_VEL_ALIGN
	if node.has_meta("poi_y_locked") and bool(node.get_meta("poi_y_locked")):
		flags |= PBM_EMIT_Y_LOCKED
	if node.one_shot:
		flags |= PBM_EMIT_PHASE_ALIGN

	var count: int = clampi(node.amount, 1, PBM_EMIT_MAX_PER_EMITTER)
	var seed_value: int = node.seed if node.use_fixed_seed else absi(hash(str(node.name)) & 0x7FFFFFFF)

	return {
		"name": str(node.name).substr(0, 23),
		"pos": xf.origin,
		"dir": dir_world,
		"spread": deg_to_rad(clampf(spread_deg, 0.0, 180.0)),
		"speed_min": mat.initial_velocity_min if mat != null else 0.0,
		"speed_max": mat.initial_velocity_max if mat != null else 0.0,
		"life_min": lifetime * (1.0 - life_rand),
		"life_max": lifetime,
		"gravity": mat.gravity if mat != null else Vector3.ZERO,
		"damping": ((mat.damping_min + mat.damping_max) * 0.5) if mat != null else 0.0,
		"size_min": quad_h * (mat.scale_min if mat != null else 1.0) * s0,
		"size_max": quad_h * (mat.scale_max if mat != null else 1.0) * s0,
		"size_mid": mid_scale / base_scale,
		"size_end": end_scale / base_scale,
		"aspect": aspect,
		"angle_min": deg_to_rad(mat.angle_min) if mat != null else 0.0,
		"angle_max": deg_to_rad(mat.angle_max) if mat != null else 0.0,
		"spin_min": deg_to_rad(mat.angular_velocity_min) if mat != null else 0.0,
		"spin_max": deg_to_rad(mat.angular_velocity_max) if mat != null else 0.0,
		"wobble_amp": float(node.get_meta("poi_wobble_amp")) if node.has_meta("poi_wobble_amp") else 0.0,
		"wobble_freq": float(node.get_meta("poi_wobble_freq")) if node.has_meta("poi_wobble_freq") else 0.0,
		"spawn_radius": mat.emission_sphere_radius if (mat != null and mat.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_SPHERE) else 0.0,
		"knee": float(node.get_meta("poi_knee")) if node.has_meta("poi_knee") else knee,
		"color_start": _pack_rgba(c_start),
		"color_mid": _pack_rgba(c_mid),
		"color_end": _pack_rgba(c_end),
		"count": count,
		"flags": flags,
		"atlas_cols": cols,
		"atlas_rows": rows,
		"anim_loops": anim_loops,
		"seed": (int(node.get_meta("poi_seed")) if node.has_meta("poi_seed") else seed_value) & 0xFFFFFFFF,
		"texture": PBM_EMITTER_GLOW_TEXTURE,
		"albedo": albedo,
		"alpha_mode": alpha_mode,
	}

## Packs the collected emitters into the standard "emitters" lump, registering
## each emitter's texture as it goes.
static func _emitters_metadata_entry(emitter_nodes: Array[GPUParticles3D], textures: Array,
		tex_map: Dictionary) -> Dictionary:
	var records: Array[Dictionary] = []
	for node in emitter_nodes:
		records.append(_emitter_from_node(node))

	var buf := PackedByteArray()
	buf.resize(16 + records.size() * PBM_EMITTER_SIZE_BYTES)
	buf.encode_u32(0, 0x54494D45)          # "EMIT"
	buf.encode_u32(4, 1)                   # lump version
	buf.encode_u32(8, records.size())
	buf.encode_u32(12, 0)

	var off := 16
	for rec in records:
		var tex_id := PBM_EMITTER_GLOW_TEXTURE
		if rec.get("albedo") != null:
			tex_id = _register_texture(textures, tex_map, rec["albedo"],
				int(rec.get("alpha_mode", PBM_ALPHA_NONE)), true)
		var name_bytes: PackedByteArray = (rec["name"] as String).to_ascii_buffer()
		name_bytes.resize(24)
		for bi in range(24):
			buf[off + bi] = name_bytes[bi]
		var pos: Vector3 = rec["pos"]
		buf.encode_float(off + 0x18, pos.x); buf.encode_float(off + 0x1C, pos.y); buf.encode_float(off + 0x20, pos.z)
		var dir: Vector3 = rec["dir"]
		buf.encode_float(off + 0x24, dir.x); buf.encode_float(off + 0x28, dir.y); buf.encode_float(off + 0x2C, dir.z)
		buf.encode_float(off + 0x30, rec["spread"])
		buf.encode_float(off + 0x34, rec["speed_min"])
		buf.encode_float(off + 0x38, rec["speed_max"])
		buf.encode_float(off + 0x3C, rec["life_min"])
		buf.encode_float(off + 0x40, rec["life_max"])
		var grav: Vector3 = rec["gravity"]
		buf.encode_float(off + 0x44, grav.x); buf.encode_float(off + 0x48, grav.y); buf.encode_float(off + 0x4C, grav.z)
		buf.encode_float(off + 0x50, rec["damping"])
		buf.encode_float(off + 0x54, rec["size_min"])
		buf.encode_float(off + 0x58, rec["size_max"])
		buf.encode_float(off + 0x5C, rec["size_mid"])
		buf.encode_float(off + 0x60, rec["size_end"])
		buf.encode_float(off + 0x64, rec["aspect"])
		buf.encode_float(off + 0x68, rec["angle_min"])
		buf.encode_float(off + 0x6C, rec["angle_max"])
		buf.encode_float(off + 0x70, rec["spin_min"])
		buf.encode_float(off + 0x74, rec["spin_max"])
		buf.encode_float(off + 0x78, rec["wobble_amp"])
		buf.encode_float(off + 0x7C, rec["wobble_freq"])
		buf.encode_float(off + 0x80, rec["spawn_radius"])
		buf.encode_float(off + 0x84, rec["knee"])
		buf.encode_u32(off + 0x88, int(rec["color_start"]))
		buf.encode_u32(off + 0x8C, int(rec["color_mid"]))
		buf.encode_u32(off + 0x90, int(rec["color_end"]))
		buf.encode_u32(off + 0x94, tex_id)
		buf.encode_u16(off + 0x98, int(rec["count"]))
		buf.encode_u16(off + 0x9A, int(rec["flags"]))
		buf[off + 0x9C] = int(rec["atlas_cols"])
		buf[off + 0x9D] = int(rec["atlas_rows"])
		buf[off + 0x9E] = int(rec["anim_loops"])
		buf[off + 0x9F] = 0
		buf.encode_u32(off + 0xA0, int(rec["seed"]))
		off += PBM_EMITTER_SIZE_BYTES

	return { "tag": "emitters", "type": PBM_META_EMITTER, "data": buf }

## Concrete materialise for the GLB path, which reaches the converters through
## glTF `extras`: one holder node per emitter carrying the full record.
static func make_emitter_extras(node: GPUParticles3D) -> Dictionary:
	var rec := _emitter_from_node(node)
	var extras := rec.duplicate()
	extras.erase("albedo")
	extras.erase("alpha_mode")
	extras["pos"] = [rec["pos"].x, rec["pos"].y, rec["pos"].z]
	extras["dir"] = [rec["dir"].x, rec["dir"].y, rec["dir"].z]
	extras["gravity"] = [rec["gravity"].x, rec["gravity"].y, rec["gravity"].z]
	return { "poi_emitter": extras }

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
