## PBScrollRuntime — plays scrolling textures in a RUNNING game.
##
## The editor animates scrolling materials from the plugin (editor only) and
## the exports carry the speed for their consumers, so a PoiBuilder scene run
## as the game itself (play mode) showed every scrolling face at rest — it
## always had. One runner node per SceneTree advances the registered
## materials' uv1_offset with the editor's formula (poibuilder_plugin.gd
## _process), so play mode looks like the editor. PBMesh._ready registers its
## own scrolling materials outside the editor; a scene without scrolling faces
## never creates the runner, and the runner stops processing when its
## materials are gone.
class_name PBScrollRuntime
extends Node

const RUNNER_NAME := "PBScrollRuntime"

## Off for the headless test suite (tests/hooks/pb_pre_run.gd): exports read
## uv1_offset, and the suite is not a game.
static var enabled: bool = true

static var _runner: PBScrollRuntime = null

var _time: float = 0.0
## [WeakRef(material), speed: Vector2, base offset: Vector3, instance id]
var _entries: Array = []
var _known: Dictionary = {}

## Registers `pb`'s scrolling materials with the tree's runner (created on
## first use). Materials shared by several meshes animate once.
static func register_mesh(pb: PBMesh) -> void:
	if not enabled or pb == null or pb.pb_mesh_data == null or not pb.is_inside_tree():
		return
	var runner: PBScrollRuntime = null
	for m in pb.pb_mesh_data.materials:
		if m is StandardMaterial3D and PBUv.has_scroll(m):
			if runner == null:
				runner = runner_for(pb.get_tree())
			runner.add_material(m as StandardMaterial3D)

## The tree's runner. It is added to the root deferred (a mesh registers from
## _ready, while its scene is still being added), so the pending one is kept
## in a static and reused by every mesh of the same frame.
static func runner_for(tree: SceneTree) -> PBScrollRuntime:
	if is_instance_valid(_runner) and not _runner.is_queued_for_deletion():
		return _runner
	_runner = PBScrollRuntime.new()
	_runner.name = RUNNER_NAME
	tree.root.add_child.call_deferred(_runner)
	return _runner

func add_material(mat: StandardMaterial3D) -> void:
	var id := mat.get_instance_id()
	if _known.has(id):
		return
	_known[id] = true
	_entries.append([weakref(mat), PBUv.get_scroll_speed(mat), mat.uv1_offset, id])
	set_process(true)

func _process(delta: float) -> void:
	_time += delta
	var i := 0
	while i < _entries.size():
		var e: Array = _entries[i]
		var mat := (e[0] as WeakRef).get_ref() as StandardMaterial3D
		if mat == null:
			_known.erase(e[3])
			_entries.remove_at(i)
			continue
		var speed: Vector2 = e[1]
		var base: Vector3 = e[2]
		mat.uv1_offset = Vector3(fposmod(base.x + speed.x * _time, 1000.0),
				fposmod(base.y + speed.y * _time, 1000.0), base.z)
		i += 1
	if _entries.is_empty():
		set_process(false)
