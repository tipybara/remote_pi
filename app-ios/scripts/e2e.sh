#!/bin/bash
# End-to-end run against a real relay + fake-pi, with screenshots.
#
#   ./scripts/e2e.sh <test-name> [extra TEST_RUNNER_ env assignments...]
#
# Screenshots land in build/native-<attachment-name>.png. See STATUS.md for the
# preconditions (relay on RP_RELAY, fake-pi against the same relay).
#
# `xcodebuild test`, not `test-without-building`: TEST_RUNNER_* environment is
# baked into the generated .xctestrun at build-for-testing time, so passing it
# to a test-without-building invocation is silently ignored and every
# env-driven test skips itself.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIM="${RP_SIM:-DFB18620-63F4-4AF2-95BB-392893A258C4}"
RELAY="${RP_RELAY:-ws://localhost:3888}"
TEST="${1:?usage: e2e.sh <TestName> [KEY=VALUE ...]}"
shift || true

RESULT="build/res-$TEST.xcresult"
rm -rf "$RESULT"

EXTRA=()
for kv in "$@"; do EXTRA+=("TEST_RUNNER_$kv"); done

xcodebuild test \
  -project RemotePi.xcodeproj -scheme RemotePiUITests \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd -resultBundlePath "$RESULT" \
  -only-testing:"RemotePiUITests/HomeE2ETests/$TEST" \
  TEST_RUNNER_RP_RELAY="$RELAY" ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 \
  | grep -E "Test Case|error:|XCTAssert|timed out|failed|passed|TEST (EXECUTE )?(SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}

# Pull the screenshots out of the result bundle and give them stable names.
OUT="build/att-$TEST"
rm -rf "$OUT"
if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null 2>&1; then
  python3 - "$OUT" <<'PY'
import json, os, shutil, sys, re
out = sys.argv[1]
manifest = os.path.join(out, "manifest.json")
if not os.path.exists(manifest):
    sys.exit(0)
for test in json.load(open(manifest)):
    for att in test.get("attachments", []):
        src = os.path.join(out, att["exportedFileName"])
        name = att.get("suggestedHumanReadableName") or att["exportedFileName"]
        # XCTest adds its own failure diagnostics (AX dumps, recordings,
        # synthesized-event logs). Only our named captures are wanted.
        if not name.endswith(".png") or "_0_" not in name:
            continue
        if name.startswith(("Debug description", "App UI hierarchy", "UI Snapshot",
                            "Synthesized Event", "Screen Recording")):
            continue
        # "grouping-machine_0_<uuid>.png" -> "grouping-machine"
        name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", "", name)
        name = re.sub(r"\.png$", "", name)
        dst = os.path.join("build", f"native-{name}.png")
        if os.path.exists(src):
            shutil.copyfile(src, dst)
            print("screenshot:", dst)
PY
fi

exit $STATUS
