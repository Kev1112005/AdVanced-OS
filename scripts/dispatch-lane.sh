#!/usr/bin/env bash
# dispatch-lane.sh — one persistent record for the global serial dispatch lane.
#
# The lane never expires. Once transport starts, only the exact request's
# terminal QA or durable pipeline completion may release it.
#
# Usage:
#   dispatch-lane.sh acquire --request-file PATH
#   dispatch-lane.sh transition --request-id ID --status submitting|active|uncertain
#   dispatch-lane.sh release --request-id ID --reason preflight_failed|qa_terminal|pipeline_complete
#   dispatch-lane.sh matches --request-id ID
#   dispatch-lane.sh status
set -euo pipefail

LANE_FILE="${HERMES_DISPATCH_LANE_FILE:-$HOME/.hermes/dispatch-lane.json}"
LOCK_FILE="${HERMES_DISPATCH_LANE_LOCK:-$HOME/.hermes/dispatch-lane.lock}"

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \?//'
}

safe_id() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._:-]+$ ]]
}

mkdir -p "$(dirname "$LANE_FILE")" "$(dirname "$LOCK_FILE")"
umask 077
exec 9>"$LOCK_FILE"
flock 9

cmd="${1:-}"
shift || true

case "$cmd" in
  acquire)
    request_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --request-file) request_file="${2:?--request-file needs a value}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    [[ -f "$request_file" ]] || {
      echo "error: request file not found: $request_file" >&2
      exit 2
    }
    LANE_FILE="$LANE_FILE" REQUEST_FILE="$request_file" python3 - <<'PY'
import json
import os
import pathlib
import re
import tempfile
from datetime import datetime, timezone

lane_path = pathlib.Path(os.environ["LANE_FILE"])
request_path = pathlib.Path(os.environ["REQUEST_FILE"])


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def atomic_json(path, value):
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


if lane_path.exists():
    try:
        existing = json.loads(lane_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SystemExit(f"error: dispatch lane state is invalid: {exc}")
    print(json.dumps(existing))
    raise SystemExit(3)

try:
    request = json.loads(request_path.read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    raise SystemExit(f"error: request is invalid: {exc}")
request_id = str(request.get("request_id") or "")
if not re.fullmatch(r"[A-Za-z0-9._:-]+", request_id):
    raise SystemExit("error: request has an invalid request_id")
record = {
    "version": 1,
    "request_id": request_id,
    "correlation_id": str(request.get("correlation_id") or ""),
    "agent": str(request.get("agent_id") or request.get("agent") or ""),
    "type": str(request.get("type") or "order"),
    "status": "reserved",
    "acquired_at": now(),
    "updated_at": now(),
}
atomic_json(lane_path, record)
print(json.dumps(record))
PY
    ;;

  transition)
    request_id=""
    status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --request-id) request_id="${2:?--request-id needs a value}"; shift 2 ;;
        --status) status="${2:?--status needs a value}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    safe_id "$request_id" || { echo "error: valid --request-id required" >&2; exit 2; }
    case "$status" in submitting|active|uncertain) ;; *)
      echo "error: invalid lane status '$status'" >&2
      exit 2
      ;;
    esac
    LANE_FILE="$LANE_FILE" REQUEST_ID="$request_id" LANE_STATUS="$status" python3 - <<'PY'
import json
import os
import pathlib
import tempfile
from datetime import datetime, timezone

path = pathlib.Path(os.environ["LANE_FILE"])
if not path.is_file():
    raise SystemExit("error: dispatch lane is open")
try:
    record = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    raise SystemExit(f"error: dispatch lane state is invalid: {exc}")
if record.get("request_id") != os.environ["REQUEST_ID"]:
    raise SystemExit("error: dispatch lane belongs to a different request")
record["status"] = os.environ["LANE_STATUS"]
record["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_name, path)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
print(json.dumps(record))
PY
    ;;

  release)
    request_id=""
    reason=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --request-id) request_id="${2:?--request-id needs a value}"; shift 2 ;;
        --reason) reason="${2:?--reason needs a value}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    safe_id "$request_id" || { echo "error: valid --request-id required" >&2; exit 2; }
    case "$reason" in preflight_failed|qa_terminal|pipeline_complete) ;; *)
      echo "error: invalid release reason '$reason'" >&2
      exit 2
      ;;
    esac
    LANE_FILE="$LANE_FILE" REQUEST_ID="$request_id" RELEASE_REASON="$reason" python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["LANE_FILE"])
if not path.exists():
    print(json.dumps({"status": "open", "idempotent": True}))
    raise SystemExit(0)
try:
    record = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    raise SystemExit(f"error: dispatch lane state is invalid: {exc}")
if record.get("request_id") != os.environ["REQUEST_ID"]:
    raise SystemExit("error: dispatch lane belongs to a different request")
if os.environ["RELEASE_REASON"] == "preflight_failed" and record.get("status") != "reserved":
    raise SystemExit("error: transport started; preflight release is forbidden")
path.unlink()
print(json.dumps({
    "status": "open",
    "released_request_id": os.environ["REQUEST_ID"],
    "reason": os.environ["RELEASE_REASON"],
}))
PY
    ;;

  matches)
    request_id=""
    [[ "${1:-}" == "--request-id" ]] && {
      request_id="${2:?--request-id needs a value}"
      shift 2
    }
    [[ $# -eq 0 ]] || { echo "error: unknown arguments" >&2; exit 2; }
    safe_id "$request_id" || { echo "error: valid --request-id required" >&2; exit 2; }
    LANE_FILE="$LANE_FILE" REQUEST_ID="$request_id" python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["LANE_FILE"])
if not path.is_file():
    raise SystemExit(1)
try:
    record = json.loads(path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(2)
raise SystemExit(0 if record.get("request_id") == os.environ["REQUEST_ID"] else 1)
PY
    ;;

  status)
    [[ $# -eq 0 ]] || { echo "error: status takes no arguments" >&2; exit 2; }
    if [[ -f "$LANE_FILE" ]]; then
      python3 -m json.tool "$LANE_FILE"
    else
      echo '{"status":"open"}'
    fi
    ;;

  -h|--help|help|"")
    usage
    ;;

  *)
    echo "error: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac
