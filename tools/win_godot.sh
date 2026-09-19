# win_godot.sh — shared helpers for the *_win.sh launchers, which drive the
# NATIVE WINDOWS Godot from WSL (sourced, not executed).
#
# Why: the Windows machine's GPU (the bench box's RTX 5060) is attached to
# Windows, not to WSL — WSL's /dev/dri and GPU paravirtualization are not
# the measurement target. WSL interop can launch the Windows exe directly;
# the only rules are (a) the repo copy must live on the WINDOWS filesystem
# (a \\wsl.localhost UNC cwd is useless to a Windows exe) and (b) the cwd
# must be translated — cd'ing to the /mnt/c path does that for us.
#
# Godot discovery: Documents\_devtools\Godot_v4.7* — the console exe is
# preferred (its stdout reaches WSL pipes; the GUI exe's does not), and the
# non-mono build over mono (the project is pure GDScript; no .NET needed on
# the bench box). Override everything with GODOT_WIN_EXE=/mnt/c/path/to.exe.

## /mnt/c/Users/x → C:\Users\x — wslpath -w without depending on wslpath
## (not installed on every WSL distro; NixOS-WSL doesn't ship it on PATH).
win_path() {
	local p="$1" rest
	rest="${p#/mnt/}"
	if [ "${#rest}" -lt 3 ] || [ "${rest:1:1}" != "/" ]; then
		echo "win_path: $p is not an /mnt/<drive>/ path" >&2
		return 1
	fi
	local win="${rest:0:1}:/${rest:2}"
	win="${win^}"
	echo "${win//\//\\}"
}

win_godot_detect() {
	if [ -n "${GODOT_WIN_EXE:-}" ]; then
		if [ ! -f "$GODOT_WIN_EXE" ]; then
			echo "GODOT_WIN_EXE=$GODOT_WIN_EXE does not exist" >&2
			return 1
		fi
		echo "$GODOT_WIN_EXE"
		return 0
	fi
	local cands=() f base name score best="" best_score=-1
	for base in /mnt/c/Users/*/Documents/_devtools/Godot_v*; do
		[ -d "$base" ] || continue
		for f in "$base"/*.exe; do
			[ -f "$f" ] || continue
			name="$(basename "$f")"
			case "$name" in
				Godot*.exe) ;;
				*) continue ;;
			esac
			score=0
			case "$name" in *console*) score=$((score + 4)) ;; esac
			case "$name" in *mono*) score=$((score + 1)) ;; *) score=$((score + 2)) ;; esac
			case "$base" in *Godot_v4.7*) score=$((score + 8)) ;; esac
			if [ "$score" -gt "$best_score" ]; then
				best="$f"
				best_score="$score"
			fi
		done
	done
	if [ -z "$best" ]; then
		echo "no Windows Godot found under /mnt/c/Users/*/Documents/_devtools/Godot_v* — set GODOT_WIN_EXE" >&2
		return 1
	fi
	echo "$best"
}

win_godot_require_windows_fs() {
	case "$1" in
		/mnt/[a-z]/*) return 0 ;;
		*) echo "this copy of the repo is on the WSL filesystem ($1)." >&2
			echo "The *_win.sh launchers drive the NATIVE Windows Godot, which needs the" >&2
			echo "repo on the Windows filesystem (e.g. /mnt/c/Users/.../_devtools/poibuilder)." >&2
			return 1 ;;
	esac
}
