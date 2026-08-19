#!/bin/bash
#
# exit_paths.sh — every way a lockdown can end, and what the proctor is told.
#
# A student who force-quits writes nothing, so the interesting question is never
# "does the happy path work" but "what does the proctor see when it does not".
# This walks each door and checks the marker the lockdown leaves behind, which is
# what cleanup turns into the event on the proctor's timeline.
#
#     ./server/tests/exit_paths.sh
#
# It tests the real helper: the generator block is lifted out of
# guided-access.command rather than copied, so a change there fails this.
# Nothing here touches the network or a Supabase project.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOCKDOWN="$ROOT/macos/guided-access.command"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EXAM_CODE="exam-code-9"
PASSCODE="machine-pass"
FAILURES=0

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# ---------- stand-ins for the two Python helpers ----------
# verify-exit    0 = right code · 1 = wrong · 2 = cannot ask (offline)
# has-exit-code  0 = this exam has one · 1 = it does not
# verify-passcode 0 = the machine's own passcode
cat > "$WORK/runner" <<'STUB'
#!/bin/bash
script="$1"; verb="$2"
case "$verb" in
	verify-exit)
		[[ "$OFFLINE" == true ]] && exit 2
		read -r typed
		[[ "$typed" == "$EXAM_CODE" ]] && exit 0
		exit 1 ;;
	has-exit-code)  [[ "$EXAM_HAS_CODE" == true ]] && exit 0; exit 1 ;;
	verify-passcode)
		read -r typed
		[[ "$typed" == "$PASSCODE" ]] && exit 0
		exit 1 ;;
esac
exit 64
STUB
chmod +x "$WORK/runner"
export EXAM_CODE PASSCODE

# ---------- build the real helper, the way the lockdown builds it ----------
build_helper() {
	local dir="$1"
	mkdir -p "$dir"
	local block
	block="$(sed -n '/^\tEXIT_HELPER="\$SESSION_DIR\/verify-exit.sh"$/,/^\tchmod +x "\$EXIT_HELPER"$/p' "$LOCKDOWN")"
	[[ -n "$block" ]] || { echo "could not lift the helper generator out of guided-access.command" >&2; exit 2; }
	SESSION_DIR="$dir" PY_RUNNER=("$WORK/runner") CLOUD_PY=cloud.py CONFIG_PY=config.py \
		LIVE_EXAM_ID=exam-1 bash -c "
			SESSION_DIR='$dir'
			PY_RUNNER=('$WORK/runner')
			CLOUD_PY=cloud.py
			CONFIG_PY=config.py
			LIVE_EXAM_ID=exam-1
			$block
		"
}

# ---------- what cleanup would report, given whatever the doors left behind ----------
reported_kind() {
	local dir="$1"
	if [[ -f "$dir/exit-kind" ]]; then cat "$dir/exit-kind"; else echo "exit.signal"; fi
}

try() {
	local name="$1" typed="$2" has_code="$3" offline="$4" want_rc="$5" want_kind="$6"
	local dir="$WORK/$RANDOM$RANDOM"
	build_helper "$dir"
	EXAM_HAS_CODE="$has_code" OFFLINE="$offline" EXAM_CODE="$EXAM_CODE" PASSCODE="$PASSCODE" \
		bash -c "printf %s '$typed' | '$dir/verify-exit.sh'" >/dev/null 2>&1
	local rc=$?
	local kind; kind="$(reported_kind "$dir")"
	if [[ "$rc" -eq "$want_rc" && "$kind" == "$want_kind" ]]; then
		pass "$name → exit $rc, proctor sees '$kind'"
	else
		fail "$name → exit $rc (wanted $want_rc), proctor sees '$kind' (wanted '$want_kind')"
	fi
}

echo "Ways a proctored lockdown ends:"
#    name                                    typed            has_code offline rc  reported
try "the exam's exit code"                   "$EXAM_CODE"     true     false   0   exit.code
try "a wrong code, exam has one"             "nope"           true     false   1   exit.signal
try "machine passcode, exam has a code"      "$PASSCODE"      true     false   1   exit.signal
try "machine passcode, exam has no code"     "$PASSCODE"      false    false   0   exit.passcode
try "machine passcode while offline"         "$PASSCODE"      true     true    0   exit.passcode
try "wrong everything"                       "nonsense"       false    false   1   exit.signal

echo
echo "Ways that write nothing at all:"
NOTHING="$WORK/forcequit"; mkdir -p "$NOTHING"
kind="$(reported_kind "$NOTHING")"
[[ "$kind" == "exit.signal" ]] \
	&& pass "Ctrl+C, kill, crash, force quit → proctor sees '$kind'" \
	|| fail "expected exit.signal for a session that wrote no marker, got '$kind'"

echo
if [[ "$FAILURES" -eq 0 ]]; then
	printf '\033[32mAll exit paths report what they should.\033[0m\n'
	echo
	echo "Not covered here, because no code runs on the machine to report it:"
	echo "  * a hard kill of the lockdown itself, and a pulled plug — nothing is"
	echo "    written and nothing is sent. The dashboard catches those by the"
	echo "    heartbeat going quiet, not by an event."
else
	printf '\033[31m%s exit path(s) reported the wrong thing.\033[0m\n' "$FAILURES"
	exit 1
fi
