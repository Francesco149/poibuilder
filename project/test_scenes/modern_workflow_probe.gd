## Modern (non-retro) workflow probe — photorealistic asset smoke test.
##
## Mimics a user who is NOT using the retro pipeline: imports 4k PBR GLTF
## props, converts one to an editable PBMesh (poibuilderize), edits it,
## splat-paints a floor with a 4k texture, exports the modern .glb path, and
## checks the UV2/lightmap contract. Prints a findings report.
##
## Run from project/:  godot-mono --headless -s test_scenes/modern_workflow_probe.gd
##
## The 4k assets are machine-local (project/test_scenes/modern_assets/,
## gitignored — see .gitignore). Missing assets => the probe prints a skip
## notice and exits 0, so CI and fresh checkouts stay clean.
extends SceneTree

const ASSET_SCENES := [
	"res://test_scenes/modern_assets/marble_bust_01_4k/marble_bust_01_4k.gltf",
	"res://test_scenes/modern_assets/gothic_statue_4k/gothic_statue_4k.gltf",
	"res://test_scenes/modern_assets/coastal_cliff_02_4k/coastal_cliff_02_4k.gltf",
]
const EXPORT_PATH := "/tmp/pb_modern_probe_export.glb"

var _issues: PackedStringArray = []
var _notes: PackedStringArray = []
var _oks: PackedStringArray = []

func _init() -> void:
	if not ResourceLoader.exists(ASSET_SCENES[0]):
		print("SKIP: modern assets not present (project/test_scenes/modern_assets/ is machine-local).")
		print("Extract the 4k GLTF zips there to run the probe.")
		quit(0)
		return

	print("== PoiBuilder modern workflow probe ==")
	_step_inspect_assets()
	_step_poibuilderize_and_edit()
	_step_splat_floor_and_modern_export()
	_step_lightmap_contract()

	# The picking check needs live scene-tree transforms, so it runs deferred
	# (inside the running frame loop) and prints the findings + quits itself.
	_step_creation_pick_cost.call_deferred()

func _finish() -> void:
	print("\n---- FINDINGS ----")
	for ok in _oks:
		print("  OK    ", ok)
	for note in _notes:
		print("  NOTE  ", note)
	for issue in _issues:
		print("  ISSUE ", issue)
	print("---- %d ok / %d notes / %d issues ----" % [_oks.size(), _notes.size(), _issues.size()])
	quit(1 if not _issues.is_empty() else 0)

func _fail(msg: String) -> void:
	_issues.append(msg)
	print("  ISSUE ", msg)

func _ok(msg: String) -> void:
	_oks.append(msg)
	print("  OK    ", msg)

func _note(msg: String) -> void:
	_notes.append(msg)
	print("  NOTE  ", msg)

# ------------------------------------------------------------------
# 1. Import + inspect: do the 4k PBR sets arrive as usable materials?
# ------------------------------------------------------------------
func _step_inspect_assets() -> void:
	print("\n[1] Loading imported 4k GLTF scenes")
	for path in ASSET_SCENES:
		if not ResourceLoader.exists(path):
			_fail("Asset not imported: %s" % path)
			continue
		var t0 := Time.get_ticks_msec()
		var ps: PackedScene = load(path)
		var load_ms := Time.get_ticks_msec() - t0
		if ps == null:
			_fail("Failed to load %s" % path)
			continue
		var node := ps.instantiate()
		var mis: Array[Node] = []
		_find_mesh_instances(node, mis)
		var tris := 0
		var mat: Material = null
		for mi in mis:
			var m: Mesh = (mi as MeshInstance3D).mesh
			if m == null:
				continue
			for s in range(m.get_surface_count()):
				tris += int(round(m.surface_get_arrays(s)[Mesh.ARRAY_INDEX].size() / 3.0)) if m.surface_get_arrays(s)[Mesh.ARRAY_INDEX] != null else 0
				if mat == null:
					mat = m.surface_get_material(s)
		var tex_info := ""
		if mat is StandardMaterial3D:
			var sm := mat as StandardMaterial3D
			tex_info = "albedo=%s" % _tex_desc(sm.albedo_texture)
			if sm.normal_texture != null:
				tex_info += " normal=%s" % _tex_desc(sm.normal_texture)
			else:
				_note("%s: first material has NO normal texture assigned" % path.get_file())
		print("  %s: %d mesh nodes, %d tris, load %d ms — %s" % [path.get_file(), mis.size(), tris, load_ms, tex_info])
		if tris > 100000:
			_note("%s is high-poly (%d tris) — poibuilderize is tri-per-face, editing this size is impractical (keep as MeshInstance3D siblings)" % [path.get_file(), tris])
		node.free()

