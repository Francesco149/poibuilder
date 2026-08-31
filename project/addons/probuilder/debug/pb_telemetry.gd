## PBTelemetry — Operation timing and mesh statistics
##
## Tracks performance of mesh operations and current mesh stats.
## Connected to PBLogger for persistence.
@tool
class_name PBTelemetry
extends RefCounted

var logger: PBLogger

## Last operation info
var last_op_name: String = ""
var last_op_duration_ms: float = 0.0

## Mesh stats (updated by PBMesh nodes)
var total_vertices: int = 0
var total_faces: int = 0
var total_edges: int = 0
var total_submeshes: int = 0

## Timing helpers
var _op_start_time: int = 0

func _init(p_logger: PBLogger = null) -> void:
	logger = p_logger

func begin_op(op_name: String) -> void:
	_op_start_time = Time.get_ticks_usec()
	last_op_name = op_name

func end_op() -> void:
	var elapsed := Time.get_ticks_usec() - _op_start_time
	last_op_duration_ms = elapsed / 1000.0
	if logger:
		logger.info("telemetry", "%s completed in %.2f ms" % [last_op_name, last_op_duration_ms])

func update_mesh_stats(vertices: int, faces: int, edges: int, submeshes: int) -> void:
	total_vertices = vertices
	total_faces = faces
	total_edges = edges
	total_submeshes = submeshes
