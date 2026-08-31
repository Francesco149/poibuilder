# Unity → Godot Concept Mapping for ProBuilder

This document maps every Unity-specific concept in the ProBuilder specification
to its Godot 4.x equivalent. Implementation workers MUST consult this when
translating spec sections.

## 1. Scene Graph & Node Types

| Unity | Godot | Notes |
|-------|-------|-------|
| `GameObject` | `Node` / `Node3D` | Base scene element |
| `MonoBehaviour` | Script extending Node | `@tool` annotation for editor scripts |
| `Component` (attached to GO) | Child node or script | Godot prefers composition via child nodes |
| `MeshFilter` + `MeshRenderer` | `MeshInstance3D` | Single node, set `.mesh` property |
| `ProBuilderMesh : MonoBehaviour` | `PBMesh : MeshInstance3D` | Our core node, `@tool` script |
| `Transform` | `Node3D.transform` / `Node3D.global_transform` | `Transform3D` in Godot |
| `SceneView` | 3D Viewport / `EditorInterface.get_editor_viewport_3d()` | |
| `EditorWindow` | Custom dock or `EditorPlugin` popup | |

## 2. Mesh & Geometry

| Unity | Godot | Notes |
|-------|-------|-------|
| `Mesh` | `ArrayMesh` | Primary mesh type |
| `MeshFilter.sharedMesh` | `MeshInstance3D.mesh` | |
| `Vector3[]` positions | `PackedVector3Array` | Packed arrays are faster |
| `Vector2[]` UVs | `PackedVector2Array` | |
| `Vector4[]` tangents | `PackedFloat32Array` (stride 4) | No PackedVector4Array; use float array |
| `Color[]` | `PackedColorArray` | |
| `int[]` indices | `PackedInt32Array` | |
| `Mesh.SetVertices/Normals/etc` | `SurfaceTool` or direct surface arrays | See §2.1 |
| `Mesh.subMeshCount` | Multiple surfaces on `ArrayMesh` | Each submesh = one `ArrayMesh.add_surface_from_arrays()` call |
| `MeshTopology.Triangles` | `Mesh.PRIMITIVE_TRIANGLES` | |
| `RecalculateNormals()` | `SurfaceTool.generate_normals()` | |
| `RecalculateTangents()` | `SurfaceTool.generate_tangents()` | |
| `RecalculateBounds()` | Automatic when mesh data set | |
| `CombineInstance` | `SurfaceTool.append_from()` | |

### 2.1 Building Meshes

Unity ProBuilder uses direct array assignment:
```csharp
mesh.SetVertices(positions);
mesh.SetNormals(normals);
mesh.SetTriangles(indices, submeshIndex);
```

Godot equivalent using surface arrays:
```gdscript
var arrays = []
arrays.resize(Mesh.ARRAY_MAX)
arrays[Mesh.ARRAY_VERTEX] = positions  # PackedVector3Array
arrays[Mesh.ARRAY_NORMAL] = normals    # PackedVector3Array
arrays[Mesh.ARRAY_TEX_UV] = uvs        # PackedVector2Array
arrays[Mesh.ARRAY_INDEX] = indices     # PackedInt32Array
var mesh = ArrayMesh.new()
mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
```

For multiple submeshes (materials), call `add_surface_from_arrays` once per
submesh with that submesh's index subset.

## 3. Editor Plugin Integration

