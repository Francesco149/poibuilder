## test_pb_paint_topology.gd — painted faces through topology ops, and the
## per-material mapping contract (v0.9.182 scaling audit).
##
## Ops copy a face's MATERIAL onto the faces they create, but a fresh PBFace
## had no splat_bounds, so each new face mapped the source's WHOLE mask onto
## its own rect: extruding a painted floor showed the floor's paint squeezed
## onto every side face, and brushing a side repainted the floor through the
## shared material. The contract now (PBSplat.settle_derived_faces):
##   - a new face on a plane PARALLEL to its source (split half, inset ring,
##     extruded cap) inherits the source's mask rect — the paint continues;
##   - any other new face (extrude side, bevel band) gets the unpainted base;
##   - faces sharing one splat material share one mapping, so painting across
##     a split seam is seamless and splitting does not multiply materials.
## Also: detach keeps its faces' materials, and ops keep the author's UV2.
extends GutTest

const TOP_Y := 1.0

func _painted_cube() -> Dictionary:
	var mesh := PBMesh.create_cube(2.0)
	add_child_autofree(mesh)
	var data := mesh.pb_mesh_data
	PBSplat.ensure_mesh_splat_uv(data)
	var top := _face_with_normal(data, Vector3.UP)
	assert_gt(top, -1, "fixture: cube has a top face")
	var face := data.faces[top]
	var mat := PBSplat.ensure_face_owned_material(data, face)
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var layer := PBSplat.ensure_layer_for_texture(mat, tex, PBSplat.live_mask_resolution_for(data, face).x)
	PBSplat.paint_face_splat(data, face, mat, layer, Vector3(0.5, TOP_Y, 0.5), 0.4, 0.0, 1.0)
	mesh.rebuild()
	return {"mesh": mesh, "data": data, "face": face, "mat": mat, "layer": layer, "tex": tex}

func _face_with_normal(data: PBMeshData, wanted: Vector3) -> int:
	for fi in range(data.faces.size()):
		if PBMath.normal_from_positions(data.positions, data.faces[fi].get_indexes()).dot(wanted) > 0.99:
			return fi
	return -1

func _faces_wearing(data: PBMeshData, mat: Material) -> Array:
	var out: Array = []
	for f in data.faces:
		if data.get_face_material(f) == mat:
			out.append(f)
	return out

## The mask value a world-space point on the top plane reads through `bounds`.
func _mask_at(mat: ShaderMaterial, layer: int, bounds: Dictionary, p: Vector3) -> float:
	var img := PBSplat.get_layer_mask_image(mat, layer)
	var u := ((bounds["u"] as Vector3).dot(p) - float(bounds["min_u"])) / float(bounds["range_u"])
	var v := ((bounds["v"] as Vector3).dot(p) - float(bounds["min_v"])) / float(bounds["range_v"])
	var x := clampi(int(round(u * float(img.get_width() - 1))), 0, img.get_width() - 1)
	var y := clampi(int(round(v * float(img.get_height() - 1))), 0, img.get_height() - 1)
	return img.get_pixel(x, y).r

func _bounds_eq(a: PackedFloat32Array, b: Dictionary) -> bool:
	return a.size() == 4 and absf(a[0] - float(b["min_u"])) < 0.0001 and absf(a[1] - float(b["max_u"])) < 0.0001 \
			and absf(a[2] - float(b["min_v"])) < 0.0001 and absf(a[3] - float(b["max_v"])) < 0.0001

# ── Derived faces ───────────────────────────────────────────────────────────

func test_extrude_keeps_paint_on_the_cap_and_none_on_the_sides() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var src_bounds := PBSplat.get_face_planar_bounds(data, f["face"])
	var side_mat := data.get_face_material(data.faces[_face_with_normal(data, Vector3.RIGHT)])
	var cmd := CmdMeshOp.new(data, "Extrude")
	var res := PBMeshOps.extrude_faces(data, PackedInt32Array([data.faces.find(f["face"])]), 0.5)
	assert_true(res.get("ok", false), "fixture: extrude succeeds")
	cmd.capture_after()
	var caps: PackedInt32Array = res["cap_face_ids"]
	assert_eq(caps.size(), 1)
	var cap := data.faces[caps[0]]
	assert_eq(data.get_face_material(cap), f["mat"], "the cap keeps the paint")
	assert_true(_bounds_eq(cap.splat_bounds, src_bounds), "through the same mask rect")
	for fid in res["new_face_ids"]:
		if caps.has(fid):
			continue
		var m := data.get_face_material(data.faces[fid])
		assert_false(PBSplat.is_splat_material(m), "an extruded side shows no paint")
		assert_eq(m, side_mat, "it wears the cube's own base material (no new material)")
	assert_eq(_faces_wearing(data, f["mat"]).size(), 1, "only the cap wears the splat material")
	# The undo "after" snapshot carries the settled state (redo restores it).
	var after_cap := cmd.after.faces[caps[0]]
	assert_true(after_cap.splat_bounds.size() == 4, "the redo snapshot is settled")