func _find_mesh_instances(node: Node, out: Array[Node]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_find_mesh_instances(child, out)

func _tex_desc(tex: Texture2D) -> String:
	if tex == null:
		return "<null>"
	var img := tex.get_image()
	if img == null:
		return tex.resource_path.get_file() + " (no image)"
	return "%s %dx%d %s" % [tex.resource_path.get_file(), img.get_width(), img.get_height(), img.get_format()]

# ------------------------------------------------------------------
# 2. Poibuilderize + edit: does conversion keep the authored 4k look?
# ------------------------------------------------------------------
func _step_poibuilderize_and_edit() -> void:
	print("\n[2] Poibuilderize the smallest asset + edit smoke")
	var ps: PackedScene = load(ASSET_SCENES[0])
	if ps == null:
		return
	var node := ps.instantiate()
	var mis: Array[Node] = []
	_find_mesh_instances(node, mis)
	if mis.is_empty():
		_fail("No MeshInstance3D in %s" % ASSET_SCENES[0])
		node.free()
		return

	# Pick the mesh node with the fewest triangles (sculpts are high-poly).
	var best: MeshInstance3D = null
	var best_tris := 999999999
	for mi in mis:
		var m: Mesh = (mi as MeshInstance3D).mesh
		var tris := 0
		for s in range(m.get_surface_count()):
			var idx: PackedInt32Array = m.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
			if idx != null:
				tris += idx.size() / 3
		if tris < best_tris:
			best_tris = tris
			best = mi
	print("  converting %s (%d tris)" % [best.name, best_tris])

	var t0 := Time.get_ticks_msec()
	var pb: PBMesh = PBObjectOps.poibuilderize(best)
	var conv_ms := Time.get_ticks_msec() - t0
	if pb == null:
		_fail("poibuilderize returned null")
		node.free()
		return
	print("  poibuilderize: %d faces, %d verts, %d ms" % [pb.pb_mesh_data.faces.size(), pb.pb_mesh_data.positions.size(), conv_ms])
	if conv_ms > 2000:
		_note("poibuilderize took %d ms for %d source tris (~%.1f ms/ktri) — GDScript tri-per-face conversion is slow for sculpt assets; large props stay MeshInstance3D" % [conv_ms, best_tris, conv_ms / (best_tris / 1000.0)])
	if pb.pb_mesh_data.faces.size() > best_tris * 4:
		_note("poibuilderize exploded face count (%d -> %d): tri-per-face privacy, expected but heavy for sculpt assets" % [best_tris, pb.pb_mesh_data.faces.size()])
	elif best_tris > 100 and pb.pb_mesh_data.faces.size() < best_tris * 0.5:
		_fail("poibuilderize dropped most triangles (%d -> %d faces) — degenerate check is eating real geometry" % [best_tris, pb.pb_mesh_data.faces.size()])
	_ok("poibuilderize completed (%d ms)" % conv_ms)

	var md := pb.pb_mesh_data

	# Authored UV1 must survive as manual (non-retro users have real unwraps)
	var all_manual := true
	for f in md.faces:
		if f != null and not f.manual_uv:
			all_manual = false
			break
	if all_manual:
		_ok("all converted faces carry manual_uv=true (auto-UV refresh will not overwrite the authored unwrap)")
	else:
		_fail("some converted faces are NOT manual_uv — a rebuild would reproject the authored 4k unwrap to planar")

	# Tangents must ride along (normal maps) — regression guard for the 0.9.135 fix
	if md.tangents.size() == md.positions.size() * 4 and md.tangents.size() > 0:
		_ok("tangents preserved through poibuilderize (%d floats)" % md.tangents.size())
	else:
		_fail("tangents lost in poibuilderize: %d floats for %d verts" % [md.tangents.size(), md.positions.size()])

	# Edit smoke: move vertices + rebuild; authored UV1 must not move.
	var uv_before := md.textures0.duplicate()
	for i in range(mini(8, md.positions.size())):
		md.positions[i] += Vector3(0.01, 0, 0)
	pb.rebuild()
	var uv_drift := false
	for i in range(uv_before.size()):
		if md.textures0[i].distance_squared_to(uv_before[i]) > 0.000001:
			uv_drift = true
			break
	if uv_drift:
		_fail("rebuild moved UV1 on manual faces — authored unwrap is not stable under edits")
	else:
		_ok("rebuild leaves authored UV1 untouched (manual_uv respected)")

	# Mesh op smoke: extrude the first face along its normal, then rebuild
	if md.faces.size() > 0:
		var op_t0 := Time.get_ticks_msec()
		var res := PBMeshOps.extrude_faces(md, PackedInt32Array([0]), 0.05)
		var op_ms := Time.get_ticks_msec() - op_t0
		if res.is_empty():
			_note("extrude_faces returned empty on converted mesh face 0")
		else:
			_ok("extrude_faces works on a poibuilderized sculpt face (%d ms)" % op_ms)
		pb.rebuild()

	if is_instance_valid(pb):
		pb.free()
	node.free()

# ------------------------------------------------------------------
# 3. Splat paint a floor + modern .glb export round-trip
# ------------------------------------------------------------------
func _step_splat_floor_and_modern_export() -> void:
	print("\n[3] Splat-painted floor + modern glTF export")
	var floor_mesh := PBMesh.create_cube(1.0)
	# Stretch into a deliberately elongated 8m x 0.1m x 2m slab
	for i in range(floor_mesh.pb_mesh_data.positions.size()):
		var p: Vector3 = floor_mesh.pb_mesh_data.positions[i]
		floor_mesh.pb_mesh_data.positions[i] = Vector3(p.x * 8.0, p.y * 0.1, p.z * 2.0)
	floor_mesh.name = "SplatFloor"
	var root := Node3D.new()
	root.add_child(floor_mesh)

	# Decal stamp on the floor — modern export must keep it as an ordinary node
	var stamps := Node3D.new()
	stamps.name = "PBStamps"
	floor_mesh.add_child(stamps)
	var stamp := MeshInstance3D.new()
	stamp.name = "Poster_0"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.8, 0.8)
	stamp.mesh = quad
	stamp.position = Vector3(2, 0.11, 0)
	stamp.set_meta("face_idx", 4)
	stamp.set_meta("anchor_center", Vector2(0.5, 0.5))
	stamp.set_meta("anchor_du", Vector2(0.1, 0.0))
	stamp.set_meta("anchor_dv", Vector2(0.0, 0.1))
	stamps.add_child(stamp)

	# Paint a splat in the MIDDLE of the big top face using a 4k asset texture.
	var md := floor_mesh.pb_mesh_data
	var top_face: PBFace = null
	var top_y := -INF
	for f in md.faces:
		if f == null:
			continue
		var idxs := f.get_distinct_indexes()
		var cy := 0.0
		for i in idxs:
			cy += md.positions[i].y
		cy /= idxs.size()
		if cy > top_y:
			top_y = cy
			top_face = f
	var diff_path := "res://test_scenes/modern_assets/coastal_cliff_02_4k/textures/coastal_cliff_02_diff_4k.jpg"
	var layer_tex: Texture2D = load(diff_path) if ResourceLoader.exists(diff_path) else null
	var base_mat := StandardMaterial3D.new()
	var check_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	check_img.fill(Color(0.3, 0.3, 0.3))
	base_mat.albedo_texture = ImageTexture.create_from_image(check_img)
	md.set_face_material(top_face, PBSplat.create_splat_material(base_mat))
	if layer_tex != null:
		PBSplat.add_layer(md.get_face_material(top_face), layer_tex)
		PBSplat.paint_face_splat(md, top_face, md.get_face_material(top_face), 1,
				Vector3(0, top_y, 0), 0.35, 0.5, 1.0)
		_ok("splat-painted a 4k-textured layer onto an 8m x 2m elongated face (UV2 masks regenerated)")
	else:
		_note("cliff diffuse texture not found — exported floor keeps base material only")

	var t0 := Time.get_ticks_msec()
	var settings := PBMapExporter.ExportSettings.new()
	settings.export_mode = PBMapExporter.ExportMode.MODERN
	var err := PBMapExporter.export_map(root, EXPORT_PATH, settings)
	var export_ms := Time.get_ticks_msec() - t0
	if err != OK:
		_fail("modern export failed: %s" % error_string(err))
	else:
		_ok("modern .glb export succeeded (%d ms, %d KB)" % [export_ms, int(FileAccess.open(EXPORT_PATH, FileAccess.READ).get_length() / 1024.0)])

	# Round-trip: what does a modern engine (or Godot re-import) see?
	if err == OK:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var lerr := doc.append_from_file(EXPORT_PATH, state)
		if lerr != OK:
			_fail("re-import of exported .glb failed: %s" % error_string(lerr))
		else:
			var scene := doc.generate_scene(state)
			var found_uv2 := false
			var found_tex := false
			var mis: Array[Node] = []
			_find_mesh_instances(scene, mis)
			for mi in mis:
				var m: Mesh = (mi as MeshInstance3D).mesh
				for s in range(m.get_surface_count()):
					var arrays := m.surface_get_arrays(s)
					if arrays[Mesh.ARRAY_TEX_UV2] != null and arrays[Mesh.ARRAY_TEX_UV2].size() > 0:
						found_uv2 = true
					if arrays[Mesh.ARRAY_TEX_UV] != null and arrays[Mesh.ARRAY_TEX_UV].size() > 0:
						found_tex = true
			if found_tex:
				_ok("re-imported .glb carries UV1 (texture coordinates intact)")
			else:
				_fail("re-imported .glb lost UV1")
			if found_uv2:
				_note("re-imported .glb carries UV2 (splat face-planar coords ride along; harmless but useless to other engines)")
			else:
				_note("re-imported .glb has no UV2 (splat coords not exported)")
			# Decal stamp round trip
			var decal := scene.get_node_or_null("SplatFloor/PBStamps/Poster_0") as MeshInstance3D
			if decal != null and decal.mesh != null:
				_ok("decal quad survives the modern .glb round trip (node + mesh, at y=%.2f)" % decal.position.y)
			else:
				_fail("decal quad lost in the modern .glb round trip")
			# Material round trip — especially: what happens to a splat
			# ShaderMaterial (GLTF has no representation for custom shaders)?
			for mi in mis:
				var m: Mesh = (mi as MeshInstance3D).mesh
				for s in range(m.get_surface_count()):
					var mat: Material = m.surface_get_material(s)
					if mat == null:
						_fail("re-imported .glb surface %d.%d has NO material" % [mis.find(mi), s])
						continue
					var desc := "%s" % mat.get_class()
					if mat is StandardMaterial3D:
						var sm := mat as StandardMaterial3D
						desc += " albedo_tex=%s" % _tex_desc(sm.albedo_texture)
					if mat is ShaderMaterial:
						var base_tex: Texture2D = mat.get_shader_parameter("base_texture")
						desc += " base_texture=%s" % _tex_desc(base_tex)
					print("    surface %d.%d material: %s" % [mis.find(mi), s, desc])
					if mat is ShaderMaterial:
						_note("modern .glb export keeps custom ShaderMaterials ONLY as opaque GLTF extensions — splat paint does not survive to other engines (bake first)")
	root.free()