| Unity | Godot | Notes |
|-------|-------|-------|
| `EditorWindow` | `EditorPlugin` + dock panels | |
| `Editor` (custom inspector) | `EditorInspectorPlugin` + `EditorProperty` | |
| `[CustomEditor(typeof(X))]` | `EditorInspectorPlugin.can_handle()` | |
| `SceneView.duringSceneGui` | `EditorPlugin._forward_3d_gui_input()` | |
| `Handles.DrawLine` etc | `ImmediateMesh` or `MeshInstance3D` overlay | Cyclops uses `ImmediateMesh` |
| `HandleUtility.PickRectObjects` | Manual raycasting / physics queries | No built-in rect pick |
| `HandleUtility.GUIPointToWorldRay` | `Camera3D.project_ray_origin/normal()` | |
| `SceneView.RepaintAll()` | `EditorPlugin.update_overlays()` | |
| `EditorGUILayout` | `VBoxContainer` + Control nodes | Godot UI is scene-tree based |
| `Overlay` (Unity 2022+) | `EditorPlugin.add_control_to_container()` | `CONTAINER_SPATIAL_EDITOR_MENU` etc |
| `ToolbarOverlay` | Custom `HBoxContainer` in spatial editor menu | See Cyclops `editor_toolbar` pattern |
| `EditorToolbarElement` | Buttons inside toolbar HBoxContainer | |

### 3.1 Plugin Lifecycle

Unity: Package loads automatically; `[InitializeOnLoad]` runs static constructors.

Godot: `plugin.cfg` declares the entry script. `_enter_tree()` = setup,
`_exit_tree()` = teardown. Key methods to override:

```gdscript
@tool
extends EditorPlugin

func _enter_tree():
    # Add docks, toolbars, custom types
    add_custom_type("PBMesh", "MeshInstance3D", preload("pb_mesh.gd"), icon)
    add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)

func _exit_tree():
    remove_custom_type("PBMesh")
    remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)

func _handles(object: Object) -> bool:
    return object is PBMesh  # Activate when PBMesh selected

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
    # Handle mouse/key in 3D viewport
    return AFTER_GUI_INPUT_STOP  # or AFTER_GUI_INPUT_PASS

func _forward_3d_draw_over_viewport(viewport_control: Control):
    # Draw 2D overlays on 3D viewport
```

### 3.2 Dock Panels

Cyclops uses `EditorDock` (a Godot 4.3+ class). For broader compatibility:

```gdscript
# Godot 4.3+
var dock = EditorDock.new()
dock.add_child(panel)
dock.title = "Tool Properties"
dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_BL
add_dock(dock)

# Godot 4.0-4.2 fallback
add_control_to_dock(DOCK_SLOT_RIGHT_BL, panel)
```

Our target: Godot 4.3+ (EditorDock API available). This matches Cyclops's approach.

### 3.3 Custom Node Types vs Custom Types

Two mechanisms:
1. `add_custom_type()` — lightweight, script-based, shows in Add Node dialog
2. Full `EditorPlugin` registration — more control but more boilerplate

We use `add_custom_type()` for `PBMesh` (like Cyclops uses for `CyclopsBlock`).

## 4. Selection & Input

| Unity | Godot | Notes |
|-------|-------|-------|
| `Selection.activeGameObject` | `EditorInterface.get_selection().get_selected_nodes()` | |
| `Selection.selectionChanged` | `EditorSelection.selection_changed` signal | |
| `HandleUtility.nearestControl` | Manual distance checks in `_forward_3d_gui_input` | |
| `Event.current` | `InputEvent` parameter in `_forward_3d_gui_input` | |
| `Event.Use()` | Return `AFTER_GUI_INPUT_STOP` | |
| `GUIUtility.hotControl` | Track active tool/drag state manually | |
| Color picking (render ID to texture) | Render to `SubViewport` with ID shader | See §4.1 |

### 4.1 Element Picking Strategy

ProBuilder renders mesh elements with unique colors to a hidden render target,
then reads back the pixel under the cursor. In Godot:

1. Create a `SubViewport` (not visible on screen)
2. Assign a custom shader that outputs element ID as color
3. `get_texture().get_image().get_pixel()` to read back
4. Map color → element index

This avoids focus/window stealing — the SubViewport is purely internal.

Alternative: Pure raycasting against the control mesh (Cyclops approach).
Cyclops does NOT use color picking — it intersects rays against ConvexVolume
face planes. For ProBuilder parity (which handles concave faces, partial
occlusion, rect-select), we need the SubViewport approach for rect selection
and raycast for single-click.

## 5. Undo/Redo

