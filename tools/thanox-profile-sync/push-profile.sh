#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="$SCRIPT_DIR/helpers"

ADB_PORT="${ADB_PORT:-}"
DEVICE="${DEVICE:-}"
REMOTE_DIR="${REMOTE_DIR:-/data/local/tmp}"
DELETE_EXISTING=1
ENABLE_AFTER_ADD=1
PUSH_HELPERS=1
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  push-profile.sh -s DEVICE [--adb-port PORT] PROFILE_JSON

Examples:
  tools/thanox-profile-sync/push-profile.sh \
    --adb-port 5038 \
    -s 192.168.50.187:35555 \
    files/profile/profiles/google_play_gms_guard.json

Options:
  -s, --serial DEVICE     adb device serial, for example 192.168.50.187:35555.
      --adb-port PORT     adb server port. Use 5038 if your adb server is there.
      --no-delete         Do not delete existing rules with the same names.
      --no-enable         Import only, do not enable imported rules.
      --no-helper-push    Do not push helper jars before importing.
      --dry-run           Parse and print rule names without touching adb.
  -h, --help              Show this help.

Environment:
  DEVICE, ADB_PORT, REMOTE_DIR can be used instead of command options.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

mvel_string_escape() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
print(s.replace("\\", "\\\\").replace('"', '\\"'))
PY
}

JSON_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--serial)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DEVICE="$2"
      shift 2
      ;;
    --adb-port)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ADB_PORT="$2"
      shift 2
      ;;
    --no-delete)
      DELETE_EXISTING=0
      shift
      ;;
    --no-enable)
      ENABLE_AFTER_ADD=0
      shift
      ;;
    --no-helper-push)
      PUSH_HELPERS=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$JSON_FILE" ]] || die "only one PROFILE_JSON is supported"
      JSON_FILE="$1"
      shift
      ;;
  esac
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -n "$DEVICE" ]] || die "missing device. Pass -s DEVICE or set DEVICE."
fi
[[ -n "$JSON_FILE" ]] || die "missing PROFILE_JSON"
[[ -f "$JSON_FILE" ]] || die "PROFILE_JSON not found: $JSON_FILE"
if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -f "$HELPER_DIR/thanox-profile-tool.jar" ]] || die "missing helper: $HELPER_DIR/thanox-profile-tool.jar"
  [[ -f "$HELPER_DIR/thanox-exec-action-dex.jar" ]] || die "missing helper: $HELPER_DIR/thanox-exec-action-dex.jar"
fi

NORMALIZED_JSON="$(mktemp -t thanox-profile-sync.XXXXXX.json)"
trap 'rm -f "$NORMALIZED_JSON"' EXIT

RULE_NAMES=()
while IFS= read -r rule_name; do
  RULE_NAMES+=("$rule_name")
done < <(python3 - "$JSON_FILE" "$NORMALIZED_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
out_path = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

if isinstance(data, list):
    profiles = data
elif isinstance(data, dict) and isinstance(data.get("profile"), dict):
    profiles = [data["profile"]]
elif isinstance(data, dict) and isinstance(data.get("profiles"), list):
    profiles = data["profiles"]
else:
    raise SystemExit("PROFILE_JSON must be a profile array, or a Thanox repository profile object with profile/profiles")

for item in profiles:
    if not isinstance(item, dict) or not item.get("name"):
        raise SystemExit("each profile item must contain name")

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(profiles, f, ensure_ascii=False, indent=2)

for item in profiles:
    print(item["name"])
PY
)

[[ ${#RULE_NAMES[@]} -gt 0 ]] || die "no rule names found in $JSON_FILE"

ADB=(adb)
if [[ -n "$ADB_PORT" ]]; then
  ADB+=(-P "$ADB_PORT")
fi
ADB+=(-s "$DEVICE")

run_su() {
  local cmd="$1"
  "${ADB[@]}" shell "su -c $(shell_quote "$cmd")"
}

REMOTE_PROFILE_JAR="$REMOTE_DIR/thanox-profile-tool.jar"
REMOTE_EXEC_JAR="$REMOTE_DIR/thanox-exec-action-dex.jar"
REMOTE_JSON="$REMOTE_DIR/$(basename "$JSON_FILE")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> Dry run"
else
  echo "==> Device: $DEVICE"
  if [[ -n "$ADB_PORT" ]]; then
    echo "==> adb port: $ADB_PORT"
  fi
fi
echo "==> Rules:"
printf '    %s\n' "${RULE_NAMES[@]}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> JSON format OK"
  echo "==> Done"
  exit 0
fi

if [[ "$PUSH_HELPERS" -eq 1 ]]; then
  echo "==> Push helper jars"
  "${ADB[@]}" push "$HELPER_DIR/thanox-profile-tool.jar" "$REMOTE_PROFILE_JAR" >/dev/null
  "${ADB[@]}" push "$HELPER_DIR/thanox-exec-action-dex.jar" "$REMOTE_EXEC_JAR" >/dev/null
  "${ADB[@]}" shell "chmod 666 $(shell_quote "$REMOTE_PROFILE_JAR") $(shell_quote "$REMOTE_EXEC_JAR")"
fi

echo "==> Push profile JSON"
"${ADB[@]}" push "$NORMALIZED_JSON" "$REMOTE_JSON"

if [[ "$DELETE_EXISTING" -eq 1 ]]; then
  echo "==> Delete existing rules with the same names"
  for name in "${RULE_NAMES[@]}"; do
    escaped_name="$(mvel_string_escape "$name")"
    action="pm=thanos.profileManager;rule=pm.getRuleByName(\"$escaped_name\");if(rule!=null){pm.deleteRule(rule.id);log.log(\"PROFILE_SYNC_DELETE=\" + rule.id + \":$escaped_name\");}"
    run_su "CLASSPATH=$REMOTE_EXEC_JAR app_process /system/bin ThanoxExecAction $(shell_quote "$action")"
  done
fi

echo "==> Import profile JSON"
run_su "CLASSPATH=$REMOTE_PROFILE_JAR app_process /system/bin ThanoxProfileTool add $(shell_quote "$REMOTE_JSON")"

if [[ "$ENABLE_AFTER_ADD" -eq 1 ]]; then
  echo "==> Enable imported rules"
  for name in "${RULE_NAMES[@]}"; do
    run_su "CLASSPATH=$REMOTE_PROFILE_JAR app_process /system/bin ThanoxProfileTool enable $(shell_quote "$name")"
  done
fi

echo "==> Done"
