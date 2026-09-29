#!/usr/bin/env bash
# qa-gate.sh — Phase 5e concrete, shell-driven delivery verification.
#
# A dispatched request is registered with its git baseline. The worker later
# sends an async `hermes-request qa REQUEST_ID` completion request; Hermes runs
# this gate from the serial consumer and records an immutable JSON result.
#
# Usage:
#   qa-gate.sh register --request-file PATH
#   qa-gate.sh transition --request-id ID --status dispatched|dispatch_uncertain
#   qa-gate.sh run --request-id ID [--completion-file PATH]
#   qa-gate.sh status --request-id ID
#
# Supported qa_checks types:
#   commit_advanced, clean_worktree, branch_matches, file_exists,
#   command_exit_zero, result_present
set -euo pipefail

RUN_DIR="${HERMES_TASK_RUN_DIR:-$HOME/.hermes/task-runs}"
TICKET_DIR="${HERMES_TICKET_DIR:-$HOME/vaults/kevin/tickets}"
QA_TIMEOUT="${HERMES_QA_TIMEOUT_SECONDS:-600}"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \?//'
}

safe_id() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._:-]+$ ]]
}

cmd="${1:-}"
shift || true

case "$cmd" in
  register)
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
    mkdir -p "$RUN_DIR"
    RUN_DIR="$RUN_DIR" TICKET_DIR="$TICKET_DIR" REQUEST_FILE="$request_file" python3 - <<'PY'
import json
import hashlib
import os
import pathlib
import re
import subprocess
import tempfile
from datetime import datetime, timezone

run_root = pathlib.Path(os.environ["RUN_DIR"]).expanduser()
ticket_root = pathlib.Path(os.environ["TICKET_DIR"]).expanduser().resolve()
request_path = pathlib.Path(os.environ["REQUEST_FILE"])
request = json.loads(request_path.read_text(encoding="utf-8"))
request_id = str(request.get("request_id") or "")
if not re.fullmatch(r"[A-Za-z0-9._:-]+", request_id):
    raise SystemExit("error: request has an invalid request_id")


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def contract_hash(value):
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        fsync_directory(path.parent)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def resolve_workspace():
    candidates = []
    configured = str(request.get("working_directory") or "").strip()
    repository = str(request.get("repository") or "").strip()
    if configured:
        candidates.append(pathlib.Path(configured).expanduser())
    if repository:
        repo_path = pathlib.Path(repository).expanduser()
        candidates.append(repo_path)
        if not repo_path.is_absolute():
            candidates.extend((
                pathlib.Path.home() / repo_path,
                pathlib.Path.home() / repo_path.name,
            ))
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved.is_dir():
            return resolved
    return None


def git_value(workspace, *args):
    if workspace is None:
        return ""
    result = subprocess.run(
        ["git", "-C", str(workspace), *args],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


workspace = resolve_workspace()
task_dir = run_root / request_id
task_dir.mkdir(parents=True, exist_ok=True)
os.chmod(task_dir, 0o700)
stored_request = task_dir / "request.json"
incoming_hash = contract_hash(request)
incoming_raw_hash = hashlib.sha256(request_path.read_bytes()).hexdigest()
stored_raw_hash = ""
if stored_request.exists():
    existing = json.loads(stored_request.read_text(encoding="utf-8"))
    if existing.get("request_id") != request_id:
        raise SystemExit("error: task-run request conflict")
    stored_hash = contract_hash(existing)
    stored_raw_hash = hashlib.sha256(stored_request.read_bytes()).hexdigest()
    if stored_hash != incoming_hash:
        raise SystemExit("error: queued request differs from the registered delivery contract")
else:
    atomic_json(stored_request, request)

state_path = task_dir / "state.json"
timestamp = now()
previous_state = {}
if state_path.exists():
    previous_state = json.loads(state_path.read_text(encoding="utf-8"))
expected_hash = str(previous_state.get("request_sha256") or "")
if expected_hash and expected_hash != incoming_hash:
    legacy_match = (
        not previous_state.get("request_hash_format")
        and expected_hash in {incoming_raw_hash, stored_raw_hash}
    )
    if not legacy_match:
        raise SystemExit("error: queued request hash does not match the durable delivery contract")
if previous_state.get("registered_at"):
    previous_state["request_sha256"] = incoming_hash
    previous_state["request_hash_format"] = "canonical-json-v1"
    atomic_json(state_path, previous_state)
    print(json.dumps(previous_state))
    raise SystemExit(0)
state = {
    **previous_state,
    "request_id": request_id,
    "correlation_id": request.get("correlation_id", ""),
    "status": "registered",
    "registered_at": previous_state.get("registered_at") or timestamp,
    "workspace": str(workspace) if workspace else "",
    "baseline_head": git_value(workspace, "rev-parse", "HEAD"),
    "baseline_branch": git_value(workspace, "branch", "--show-current"),
    "agent": request.get("agent_id") or request.get("agent") or "",
    "ticket_id": request.get("ticket_id") or "",
    "source_ticket": request.get("source_ticket") or "",
    "request_sha256": incoming_hash,
    "request_hash_format": "canonical-json-v1",
}
atomic_json(state_path, state)
print(json.dumps(state))
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
    safe_id "$request_id" || {
      echo "error: valid --request-id is required" >&2
      exit 2
    }
    case "$status" in dispatched|dispatch_uncertain) ;; *)
      echo "error: status must be dispatched or dispatch_uncertain" >&2
      exit 2
      ;;
    esac
    task_dir="$RUN_DIR/$request_id"
    [[ -f "$task_dir/request.json" && -f "$task_dir/state.json" ]] || {
      echo "error: task run not found: $request_id" >&2
      exit 2
    }
    exec 9>"$task_dir/.state.lock"
    flock 9
    RUN_DIR="$RUN_DIR" TICKET_DIR="$TICKET_DIR" REQUEST_ID="$request_id" \
      NEXT_STATUS="$status" python3 - <<'PY'