# ------------------------------------------------------------------
# 4. UV2 / lightmap contract (data-level; LightmapGI bakes are editor-GUI only)
# ------------------------------------------------------------------
func _step_lightmap_contract() -> void:
	print("\n[4] UV2 / LightmapGI contract")
	# (a) An authored lightmap unwrap on a splat-FREE mesh survives rebuilds.
	var cube := PBMeshData.create_cube(1.0)
	PBUv.refresh_mesh_uvs(cube, true)
	var authored := PackedVector2Array()
	authored.resize(cube.positions.size())
	authored.fill(Vector2(0.25, 0.75))
	cube.textures1 = authored
	cube.to_array_mesh()
	var survived := true
	for i in range(authored.size()):
		if cube.textures1[i].distance_squared_to(authored[i]) > 0.000001:
			survived = false
			break
	if survived:
		_ok("authored UV2 unwrap survives rebuild on splat-free meshes (LightmapGI-ready)")
	else:
		_fail("authored UV2 unwrap is clobbered by rebuild on splat-free meshes")
	# (b) Splat paint is independent of UV2: masks travel in the CUSTOM0
	# attribute, so the authored unwrap above must survive painting.
	cube.faces[0].splat_bounds = PackedFloat32Array([0, 1, 0, 1])
	var am := cube.to_array_mesh()
	var kept := true
	for i in range(authored.size()):
		if cube.textures1[i].distance_squared_to(authored[i]) > 0.000001:
			kept = false
			break
	if kept:
		_ok("paint no longer clobbers UV2 — splat masks ride in CUSTOM0, lightmap unwraps survive")
	else:
		_fail("paint clobbered the authored UV2 unwrap")
	if am.surface_get_count() > 0 and (am.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM0) != 0:
		_ok("splat masks are delivered as ARRAY_CUSTOM0 (exported to glTF as TEXCOORD_2)")
	else:
		_fail("splat mask custom attribute missing from the compiled mesh")