func test_subdivide_keeps_one_material_and_one_mapping() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var src_bounds := PBSplat.get_face_planar_bounds(data, f["face"])
	var probe := Vector3(0.5, TOP_Y, 0.5)
	var before := _mask_at(f["mat"], f["layer"], src_bounds, probe)
	assert_gt(before, 0.5, "fixture: the probe point is painted")
	var cmd := CmdMeshOp.new(data, "Subdivide")
	var res := PBMeshOps.subdivide_faces(data, PackedInt32Array([data.faces.find(f["face"])]))
	assert_true(res.get("ok", false), "fixture: subdivide succeeds")
	cmd.capture_after()
	var pieces := _faces_wearing(data, f["mat"])
	assert_gt(pieces.size(), 1, "the split pieces all keep the ONE splat material")
	for piece in pieces:
		assert_true(_bounds_eq((piece as PBFace).splat_bounds, src_bounds), "each maps the original rect")
	# The mapping is unchanged: CUSTOM0 coordinates of every piece's corners
	# are what the original rect gives for those positions.
	PBSplat.ensure_mesh_splat_uv(data)
	for piece in pieces:
		for idx in (piece as PBFace).get_distinct_indexes():
			var p := data.positions[idx]
			var want := Vector2(((src_bounds["u"] as Vector3).dot(p) - float(src_bounds["min_u"])) / float(src_bounds["range_u"]),
					((src_bounds["v"] as Vector3).dot(p) - float(src_bounds["min_v"])) / float(src_bounds["range_v"]))
			assert_true(data.splat_uvs[idx].is_equal_approx(want), "corner %s keeps its mask coordinate" % p)
	assert_almost_eq(_mask_at(f["mat"], f["layer"], src_bounds, probe), before, 0.001, "the paint did not move")

func test_inset_keeps_the_whole_region_on_one_material() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var cmd := CmdMeshOp.new(data, "Inset")
	var res := PBMeshOps.inset_faces(data, PackedInt32Array([data.faces.find(f["face"])]), 0.3)
	assert_true(res.get("ok", false), "fixture: inset succeeds")
	cmd.capture_after()
	for fid in res["new_face_ids"]:
		assert_eq(data.get_face_material(data.faces[fid]), f["mat"],
				"inner face and ring are coplanar: all keep the paint")

func test_bevel_band_drops_the_paint() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var cmd := CmdMeshOp.new(data, "Bevel")
	var res := PBMeshOps.bevel_faces(data, PackedInt32Array([data.faces.find(f["face"])]), 0.1, 1)
	assert_true(res.get("ok", false), "fixture: bevel succeeds")
	cmd.capture_after()
	for fid in res["new_face_ids"]:
		var face := data.faces[fid]
		var n := PBMath.normal_from_positions(data.positions, face.get_indexes())
		var m := data.get_face_material(face)
		if n.dot(Vector3.UP) > 0.999:
			assert_eq(m, f["mat"], "the beveled top keeps its paint")
		else:
			assert_false(PBSplat.is_splat_material(m), "an angled bevel face shows no paint")

# ── One material, one mapping ───────────────────────────────────────────────

func test_ownership_shares_same_mapping_and_privatises_different_mapping() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	PBMeshOps.subdivide_faces(data, PackedInt32Array([data.faces.find(f["face"])]))
	# (direct op call: settle by hand, as CmdMeshOp would)
	var pieces := _faces_wearing(data, f["mat"])
	var sources := {"faces": {}, "by_mat": {f["mat"]: [{"normal": Vector3.UP,
			"bounds": (f["face"] as PBFace).splat_bounds}]}}
	PBSplat.settle_derived_faces(data, sources)
	assert_eq(PBSplat.ensure_face_owned_material(data, pieces[0]), f["mat"],
			"a piece sharing the material through the same rect keeps it")
	var side := data.faces[_face_with_normal(data, Vector3.RIGHT)]
	data.set_face_material(side, f["mat"])
	var owned := PBSplat.ensure_face_owned_material(data, side)
	assert_ne(owned, f["mat"], "a face mapping it differently gets a private copy")

func test_brush_on_a_differently_mapped_face_never_reaches_the_other() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var mesh: PBMesh = f["mesh"]
	var side_idx := _face_with_normal(data, Vector3.RIGHT)
	data.set_face_material(data.faces[side_idx], f["mat"])  # shared, different rect
	mesh.rebuild()
	var top_mask_before := PBSplat.get_layer_mask_image(f["mat"], f["layer"]).get_data()
	var ctrl := PBPaintController.new()
	ctrl.set_mode(PBPaintController.Mode.PAINT)
	ctrl.paint_texture = f["tex"]
	ctrl.update_cursor(Vector3(1.0, 0.0, 0.0), Vector3.RIGHT, mesh, side_idx)
	ctrl.begin_stroke()
	ctrl.end_stroke()
	assert_ne(data.get_face_material(data.faces[side_idx]), f["mat"],
			"the brush privatised the side's material before painting")
	assert_eq(hash(PBSplat.get_layer_mask_image(f["mat"], f["layer"]).get_data()), hash(top_mask_before),
			"the stroke on the side left the top's mask untouched")