import json
import os
import pathlib
import re
import tempfile
from datetime import datetime, timezone

run_root = pathlib.Path(os.environ["RUN_DIR"]).expanduser()
ticket_root = pathlib.Path(os.environ["TICKET_DIR"]).expanduser().resolve()
request_id = os.environ["REQUEST_ID"]
next_status = os.environ["NEXT_STATUS"]
task_dir = run_root / request_id
request = json.loads((task_dir / "request.json").read_text(encoding="utf-8"))
state_path = task_dir / "state.json"
state = json.loads(state_path.read_text(encoding="utf-8"))


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        fsync_directory(path.parent)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def update_ticket(status):
    source = str(request.get("source_ticket") or "")
    if not source:
        return
    try:
        path = pathlib.Path(source).expanduser().resolve()
        path.relative_to(ticket_root)
    except (OSError, ValueError):
        return
    if not path.is_file():
        return
    content = path.read_text(encoding="utf-8")
    if not content.startswith("---\n"):
        return
    content, count = re.subn(
        r"(?m)^status:\s*[^\n]*$",
        f"status: {status}",
        content,
        count=1,
    )
    if count:
        atomic_text(path, content)


timestamp = now()
if next_status == "dispatched":
    if state.get("status") not in {"registered", "dispatched"}:
        raise SystemExit(f"error: cannot mark {state.get('status')} as dispatched")
    state["status"] = "dispatched"
    state["dispatched_at"] = state.get("dispatched_at") or timestamp
    update_ticket("in_progress")
else:
    if state.get("status") in {"qa_pass", "qa_fail"}:
        raise SystemExit("error: terminal QA state cannot become dispatch_uncertain")
    state["status"] = "dispatch_uncertain"
    state["dispatch_uncertain_at"] = state.get("dispatch_uncertain_at") or timestamp
    state["failed_at"] = state.get("failed_at") or timestamp
    update_ticket("blocked")
atomic_text(state_path, json.dumps(state, indent=2) + "\n")
print(json.dumps(state))
PY
    ;;

  run)
    request_id=""
    completion_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --request-id) request_id="${2:?--request-id needs a value}"; shift 2 ;;
        --completion-file) completion_file="${2:?--completion-file needs a value}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    safe_id "$request_id" || {
      echo "error: valid --request-id is required" >&2
      exit 2
    }
    [[ -z "$completion_file" || -f "$completion_file" ]] || {
      echo "error: completion file not found: $completion_file" >&2
      exit 2
    }
    task_dir="$RUN_DIR/$request_id"
    [[ -f "$task_dir/request.json" && -f "$task_dir/state.json" ]] || {
      echo "error: task run not found: $request_id" >&2
      exit 2
    }
    exec 9>"$task_dir/.qa.lock"
    flock -n 9 || {
      echo "error: QA already running for $request_id" >&2
      exit 2
    }
    RUN_DIR="$RUN_DIR" TICKET_DIR="$TICKET_DIR" REQUEST_ID="$request_id" \
      COMPLETION_FILE="$completion_file" QA_TIMEOUT="$QA_TIMEOUT" \
      ALLOW_UNCERTAIN="${HERMES_QA_ALLOW_UNCERTAIN:-0}" python3 - <<'PY'