| Unity | Godot | Notes |
|-------|-------|-------|
| `Undo.RecordObject()` | `EditorUndoRedoManager` | |
| `Undo.RegisterCompleteObjectUndo()` | `undo_redo.create_action()` + do/undo methods | |
| `Undo.DestroyObjectImmediate()` | Track in undo action | |
| `Undo.RegisterCreatedObjectUndo()` | Track in undo action | |

### 5.1 Command Pattern (from Cyclops)

```gdscript
class_name CmdMoveFaces extends RefCounted

var command_name: String = "Move faces"
var builder: ProBuilder  # plugin ref
var tracked_data: Dictionary  # {NodePath: MeshVectorData}

func add_to_undo_manager(undo: EditorUndoRedoManager):
    undo.create_action(command_name)
    undo.add_do_method(self, "do_it")
    undo.add_undo_method(self, "undo_it")
    undo.commit_action()

func do_it():
    # Apply operation, store new state

func undo_it():
    # Restore tracked_data to nodes
```

This is the proven pattern. Every mesh operation creates a command, snapshots
the mesh data before, applies the operation, and registers with
`EditorUndoRedoManager`. Undo restores the snapshot.

## 6. Materials & Rendering

| Unity | Godot | Notes |
|-------|-------|-------|
| `Material` | `Material` (StandardMaterial3D, ShaderMaterial) | |
| `MeshRenderer.sharedMaterials` | `MeshInstance3D.set_surface_override_material()` | Per-surface |
| `Shader` | `.gdshader` files | |
| `MaterialPropertyBlock` | `ShaderMaterial` with per-instance params | |
| `GL.Begin/End` (immediate mode) | `ImmediateMesh` | For wireframe/overlay drawing |
| `CommandBuffer` | `RenderingServer` advanced API | Rarely needed |
| `Graphics.DrawMesh` | `RenderingServer.mesh_create()` + instance | For overlay meshes |

### 6.1 Wireframe & Selection Overlay

Cyclops draws wireframes using `ImmediateMesh` (line primitives) and manages
vertex point billboards via `MeshInstance3D` children. This is the right
approach for our overlay rendering.

For face selection highlights: render selected faces as a separate
`ImmediateMesh` surface with a transparent material on top.

## 7. Physics & Collision

| Unity | Godot | Notes |
|-------|-------|-------|
| `MeshCollider` | `CollisionShape3D` + `ConcavePolygonShape3D` | |
| `BoxCollider` | `CollisionShape3D` + `BoxShape3D` | |
| `Rigidbody` | `RigidBody3D` | |
| `Physics.Raycast` | `PhysicsDirectSpaceState3D.intersect_ray()` | |

Cyclops creates `StaticBody3D` + `CollisionShape3D` + `ConvexPolygonShape3D`
as children of each block. We follow the same pattern.

## 8. Serialization & Resources

| Unity | Godot | Notes |
|-------|-------|-------|
| `[SerializeField]` | `@export` | |
| `[NonSerialized]` | Regular var (no `@export`) | |
| `ScriptableObject` | `Resource` | |
| `JsonUtility` | `JSON` class | |
| `EditorPrefs` | `EditorSettings` or `ProjectSettings` | |
| `AssetDatabase` | `EditorInterface.get_resource_filesystem()` | |
| `Resources.Load` | `load()` / `preload()` | |

### 8.1 PBMesh Data Storage

Our `PBMesh` node stores its editable mesh data as an `@export` `Resource`:

```gdscript
@tool
extends MeshInstance3D
class_name PBMesh

@export var pb_data: PBMeshData  # Custom Resource with all editable arrays
```

`PBMeshData` extends `Resource` and holds:
- `positions: PackedVector3Array`
- `faces: Array[PBFace]` (each face is a Resource)
- `shared_vertices: Array[PackedInt32Array]`
- `shared_textures: Array[PackedInt32Array]`
- Selection state, UV data, colors, etc.

This serializes automatically with `.tscn`/`.tres` files.

## 9. Math & Coordinate System

