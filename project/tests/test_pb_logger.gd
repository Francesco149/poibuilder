## Test: PBLogger
##
## Verifies ring buffer logging, level filtering, category filtering,
## file dump, and signal emission.
extends GutTest

var logger: PBLogger

func before_each():
	# Tests assert on INFO/DEBUG entries, so force verbosity on (production
	# gates it behind POIBUILDER_DEBUG — see test_verbose_gate).
	PBLogger.verbose = true
	logger = PBLogger.new()

func after_each():
	PBLogger.verbose = false

func test_basic_logging():
	logger.info("test", "hello")
	assert_eq(logger.entry_count(), 1, "Should have 1 entry")
	var entry = logger.entries[0]
	assert_eq(entry.category, "test")
	assert_eq(entry.message, "hello")
	assert_eq(entry.level, PBLogger.Level.INFO)

func test_log_levels():
	logger.debug("cat", "debug msg")
	logger.warn("cat", "warn msg")
	logger.error("cat", "error msg")
	assert_eq(logger.entry_count(), 3)
	assert_eq(logger.entries[0].level, PBLogger.Level.DEBUG)
	assert_eq(logger.entries[1].level, PBLogger.Level.WARN)
	assert_eq(logger.entries[2].level, PBLogger.Level.ERROR)

func test_ring_buffer_overflow():
	logger.max_entries = 5
	for i in range(10):
		logger.info("test", "msg %d" % i)
	assert_eq(logger.entry_count(), 5, "Should cap at max_entries")
	assert_eq(logger.entries[0].message, "msg 5", "Oldest should be msg 5")
	assert_eq(logger.entries[4].message, "msg 9", "Newest should be msg 9")

func test_filter_by_category():
	logger.info("alpha", "a1")
	logger.info("beta", "b1")
	logger.info("alpha", "a2")
	var alpha_entries = logger.get_entries_by_category("alpha")
	assert_eq(alpha_entries.size(), 2)
	assert_eq(alpha_entries[0].message, "a1")
	assert_eq(alpha_entries[1].message, "a2")

func test_filter_by_level():
	logger.debug("x", "d")
	logger.info("x", "i")
	logger.warn("x", "w")
	logger.error("x", "e")
	var warns_and_above = logger.get_entries_by_level(PBLogger.Level.WARN)
	assert_eq(warns_and_above.size(), 2)

func test_dump_to_file():
	logger.info("test", "line1")
	logger.warn("test", "line2")
	var path = "user://test_pb_logger_dump.log"
	var err = logger.dump_to_file(path)
	assert_eq(err, OK, "Should write successfully")
	# Verify file exists and has content
	assert_true(FileAccess.file_exists(path))
	var content = FileAccess.get_file_as_string(path)
	assert_true(content.contains("line1"))
	assert_true(content.contains("line2"))
	assert_true(content.contains("WARN"))
	# Cleanup
	DirAccess.remove_absolute(path)

func test_signal_emission():
	var received = []
	logger.entry_added.connect(func(entry): received.append(entry))
	logger.info("sig", "test signal")
	assert_eq(received.size(), 1)
	assert_eq(received[0].message, "test signal")

func test_clear():
	logger.info("test", "msg")
	logger.info("test", "msg2")
	logger.clear()
	assert_eq(logger.entry_count(), 0)

func test_verbose_gate():
	# Production default: the gate is OFF unless POIBUILDER_DEBUG is set.
	# INFO/DEBUG are dropped entirely (no entry, no signal, no print);
	# WARN/ERROR always go through.
	PBLogger.verbose = false
	logger = PBLogger.new()
	var received = []
	logger.entry_added.connect(func(entry): received.append(entry))
	logger.debug("gate", "dropped debug")
	logger.info("gate", "dropped info")
	assert_eq(logger.entry_count(), 0, "INFO/DEBUG should be gated off")
	assert_eq(received.size(), 0, "No signal for gated entries")
	logger.warn("gate", "kept warn")
	logger.error("gate", "kept error")
	assert_eq(logger.entry_count(), 2, "WARN/ERROR always record")
	# Back to verbose: entries flow again.
	PBLogger.verbose = true
	logger.info("gate", "kept info")
	assert_eq(logger.entry_count(), 3, "verbose restores INFO")