import json
import hashlib
import os
import pathlib
import re
import subprocess
import tempfile
from datetime import datetime, timezone

run_root = pathlib.Path(os.environ["RUN_DIR"]).expanduser()
ticket_root = pathlib.Path(os.environ["TICKET_DIR"]).expanduser().resolve()
request_id = os.environ["REQUEST_ID"]
task_dir = run_root / request_id
request = json.loads((task_dir / "request.json").read_text(encoding="utf-8"))
state_path = task_dir / "state.json"
state = json.loads(state_path.read_text(encoding="utf-8"))
result_path = task_dir / "result.json"
timeout = max(1, min(3600, int(os.environ.get("QA_TIMEOUT", "600"))))
allow_uncertain = os.environ.get("ALLOW_UNCERTAIN") == "1"


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def contract_hash(value):
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def atomic_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        fsync_directory(path.parent)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def atomic_json(path, value):
    atomic_text(path, json.dumps(value, indent=2) + "\n")


def run_command(argv, cwd=None, shell=False):
    try:
        result = subprocess.run(
            argv,
            cwd=cwd,
            shell=shell,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        output = (result.stdout + result.stderr).strip()
        return result.returncode, output[-4000:]
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 124, str(exc)


def git(workspace, *args):
    return run_command(["git", "-C", str(workspace), *args])


def safe_child(workspace, value):
    if not workspace:
        return None
    try:
        candidate = (workspace / str(value)).resolve()
        candidate.relative_to(workspace)
        return candidate
    except (OSError, ValueError):
        return None


def completion_result():
    path = os.environ.get("COMPLETION_FILE", "")
    if not path:
        return ""
    try:
        value = json.loads(pathlib.Path(path).read_text(encoding="utf-8")).get("result", "")
    except (OSError, ValueError):
        return ""
    return str(value)[:65536].strip()


def update_ticket(source, status, report):
    if not source:
        return
    try:
        path = pathlib.Path(source).expanduser().resolve()
        path.relative_to(ticket_root)
    except (OSError, ValueError):
        return
    if not path.is_file():
        return
    content = path.read_text(encoding="utf-8")
    if not content.startswith("---\n"):
        return
    content, count = re.subn(
        r"(?m)^status:\s*[^\n]*$",
        f"status: {status}",
        content,
        count=1,
    )
    if not count:
        return
    if report:
        results = (
            "## Results\n"
            f"QA run `{request_id}`: **{status}**\n\n"
            f"{report.strip()}\n"
        )
        if re.search(r"(?m)^## Results\s*$", content):
            content = re.sub(
                r"(?ms)^## Results\s*$.*?(?=^## |\Z)",
                results,
                content,
                count=1,
            )
        else:
            content = content.rstrip() + "\n\n" + results
    atomic_text(path, content)


source_status = str(state.get("status") or "")
if source_status == "dispatch_uncertain" and not allow_uncertain:
    raise SystemExit(
        "error: dispatch_uncertain completion requires explicit lane validation"
    )
if source_status not in {"dispatched", "dispatch_uncertain", "qa_pass", "qa_fail"}:
    raise SystemExit(
        f"error: delivery state {source_status or 'missing'} cannot complete QA"
    )

expected_contract_hash = str(state.get("request_sha256") or "")
actual_contract_hash = contract_hash(request)
if expected_contract_hash and actual_contract_hash != expected_contract_hash:
    if result_path.exists():
        raise SystemExit("error: immutable QA result has a mutated delivery contract")

report_path = task_dir / "result.md"
report = completion_result()
if not report and report_path.is_file():
    report = report_path.read_text(encoding="utf-8").strip()

if result_path.exists():
    existing = json.loads(result_path.read_text(encoding="utf-8"))
    existing_status = str(existing.get("status") or "")
    if (
        existing.get("request_id") != request_id
        or existing_status not in {"qa_pass", "qa_fail"}
    ):
        raise SystemExit("error: immutable QA result is invalid")
    result_hash = str(existing.get("request_sha256") or expected_contract_hash)
    if result_hash != actual_contract_hash:
        raise SystemExit("error: immutable QA result belongs to a different contract")
    if report:
        atomic_text(report_path, report + "\n")
    update_ticket(
        request.get("source_ticket"),
        "pending_review" if existing_status == "qa_pass" else "blocked",
        report,
    )
    state.update({
        "status": existing_status,
        "qa_completed_at": existing.get("checked_at") or state.get("qa_completed_at"),
    })
    atomic_json(state_path, state)
    print(json.dumps(existing))
    raise SystemExit(0 if existing_status == "qa_pass" else 1)

if source_status in {"qa_pass", "qa_fail"}:
    raise SystemExit("error: terminal QA state is missing its immutable result")

workspace_value = str(state.get("workspace") or "")
workspace = pathlib.Path(workspace_value).resolve() if workspace_value else None
if report:
    atomic_text(report_path, report + "\n")

checks = request.get("qa_checks") or []
results = []
if expected_contract_hash and actual_contract_hash != expected_contract_hash:
    results.append({
        "index": 0,
        "type": "contract_unchanged",
        "passed": False,
        "detail": "registered request.json changed after dispatch",
    })
for index, check in enumerate(checks, 1):
    if not isinstance(check, dict):
        results.append({"index": index, "type": "invalid", "passed": False,
                        "detail": "check must be an object"})
        continue
    check_type = str(check.get("type") or "")
    value = str(check.get("value") or "")
    passed = False
    detail = ""

    if check_type == "commit_advanced":
        baseline = str(state.get("baseline_head") or "")
        code, current = git(workspace, "rev-parse", "HEAD") if workspace else (2, "")
        ancestor_code, _ = (
            git(workspace, "merge-base", "--is-ancestor", baseline, current)
            if workspace and baseline and current
            else (2, "")
        )
        passed = bool(
            baseline
            and code == 0
            and current
            and current != baseline
            and ancestor_code == 0
        )
        detail = f"baseline={baseline[:12] or 'missing'} current={current[:12] or 'missing'}"
    elif check_type == "clean_worktree":
        code, output = git(workspace, "status", "--porcelain") if workspace else (2, "workspace unavailable")
        passed = code == 0 and not output
        detail = "worktree clean" if passed else (output or "not a git workspace")
    elif check_type == "branch_matches":
        code, branch = git(workspace, "branch", "--show-current") if workspace else (2, "")
        passed = code == 0 and branch == value
        detail = f"expected={value or 'missing'} actual={branch or 'missing'}"
    elif check_type == "file_exists":
        candidate = safe_child(workspace, value)
        passed = bool(candidate and candidate.is_file())
        detail = value if candidate else "path escapes or workspace unavailable"
    elif check_type == "command_exit_zero":
        if not workspace:
            detail = "workspace unavailable"
        elif not value or len(value) > 1000:
            detail = "command missing or exceeds 1000 characters"
        else:
            code, output = run_command(["bash", "-lc", value], cwd=workspace)
            passed = code == 0
            detail = output or f"exit {code}"
    elif check_type == "result_present":
        passed = bool(report)
        detail = f"{len(report)} result characters" if report else "completion report missing"
    else:
        detail = f"unsupported check type: {check_type or 'missing'}"

    results.append({
        "index": index,
        "type": check_type,
        "value": value,
        "passed": passed,
        "detail": detail[-4000:],
    })

if not results:
    results.append({
        "index": 1,
        "type": "concrete_checks_required",
        "passed": False,
        "detail": "request declared no concrete qa_checks",
    })

passed = all(item["passed"] for item in results)
status = "qa_pass" if passed else "qa_fail"
result = {
    "request_id": request_id,
    "correlation_id": request.get("correlation_id", ""),
    "status": status,
    "checked_at": now(),
    "workspace": str(workspace) if workspace else "",
    "checks": results,
    "ticket_id": request.get("ticket_id") or "",
    "has_result": bool(report),
    "request_sha256": actual_contract_hash,
    "source_status": source_status,
}
atomic_json(result_path, result)
update_ticket(
    request.get("source_ticket"),
    "pending_review" if passed else "blocked",
    report,
)
state.update({"status": status, "qa_completed_at": result["checked_at"]})
atomic_json(state_path, state)
print(json.dumps(result))
raise SystemExit(0 if passed else 1)
PY
    ;;

  status)
    request_id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --request-id) request_id="${2:?--request-id needs a value}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    safe_id "$request_id" || {
      echo "error: valid --request-id is required" >&2
      exit 2
    }
    if [[ -f "$RUN_DIR/$request_id/result.json" ]]; then
      python3 -m json.tool "$RUN_DIR/$request_id/result.json"
    elif [[ -f "$RUN_DIR/$request_id/state.json" ]]; then
      python3 -m json.tool "$RUN_DIR/$request_id/state.json"
    else
      echo "error: task run not found: $request_id" >&2
      exit 2
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