func test_growing_one_piece_moves_its_siblings_to_the_grown_rect() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var src_bounds := PBSplat.get_face_planar_bounds(data, f["face"])
	var cmd := CmdMeshOp.new(data, "Subdivide")
	PBMeshOps.subdivide_faces(data, PackedInt32Array([data.faces.find(f["face"])]))
	cmd.capture_after()
	var pieces := _faces_wearing(data, f["mat"])
	var probe := Vector3(0.5, TOP_Y, 0.5)
	var before := _mask_at(f["mat"], f["layer"], src_bounds, probe)
	# Pull one piece's corners outward past the original rect, then paint it:
	# the paint-time expansion re-anchors the masks for the WHOLE material.
	var grown_piece: PBFace = pieces[0]
	for idx in grown_piece.get_distinct_indexes():
		var p := data.positions[idx]
		data.positions[idx] = Vector3(p.x * 1.5, p.y, p.z * 1.5)
	data.invalidate_caches()
	var corner := data.positions[grown_piece.get_distinct_indexes()[0]]
	PBSplat.paint_face_splat(data, grown_piece, f["mat"], f["layer"], corner, 0.2, 0.0, 1.0)
	var grown := PBSplat.get_face_planar_bounds(data, grown_piece)
	assert_gt(float(grown["range_u"]), float(src_bounds["range_u"]), "fixture: the rect grew")
	for piece in pieces:
		assert_true(_bounds_eq((piece as PBFace).splat_bounds, grown), "every piece moved to the grown rect")
	assert_almost_eq(_mask_at(f["mat"], f["layer"], grown, probe), before, 0.02,
			"existing paint stays at its world position for every piece")

func test_stamp_across_split_pieces_is_written_once() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var cmd := CmdMeshOp.new(data, "Subdivide")
	PBMeshOps.subdivide_faces(data, PackedInt32Array([data.faces.find(f["face"])]))
	cmd.capture_after()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	# Centred on the split: the footprint covers every piece.
	var painted := PBSplat.paste_decal(data, Vector3(0, TOP_Y, 0), Vector3.UP, 0.0, 1.0, 0.5, img)
	assert_eq(painted, 1, "one shared window, one write")
	var decal := PBSplat.get_decal_layer_image(f["mat"])
	var max_a := 0.0
	for y in range(decal.get_height()):
		for x in range(decal.get_width()):
			max_a = maxf(max_a, decal.get_pixel(x, y).a)
	assert_almost_eq(max_a, 0.5, 0.02, "a 50 % stamp is 50 %, not pasted twice")

# ── Detach and UV2 ──────────────────────────────────────────────────────────

func test_detach_keeps_textured_and_painted_materials() -> void:
	var f := _painted_cube()
	var data: PBMeshData = f["data"]
	var side_idx := _face_with_normal(data, Vector3.RIGHT)
	var brick := StandardMaterial3D.new()
	brick.albedo_color = Color(0.7, 0.2, 0.1)
	data.set_face_material(data.faces[side_idx], brick)
	var top_idx := data.faces.find(f["face"])
	var res := PBMeshOps.detach_faces(data, PackedInt32Array([top_idx, side_idx]))
	assert_true(res.get("ok", false), "fixture: detach succeeds")
	var det: PBMeshData = res["detached"]
	var saw_brick := false
	var saw_paint := false
	for face in det.faces:
		var m := det.get_face_material(face)
		if m == brick:
			saw_brick = true
		elif PBSplat.is_splat_material(m):
			saw_paint = true
			assert_ne(m, f["mat"], "the detached mesh owns its paint")
			assert_eq(hash(PBSplat.get_layer_mask_image(m, f["layer"]).get_data()),
					hash(PBSplat.get_layer_mask_image(f["mat"], f["layer"]).get_data()), "with the same pixels")
	assert_true(saw_brick, "the textured face keeps its material")
	assert_true(saw_paint, "the painted face keeps its paint")

func test_ops_keep_the_authors_uv2_aligned() -> void:
	var data := PBMeshData.create_cube(2.0)
	data.textures1 = PackedVector2Array()
	for i in range(data.positions.size()):
		data.textures1.append(Vector2(float(i) * 0.01, 0.5))
	var top := _face_with_normal(data, Vector3.UP)
	assert_true(PBMeshOps.extrude_faces(data, PackedInt32Array([top]), 0.5).get("ok", false))
	assert_eq(data.textures1.size(), data.positions.size(), "extrude keeps UV2 one-per-vertex")
	var side := _face_with_normal(data, Vector3.RIGHT)
	assert_true(PBMeshOps.delete_faces(data, PackedInt32Array([side])).get("ok", false))
	assert_eq(data.textures1.size(), data.positions.size(), "compaction keeps UV2 aligned")
	var res := PBMeshOps.detach_faces(data, PackedInt32Array([0]))
	var det: PBMeshData = res["detached"]
	assert_eq(det.textures1.size(), det.positions.size(), "detach carries UV2")
