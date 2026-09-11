## Shared helpers for the showcase sessions: the "showcase look" (environment
## + materials) and small scene-building utilities.
##
## Everything here is presentation only — it builds the scene the recorder
## drives. The plugin's own behaviour is never bypassed: environment presets go
## through the plugin's own preset applier, and shapes are built by the same
## generators the plugin's creation flow uses.
@tool
class_name ShowcaseUtil
extends RefCounted

## A small, deliberately pleasant palette. The plugin's stock default material
## is a dark checkerboard meant for reading tiling, which photographs poorly;
## these are the materials the showcase objects wear.
##
## Two hard constraints from the plugin's own visual language: SELECTION is
## yellow and HOVER is cyan, so the palette stays away from both — no yellows,
## oranges, sallows or cyans on anything the viewer is supposed to watch being
## selected. Values are also a little under white, because the editor's day
## preset is bright enough to blow out near-white albedo on video.
const PALETTE := {
	"stone": Color(0.72, 0.70, 0.66),   # light neutral grey
	"slate": Color(0.30, 0.39, 0.52),   # blue-grey
	"steel": Color(0.46, 0.52, 0.60),   # lighter blue-grey
	"plum": Color(0.46, 0.28, 0.48),    # purple
	"brick": Color(0.55, 0.24, 0.20),   # deep red
	"moss": Color(0.26, 0.40, 0.24),    # dark green
	"ink": Color(0.12, 0.14, 0.17),     # near-black ground
}

const META_CACHE := "__showcase_mats"

## Builds (once per scene root) a simple lit material for a palette colour.
static func mat(root: Node, color_name: String, roughness := 0.72) -> StandardMaterial3D:
	var cache: Dictionary = root.get_meta(META_CACHE, {})
	var key := "%s_%.2f" % [color_name, roughness]
	if cache.has(key):
		return cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = PALETTE.get(color_name, Color.WHITE)
	m.roughness = roughness
	m.metallic = 0.0
	m.resource_name = "Showcase_" + color_name
	cache[key] = m
	root.set_meta(META_CACHE, cache)
	return m

static func checker(root: Node) -> StandardMaterial3D:
	var cache: Dictionary = root.get_meta(META_CACHE, {})
	if cache.has("checker"):
		return cache["checker"]
	var m := PBMeshData.load_material_or_texture("res://addons/poibuilder/materials/textures/checkerboard_2x2.png")
	if m is StandardMaterial3D:
		(m as StandardMaterial3D).albedo_color = Color(1.0, 1.0, 1.0)
		(m as StandardMaterial3D).resource_name = "Showcase_Checker"
		cache["checker"] = m
		root.set_meta(META_CACHE, cache)
		return m
	return mat(root, "stone")

## Creates a PBMesh under `root` from generated mesh data, wearing one material.
static func mesh(root: Node, name: String, data: PBMeshData,
		pos := Vector3.ZERO, material: Material = null) -> PBMesh:
	var node := PBMesh.new()
	node.name = name
	node.pb_mesh_data = data
	node.position = pos
	if material != null:
		node.pb_mesh_data.materials = [material]
	root.add_child(node)
	node.owner = root
	node.rebuild()
	return node

## The workbench every editing beat sits on: a wide floor with a soft material.
static func floor_slab(root: Node, size: float, material: Material) -> PBMesh:
	var data := PBShapeGenerators.create_box(Vector3(size, 0.4, size))
	var node := mesh(root, "Bench", data, Vector3(0, -0.2, 0), material)
	return node

## Points the plugin's "default material for new shapes" at a project texture,
## so drag-created shapes arrive wearing something presentable (the stock
## default is a dark checkerboard meant for reading tiling, not for a video).
static func use_default_material(texture_path: String) -> void:
	var settings: EditorSettings = EditorInterface.get_editor_settings()
	if settings == null:
		return
	settings.set_setting("poibuilder/materials/default_material_path", texture_path)
	PBMeshData.invalidate_default_material()

## Replaces a mesh's material list with a texture/material at `tex_path`.
##
## `pb_mesh_data.materials` is a TYPED `Array[Material]`, and assigning an
## untyped array literal to it fails at runtime ("Invalid assignment of property
## 'materials' with value of type 'Array'") — which silently left a beat with a
## node that had no material at all.
static func dress(node: PBMesh, tex_path: String) -> void:
	if node == null or node.pb_mesh_data == null:
		return
	var m: Material = PBMeshData.load_material_or_texture(tex_path)
	if m == null:
		return
	var mats: Array[Material] = [m]
	node.pb_mesh_data.materials = mats
	node.rebuild()

## Drops a node onto the ground plane. The shape generators disagree about
## whether their origin is the base or the centre (create_box/create_cube are
## centred, the door/stairs generators build upward from y=0), so every showcase
## object is placed by its own bounds instead of by assumption.
static func drop_on_ground(node: Node3D) -> void:
	var mi := node as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	node.position.y -= mi.get_aabb().position.y

## Applies one of the plugin's own environment presets (dawn/day/dusk/night) to
## the scene, through the plugin's entry point.
static func env(plugin: Node, preset: String) -> void:
	plugin.call("_on_env_preset_requested", preset)

## Post-preset lighting trim. The presets are tuned for editing readability
## (day ships sun 1.25 + ambient 0.65), which clips bright materials on video.
## This dials them to a film look without touching the plugin's own presets.
static func grade_light(root: Node3D, sun_energy := 0.95, ambient := 0.40) -> void:
	var sun := PBEnvironment.find_sun(root)
	if sun != null:
		sun.light_energy = sun_energy
		sun.shadow_enabled = true
		sun.directional_shadow_blend_splits = true
	var we := PBEnvironment.find_world_environment(root)
	if we != null and we.environment != null:
		we.environment.ambient_light_energy = ambient

## A shape from the plugin's own generator, wearing a palette colour.
static func shape(root: Node, name: String, shape_id: StringName, values: Dictionary,
		pos := Vector3.ZERO, color := "stone") -> PBMesh:
	var data := PBShapeParams.build(shape_id, values)
	return mesh(root, name, data, pos, mat(root, color))

## Sets the editor's active mesh + element mode without touching the
## selection API, for beats that need a specific starting context.
static func activate(plugin: Node, node: PBMesh, mode: int = -1) -> void:
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(node)
	if mode >= 0:
		plugin.editor.select_mode = mode

static func names_of(root: Node, prefix: String) -> Array:
	var out := []
	for c in root.get_children():
		if String(c.name).begins_with(prefix):
			out.append(c)
	return out
