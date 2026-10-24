# pin_editor_layout.sh — sourced by the real-editor harness runners
# (run_gui_tests.sh, run_paint_perf.sh).
#
# Godot keeps the editor's dock layout PER PROJECT, in
# project/.godot/editor/editor_layout.cfg, not under HOME, so the runners'
# isolated HOME never covered it. The harness inherited whatever layout the
# last editor session saved (a dock that resizes the 3D viewport moves every
# synthesized click: the engine's default layout fails 13 cases) and wrote its
# own layout back over the user's on exit. These pin the harness's committed
# layout (project/test_scenes/editor_gui_layout.cfg) for the run and put the
# user's file back afterwards.
#
#   source "$REPO/tools/pin_editor_layout.sh"
#   pin_editor_layout "$PROJECT_DIR" "$SCRATCH_DIR"   # SCRATCH_DIR keeps the backup
#   trap 'restore_editor_layout; rm -rf "$SCRATCH_DIR"' EXIT

pin_editor_layout() {
    _PB_LAYOUT="$1/.godot/editor/editor_layout.cfg"
    _PB_LAYOUT_BACKUP="$2/editor_layout.user.cfg"
    mkdir -p "$(dirname "$_PB_LAYOUT")"
    if [ -f "$_PB_LAYOUT" ]; then
        cp -p "$_PB_LAYOUT" "$_PB_LAYOUT_BACKUP"
    fi
    cp "$1/test_scenes/editor_gui_layout.cfg" "$_PB_LAYOUT"
}

restore_editor_layout() {
    [ -n "${_PB_LAYOUT:-}" ] || return 0
    if [ -f "$_PB_LAYOUT_BACKUP" ]; then
        cp -p "$_PB_LAYOUT_BACKUP" "$_PB_LAYOUT"
    else
        rm -f "$_PB_LAYOUT"
    fi
}