| Unity | Godot | Notes |
|-------|-------|-------|
| Left-handed Y-up | **Right-handed Y-up** | Z axis is flipped |
| `Vector3.forward = (0,0,1)` | `Vector3.FORWARD = (0,0,-1)` | Critical difference |
| `Vector3.Cross(a, b)` | `a.cross(b)` | Same operation, different handedness |
| `Mathf.Approximately` | `is_equal_approx()` / `is_zero_approx()` | |
| `Quaternion.LookRotation` | `Transform3D.looking_at()` or `Basis.looking_at()` | |
| `Matrix4x4` | `Transform3D` (Basis + origin) | |
| `Plane` | `Plane` | Same concept |
| `Bounds` / `AABB` | `AABB` | |
| `Ray` | origin + direction Vector3 pair | No Ray class in Godot |

### 9.1 Winding Order

Unity uses clockwise winding for front faces. Godot uses **counter-clockwise**.
All triangle index generation must account for this — reverse the index order
when porting algorithms.

### 9.2 UV Coordinate System

Both Unity and Godot use bottom-left origin for UV space (0,0 = bottom-left,
1,1 = top-right). No conversion needed for UV algorithms.

## 10. Editor-Specific APIs

| Unity | Godot | Notes |
|-------|-------|-------|
| `EditorUtility.SetDirty()` | `notify_property_list_changed()` + resource changed | |
| `PrefabUtility` | N/A | Godot scenes are the equivalent |
| `AssetDatabase.CreateAsset()` | `ResourceSaver.save()` | |
| `EditorGUIUtility.singleLineHeight` | Theme constants | |
| `EditorStyles` | `EditorInterface.get_editor_theme()` | |
| `Handles.color` | Material color on overlay mesh | |
| `HandleUtility.WorldToGUIPoint` | `Camera3D.unproject_position()` | |
| `HandleUtility.GetHandleSize` | Manual calculation from camera distance | |

## 11. Preferences & Settings

ProBuilder stores per-project and per-user preferences via Unity's
`EditorPrefs` and `Settings` system. Godot equivalents:

1. **Per-project settings**: `ProjectSettings.set_setting()` with
   `addons/probuilder/` prefix
2. **Per-user editor settings**: `EditorSettings.set_setting()` with
   `probuilder/` prefix
3. **Plugin config file**: JSON/ConfigFile in `user://probuilder_config.cfg`

We use approach 3 (ConfigFile) for most settings, matching Cyclops's pattern
of using a settings file (`cyclops_settings.config`).

## 12. Export Formats

ProBuilder supports OBJ, PLY, STL, and Asset export. Godot equivalents:

| Format | Implementation | Notes |
|--------|---------------|-------|
| OBJ | Custom writer (simple text format) | Same algorithm, adjust coord system |
| PLY | Custom writer | Same |
| STL | Custom writer | Same |
| Asset (Unity) | `.tres` / `.res` (Godot Resource) | Native Godot format |
| GLTF | `GLTFDocument` class | Godot has built-in GLTF support |

## 13. Key Architectural Differences

### 13.1 No Submesh → Use Multiple Surfaces
Unity's submesh concept maps to Godot's `ArrayMesh` surfaces. Each material
gets its own surface. `ArrayMesh.get_surface_count()` = submesh count.

### 13.2 No HideFlags → Use Meta or Internal Children
Unity hides internal components with `HideFlags`. In Godot, set child nodes
as internal: `add_child(node, false, Node.INTERNAL_MODE_BACK)` to hide from
scene tree inspector.

### 13.3 No MonoBehaviour Lifecycle → Use _process/_ready
`Awake()` → `_init()`, `Start()` → `_ready()`, `Update()` → `_process()`,
`OnDestroy()` → `_notification(NOTIFICATION_PREDELETE)`.

### 13.4 @tool Scripts Run in Editor
Any script with `@tool` at the top runs in the editor. This is how we get
live mesh preview, selection rendering, etc. — equivalent to Unity's
`[ExecuteInEditMode]`.
