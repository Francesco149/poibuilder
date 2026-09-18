extends SceneTree

## Emitter verification probe (run under xvfb with the opengl3 driver):
##
##   xvfb-run -a godot-mono --rendering-driver opengl3 -s res://test_scenes/emitter_probe.gd
##
## Renders the sprite-sheet cases the emitter's Sheet Columns/Rows knobs were
## reported broken for, TWICE per case (two moments of the particle life, so a
## working flipbook visibly changes), to /tmp/emit_<case>_<step>.png:
##
##   a_single   the shipped 64x64 art, no sheet - one square particle
##   b_sheet3x1 a 192x64 sheet of 64x64 cells built from that art, each cell a
##              solid red/green/blue - a working flipbook shows ONE cell per
##              particle and walks through the colours over the lifetime
##   c_sheet1x3 the same as a 64x192 sheet with 3 ROWS
##   d_wide     a 128x64 (2:1) single frame - the particle must be 2:1 wide
##   e_tall_cells a 96x64 sheet of 32x64 cells - square quads used to stretch
##              them; each particle is a 0.5:1-tall cell
##   f_glow_cols2 the shipped glow (NOT a sheet) with Sheet Columns = 2
##              requested - the sheet rule clamps it, so every particle shows
##              the WHOLE glow instead of a sliced half-disc ("rows/cols cut
##              my particles")
##
## Prints each emitter's quad size + frame grid; the assertions live in
## tests/test_pb_particle_placer.gd. This is for looking at the result.

var _root: Node3D
var _cam: Camera3D
var _cases: Array = []

func _init() -> void:
	_root = Node3D.new()
	root.add_child(_root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.06, 0.07, 0.09)
	env.environment = e
	_root.add_child(env)

	_cam = Camera3D.new()
	_cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0.6, 4.5)).looking_at(Vector3(0, 0.6, 0), Vector3.UP)
	_root.add_child(_cam)

	var glow := load("res://addons/poibuilder/materials/textures/particle_glow.png") as Texture2D
	var cells := _sheet_cells(glow, 3, 1)
	_cases = [
		{"name": "a_single", "tex": glow, "cols": 1, "rows": 1},
		{"name": "b_sheet3x1", "tex": _tinted_sheet(cells, 3, 1, "sheet3x1"), "cols": 3, "rows": 1},
		{"name": "c_sheet1x3", "tex": _tinted_sheet(cells, 1, 3, "sheet1x3"), "cols": 1, "rows": 3},
		{"name": "d_wide", "tex": _wide_frame(glow), "cols": 1, "rows": 1},
		{"name": "e_tall_cells", "tex": _tall_cells_sheet(cells), "cols": 3, "rows": 1},
		# The "rows/cols cut my particles" report: the plain glow is NOT a
		# sheet, so cranking the knobs must still render the WHOLE glow.
		{"name": "f_glow_cols2", "tex": glow, "cols": 2, "rows": 1},
		# The same emitter ADDITIVE — how the glow preset actually renders in
		# the editor and on the device (the case above forces blended so the
		# frame grid reads; additive quads sum to white under overlap).
		{"name": "g_glow_add", "tex": glow, "cols": 2, "rows": 1, "additive": 1.0},
	]
	_run_next()

func _run_next() -> void:
	if _cases.is_empty():
		quit()
		return
	var c: Dictionary = _cases.pop_front()
	for child in _root.get_children():
		if child is GPUParticles3D:
			_root.remove_child(child)
			child.free()

	var values := PBParticleParams.preset_for_texture("glow")
	# Blended, not additive: overlapping additive quads sum to white and hide
	# which cell each particle is showing; spread wide so each particle reads
	# on its own.
	values["count"] = 6.0
	values["size"] = 0.55
	values["speed"] = 0.8
	values["spread"] = 70.0
	values["rise"] = 0.0
	values["lifetime"] = 2.0
	values["additive"] = float(c.get("additive", 0.0))
	values["opacity"] = 1.0
	values["atlas_cols"] = float(c["cols"])
	values["atlas_rows"] = float(c["rows"])
	var emitter := PBParticleParams.build_node(c["tex"], values, "Probe_%s" % c["name"])
	emitter.position = Vector3(0, 0.6, 0)
	emitter.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	_root.add_child(emitter)

	var qm := emitter.draw_pass_1 as QuadMesh
	var sm := qm.material as StandardMaterial3D
	print("\n=== %s  quad=%s frames=%dx%d billboard=%d tex=%dx%d" % [
		c["name"], str(qm.size), sm.particles_anim_h_frames, sm.particles_anim_v_frames,
		sm.billboard_mode, c["tex"].get_width(), c["tex"].get_height()])

	# Two captures a second apart of simulated time: a flipbook that does not
	# advance (or a quad showing the whole sheet) cannot look different.
	for step in range(2):
		for i in range(30):
			await process_frame
		var out := root.get_viewport().get_texture().get_image()
		out.save_png("/tmp/emit_%s_%d.png" % [c["name"], step])
		print("[probe] saved /tmp/emit_%s_%d.png" % [c["name"], step])
	_run_next()

## Three 64x64 cells (the shipped art's alpha, flat R/G/B) to lay out as a sheet.
func _sheet_cells(glow: Texture2D, _cols: int, _rows: int) -> Array:
	var src := _uncompressed(glow)
	var tints := [Color(1, 0.15, 0.1), Color(0.15, 1, 0.2), Color(0.2, 0.35, 1)]
	var out: Array = []
	for t in tints:
		var img := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
		for y in range(src.get_height()):
			for x in range(src.get_width()):
				img.set_pixel(x, y, Color(t.r, t.g, t.b, src.get_pixel(x, y).a))
		out.append(img)
	return out

## Lays `cells` out as a `cols` x `rows` sheet. The path carries the `_sheet`
## marker: under the sheet rule only a declared sheet may grid.
func _tinted_sheet(cells: Array, cols: int, rows: int, kind: String) -> Texture2D:
	var cw: int = (cells[0] as Image).get_width()
	var ch: int = (cells[0] as Image).get_height()
	var sheet := Image.create(cw * cols, ch * rows, false, Image.FORMAT_RGBA8)
	for i in range(cells.size()):
		var cell: Image = cells[i]
		sheet.blit_rect(cell, Rect2i(0, 0, cw, ch),
				Vector2i((i % cols) * cw, (i / cols) * ch))
	var tex := ImageTexture.create_from_image(sheet)
	tex.resource_path = "res://probe/%s_sheet.png" % kind
	return tex

## A 3-column sheet whose cells are 32x64 (0.5:1): the shape a square quad
## used to stretch 2x wider than the art.
func _tall_cells_sheet(cells: Array) -> Texture2D:
	var cw: int = (cells[0] as Image).get_width() / 2
	var ch: int = (cells[0] as Image).get_height()
	var sheet := Image.create(cw * 3, ch, false, Image.FORMAT_RGBA8)
	for i in range(3):
		var cell: Image = (cells[i] as Image).get_region(Rect2i(0, 0, cw, ch))
		sheet.blit_rect(cell, Rect2i(0, 0, cw, ch), Vector2i(i * cw, 0))
	var tex := ImageTexture.create_from_image(sheet)
	tex.resource_path = "res://probe/tall_cells_sheet.png"
	return tex

## The imported PNGs arrive compressed; get_pixel/resize need RGBA8.
func _uncompressed(tex: Texture2D) -> Image:
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img

## A 2:1 single frame: the shipped art stretched horizontally.
func _wide_frame(glow: Texture2D) -> Texture2D:
	var img := _uncompressed(glow)
	img.resize(img.get_width() * 2, img.get_height(), Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)
