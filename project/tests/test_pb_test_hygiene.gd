## test_pb_test_hygiene.gd — static checks over the test suite and the addon
## for patterns that have cost a full-suite run before.
##
## These read SOURCE, not behaviour: each rule names the incident it exists
## for, so a failure says what to change instead of just "don't".
extends GutTest

const TESTS_DIR := "res://tests"

## Every .gd file under `dir` (recursive), as res:// paths.
func _scripts_under(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var path := dir.path_join(name)
		if d.current_is_dir():
			if not name.begins_with("."):
				out.append_array(_scripts_under(path))
		elif name.ends_with(".gd"):
			out.append(path)
		name = d.get_next()
	d.list_dir_end()
	return out

## The full text of each `assert_*(` call in `source` (calls can span
## lines), with its starting line number.
func _assert_calls(source: String) -> Array:
	var out: Array = []
	var lines := source.split("\n")
	var i := 0
	while i < lines.size():
		var line: String = lines[i]
		var stripped := line.strip_edges()
		var at := line.find("assert_")
		if stripped.begins_with("#") or at < 0 or line.find("(", at) < 0:
			i += 1
			continue
		var text := line.substr(at)
		var depth := text.count("(") - text.count(")")
		var start := i
		while depth > 0 and i + 1 < lines.size():
			i += 1
			text += "\n" + lines[i]
			depth += lines[i].count("(") - lines[i].count(")")
		out.append({"line": start + 1, "text": text})
		i += 1
	return out

## The asserts that receive their VALUES (GUT formats and keeps both).
## `assert_true(a == b)` hands GUT a bool and is fine.
const VALUE_ASSERTS := ["assert_eq(", "assert_ne(", "assert_eq_deep(", "assert_ne_deep(",
		"assert_same(", "assert_not_same("]

## INCIDENT (v0.9.182): GUT keeps a formatted copy of every value assertion's
## arguments, and assert_eq on two 64 KB mask buffers retained ~143 MB — two
## such asserts plus one heavy decal test pushed the full suite past the
## guard's 2 GB cap, and it was OOM-killed in an unrelated test. Compare
## image buffers through hash() (or `assert_true(a == b)`), never raw.
func test_no_assertion_compares_raw_image_buffers() -> void:
	var offenders := PackedStringArray()
	for path in _scripts_under(TESTS_DIR):
		if path.ends_with("test_pb_test_hygiene.gd"):
			continue
		var source := FileAccess.get_file_as_string(path)
		for call in _assert_calls(source):
			var text: String = call["text"]
			var takes_values := false
			for prefix in VALUE_ASSERTS:
				if text.begins_with(prefix):
					takes_values = true
			if not takes_values:
				continue
			var raw := text.count(".get_data()")
			if raw > text.count("hash("):
				offenders.append("%s:%d" % [path, call["line"]])
	assert_eq(offenders.size(), 0,
			"assertions on raw .get_data() buffers (wrap them in hash()): %s" % ", ".join(offenders))

## The lint itself must see real calls (a parser that matches nothing would
## pass vacuously).
func test_assert_call_scanner_finds_multiline_calls() -> void:
	var src := "func t():\n\tassert_eq(a.get_data(),\n\t\tb.get_data(), \"x\")\n\t# assert_eq(c.get_data(), d)\n\tassert_true(ok)\n"
	var calls := _assert_calls(src)
	assert_eq(calls.size(), 2, "two real calls, the commented one skipped")
	assert_true((calls[0]["text"] as String).begins_with("assert_eq("), "a value assert is recognised")
	assert_eq((calls[0]["text"] as String).count(".get_data()"), 2, "the continuation line is part of the call")
	assert_gt(_scripts_under(TESTS_DIR).size(), 50, "the scan reaches the whole suite")