func _unhandled_key_input(_e) -> void:
	pass

# ------------------------------------------------------------------
# 5. Creation-hover picking cost (freeze regression guard)
# ------------------------------------------------------------------
## The creation tools' plain-mesh picking used to sweep EVERY triangle of
## every MeshInstance3D in the scene per mouse move (GDScript), which with a
## 943k-triangle prop stalled each drag ~10s. The plugin now caches face
## arrays per Mesh with a triangle budget and prefilters with a ray-AABB
## slab test. This step exercises the REAL plugin code against the real
## assets: a 943k-tri cliff (over budget) and a 17k-tri bust (under budget).
func _step_creation_pick_cost() -> void:
	print("\n[5] Creation-hover plain-mesh picking cost")

	var cliff_ps: PackedScene = load("res://test_scenes/modern_assets/coastal_cliff_02_4k/coastal_cliff_02_4k.gltf")
	var bust_ps: PackedScene = load("res://test_scenes/modern_assets/marble_bust_01_4k/marble_bust_01_4k.gltf")
	if cliff_ps == null or bust_ps == null:
		_note("assets missing — picking cost check skipped")
		_finish()
		return

	var root := Node3D.new()
	get_root().add_child(root)
	var cliff := cliff_ps.instantiate()
	cliff.position = Vector3(0, 0, 4.5)
	root.add_child(cliff)
	var bust := bust_ps.instantiate()
	bust.position = Vector3(-2.5, 0, 0)
	root.add_child(bust)
	var nodes: Array[Node] = []
	_find_mesh_instances(root, nodes)
	var cliff_mi: MeshInstance3D = null
	var bust_mi: MeshInstance3D = null
	for n in nodes:
		var mi := n as MeshInstance3D
		var aabb: AABB = mi.global_transform * mi.get_aabb()
		if aabb.size.length() > 20.0:
			cliff_mi = mi
		else:
			bust_mi = mi
	if cliff_mi == null or bust_mi == null:
		_fail("could not identify cliff/bust meshes for the picking check")
		_finish()
		return

	# Over-budget cliff: ray at its AABB center. Cold call pays the one-time
	# face extraction; warm calls must be sub-millisecond (budget skip).
	var cliff_aabb: AABB = cliff_mi.global_transform * cliff_mi.get_aabb()
	var center: Vector3 = cliff_aabb.get_center()
	var cam_o := center + Vector3(0, 0, 10.0)
	var ray_d := (center - cam_o).normalized()
	var t0 := Time.get_ticks_msec()
	var hit_cliff: Dictionary = PBPicking.pick_plain_mesh_surface(root, cam_o, ray_d, INF)
	var cold := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	for i in range(10):
		PBPicking.pick_plain_mesh_surface(root, cam_o, ray_d, INF)
	var warm := Time.get_ticks_msec() - t0
	print("  cliff (943k tris, over budget): cold=%d ms, warm 10x=%d ms, picked=%s" % [cold, warm, not hit_cliff.is_empty()])
	if warm > 50:
		_fail("over-budget mesh still costs %d ms / 10 hover picks — budget or AABB prefilter regressed" % warm)
	else:
		_ok("over-budget mesh excluded from hover picking (warm %d ms / 10 calls)" % warm)
	if cold > 3000:
		_note("one-time face extraction of the cliff took %d ms (per editor session, per Mesh) — expected for 943k tris" % cold)

	# Under-budget bust: must still be pickable, and quickly.
	var bust_aabb: AABB = bust_mi.global_transform * bust_mi.get_aabb()
	var bcenter: Vector3 = bust_aabb.get_center()
	var bcam := bcenter + Vector3(0, 0, 5.0)
	var bray := (bcenter - bcam).normalized()
	t0 = Time.get_ticks_msec()
	var hit_bust: Dictionary = PBPicking.pick_plain_mesh_surface(root, bcam, bray, INF)
	var bust_ms := Time.get_ticks_msec() - t0
	print("  bust (17k tris, under budget): pick=%d ms, hit=%s" % [bust_ms, not hit_bust.is_empty()])
	if hit_bust.is_empty():
		_fail("under-budget bust not picked — picker regressed")
	elif bust_ms > 100:
		_fail("under-budget pick too slow: %d ms" % bust_ms)
	else:
		_ok("under-budget prop picked in %d ms" % bust_ms)

	# Early-out: a max_t short of the cliff must return nothing.
	var early: Dictionary = PBPicking.pick_plain_mesh_surface(root, cam_o, ray_d, 1.0)
	if early.is_empty():
		_ok("max_t early-out works (nothing returned short of the surface)")
	else:
		_fail("early-out failed: returned a hit at %.2f beyond max_t=1.0" % cam_o.distance_to(early["point"]))
	get_root().remove_child(root)
	root.free()
	_finish()
