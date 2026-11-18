## PBMaterialDropOverlay — Viewport overlay for drag-and-drop material assignment.
##
## Listens for material drops from the FileSystem dock or the Material Picker panel.
## When dropped on a PBMesh face:
## - If multiple faces are selected and dropped onto one of the selected faces -> applies to all selected faces.
## - Otherwise -> applies to that face instantly.
##
## Remains completely inert (MOUSE_FILTER_IGNORE) when not dragging, ensuring zero
## interference with normal viewport clicks, gizmo drags, or box selections.
##
## PARENTING IS LOAD-BEARING: the overlay must be a CHILD of the viewport's
## `surface` control (the one the engine forwards drag-and-drop through to
## Node3DEditorViewport), never its sibling. During a drag the overlay turns
## MOUSE_FILTER_PASS, and a refused drop climbs to the PARENT chain
## (Viewport::_gui_drop). As a sibling above `surface` that chain skipped the
## engine's handler entirely, so with the plugin enabled no scene/prefab,
## mesh or texture could be dropped into the 3D view at all (user report,
## v0.9.186). Under `surface`, anything we refuse falls through to Godot's
## own drop: scenes instance, materials on plain meshes assign natively.
@tool
class_name PBMaterialDropOverlay
extends Control

## Reference to the main PoiBuilder plugin.
var plugin: EditorPlugin = null
## Which of the (up to four) 3D editor viewports this overlay covers.
var viewport_index: int = 0

## Finds the engine's drop-forwarding `surface` under a Node3DEditorViewport:
## its only plain, script-less Control child (the other engine child is the
## SubViewportContainer; plugin overlays carry scripts). Null when the layout
## is unrecognised.
static func find_drop_surface(viewport_host: Node) -> Control:
	if viewport_host == null:
		return null
	for child in viewport_host.get_children():
		if child.get_class() == "Control" and child.get_script() == null:
			return child as Control
	return null

func _init() -> void:
	name = "PBMaterialDropOverlay"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_DRAG_BEGIN:
			mouse_filter = Control.MOUSE_FILTER_PASS
		NOTIFICATION_DRAG_END:
			mouse_filter = Control.MOUSE_FILTER_IGNORE

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not _is_material_data(data):
		return false
	var hit := _pick_pbmesh_face(at_position)
	return not hit.is_empty()

func _drop_data(at_position: Vector2, data: Variant) -> void:
	var mat := _resolve_material(data)
	if mat == null:
		return

	var hit := _pick_pbmesh_face(at_position)
	if hit.is_empty():
		return

	var mesh: PBMesh = hit["mesh"]
	var face_index: int = hit["face_index"]
	if mesh == null or mesh.pb_mesh_data == null:
		return

	var target_faces: Array[PBFace] = []
	var editor = plugin.get("editor") if plugin != null else null

	if editor != null and editor.active_mesh == mesh and editor.selection != null:
		var sel_faces: PackedInt32Array = editor.selection.selected_faces
		if sel_faces.size() > 1 and sel_faces.has(face_index):
			for fi in sel_faces:
				if fi >= 0 and fi < mesh.pb_mesh_data.faces.size():
					target_faces.append(mesh.pb_mesh_data.faces[fi])
		else:
			if face_index >= 0 and face_index < mesh.pb_mesh_data.faces.size():
				target_faces.append(mesh.pb_mesh_data.faces[face_index])
	else:
		if face_index >= 0 and face_index < mesh.pb_mesh_data.faces.size():
			target_faces.append(mesh.pb_mesh_data.faces[face_index])

	if target_faces.is_empty():
		return

	if plugin != null and plugin.has_method("apply_faces_material"):
		plugin.apply_faces_material(mesh, target_faces, mat)
	else:
		mesh.pb_mesh_data.set_faces_material(target_faces, mat)
		mesh.rebuild()
		mesh.update_gizmos()

# ==============================================================================
# Helper Methods
# ==============================================================================

func _is_material_data(data: Variant) -> bool:
	if data is Material:
		return true
	if data is Dictionary:
		if data.get("type") == "poibuilder_material" and data.get("material") is Material:
			return true
		if data.get("material") is Material:
			return true
		if data.get("type") == "files" and data.has("files"):
			for f in data["files"]:
				var ext := String(f).get_extension().to_lower()
				if ext == "tres" or ext == "material" or ext == "res":
					var res = ResourceLoader.load(f)
					if res is Material:
						return true
	return false

func _resolve_material(data: Variant) -> Material:
	if data is Material:
		return data
	if data is Dictionary:
		if data.get("material") is Material:
			return data["material"]
		if data.get("type") == "files" and data.has("files"):
			for f in data["files"]:
				var ext := String(f).get_extension().to_lower()
				if ext == "tres" or ext == "material" or ext == "res":
					var res = ResourceLoader.load(f)
					if res is Material:
						return res
	return null

func _pick_pbmesh_face(screen_pos: Vector2) -> Dictionary:
	if plugin == null or not is_instance_valid(plugin):
		return {}

	var editor_if = plugin.get_editor_interface()
	if editor_if == null:
		return {}

	var viewport: SubViewport = editor_if.get_editor_viewport_3d(viewport_index)
	if viewport == null:
		return {}

	var camera: Camera3D = viewport.get_camera_3d()
	if camera == null:
		return {}

	# The SubViewport can render below the control's size (the 3D view's
	# half-resolution option): map control pixels to viewport pixels.
	if size.x > 0.0 and size.y > 0.0:
		screen_pos *= Vector2(viewport.size) / size

	var ray_o: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_d: Vector3 = camera.project_ray_normal(screen_pos)

	var scene_root: Node = editor_if.get_edited_scene_root()
	if scene_root == null:
		return {}

	var hit := PBPicking.scene_ray_pick(PBPicking.collect_pbmeshes(scene_root), ray_o, ray_d)
	if hit.is_empty():
		return {}
	return {"mesh": hit["mesh"], "face_index": hit["face_index"]}
