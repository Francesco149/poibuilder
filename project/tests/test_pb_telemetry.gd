## Test: PBTelemetry
##
## Verifies operation timing and mesh stat tracking.
extends GutTest

func test_timing():
	var logger = PBLogger.new()
	var tel = PBTelemetry.new(logger)

	tel.begin_op("test_op")
	# Simulate some work
	var x = 0
	for i in range(1000):
		x += i
	tel.end_op()

	assert_eq(tel.last_op_name, "test_op")
	assert_gt(tel.last_op_duration_ms, 0.0, "Duration should be > 0")
	assert_true(logger.entry_count() > 0, "Should log the operation")

func test_mesh_stats():
	var tel = PBTelemetry.new()
	tel.update_mesh_stats(24, 6, 12, 1)
	assert_eq(tel.total_vertices, 24)
	assert_eq(tel.total_faces, 6)
	assert_eq(tel.total_edges, 12)
	assert_eq(tel.total_submeshes, 1)

func test_default_state():
	var tel = PBTelemetry.new()
	assert_eq(tel.last_op_name, "")
	assert_eq(tel.last_op_duration_ms, 0.0)
	assert_eq(tel.total_vertices, 0)
