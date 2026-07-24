#!/usr/bin/env python3
"""Shared durable deployment-approval state contract.

Mission Control and the Hermes shell command both use this module so deployment
IDs, locking, record validation, immutability, and exit semantics cannot drift.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone


DEPLOYMENT_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
MAX_RECORD_BYTES = 16 * 1024
REQUEST_FIELD_LIMITS = {
    "title": 160,
    "summary": 1000,
    "repository": 240,
    "ref": 240,
    "checks": 1000,
    "rollback": 1000,
    "correlation_id": 200,
    "requested_by": 200,
    "created_at": 64,
}
DECISION_FIELD_LIMITS = {
    "reason": 2000,
    "decided_by": 200,
    "decided_at": 64,
}
ALLOWED_RISKS = {"low", "medium", "high", "critical"}
EXIT_PENDING = 1
EXIT_DENIED = 2
EXIT_INVALID = 3
EXIT_CONFLICT = 5


class ApprovalStateError(Exception):
    """Base class for an invalid or unsafe approval-state operation."""


class InvalidDeploymentId(ApprovalStateError):
    """The deployment ID cannot safely identify a state file."""


class MissingRequest(ApprovalStateError):
    """No durable request exists for the deployment."""


class InvalidRecord(ApprovalStateError):
    """A safety-critical state file exists but is not valid."""


class ExistingRequest(ApprovalStateError):
    """A deployment request or decision already owns the requested ID."""


class DecisionConflict(ApprovalStateError):
    """A second decision conflicts with the immutable first decision."""


def validate_deployment_id(value):
    """Return a canonical safe deployment ID or raise."""
    deployment_id = str(value or "")
    if not DEPLOYMENT_ID_PATTERN.fullmatch(deployment_id):
        raise InvalidDeploymentId(
            "deployment id must start with an alphanumeric character and use "
            "at most 128 letters, numbers, dots, underscores, or hyphens"
        )
    return deployment_id


def _request_path(deploy_dir, deployment_id):
    return Path(deploy_dir) / f"{deployment_id}.json"


def _approval_path(approval_dir, deployment_id):
    return Path(approval_dir) / f"{deployment_id}.json"


def _read_record(path, label):
    try:
        if path.stat().st_size > MAX_RECORD_BYTES:
            raise InvalidRecord(
                f"{label} exceeds the {MAX_RECORD_BYTES}-byte limit: {path}"
            )
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError) as exc:
        raise InvalidRecord(f"{label} is unreadable or corrupt: {path}") from exc
    if not isinstance(record, dict) or not record:
        raise InvalidRecord(f"{label} must be a non-empty JSON object: {path}")
    return record


def _bounded_text(record, field, limit, label, required=False):
    value = record.get(field, "")
    if not isinstance(value, str):
        raise InvalidRecord(f"{label} field '{field}' must be text")
    if required and not value.strip():
        raise InvalidRecord(f"{label} field '{field}' is required")
    if len(value.encode("utf-8")) > limit:
        raise InvalidRecord(
            f"{label} field '{field}' exceeds the {limit}-byte limit"
        )
    return value


def _validate_request(request, deployment_id):
    if request.get("id") != deployment_id:
        raise InvalidRecord(
            f"deployment request id does not match filename: {deployment_id}"
        )
    for field, limit in REQUEST_FIELD_LIMITS.items():
        _bounded_text(
            request,
            field,
            limit,
            "deployment request",
            required=field in ("title", "summary"),
        )
    if request.get("risk", "medium") not in ALLOWED_RISKS:
        raise InvalidRecord(f"deployment request has invalid risk: {deployment_id}")
    if request.get("status", "pending") != "pending":
        raise InvalidRecord(f"deployment request has invalid status: {deployment_id}")
    return request


def _validate_decision(decision, deployment_id):
    if decision.get("deployment_id") != deployment_id:
        raise InvalidRecord(
            f"deployment decision id does not match filename: {deployment_id}"
        )
    if decision.get("decision") not in ("approve", "deny"):
        raise InvalidRecord(
            f"deployment decision must contain approve or deny: {deployment_id}"
        )
    for field, limit in DECISION_FIELD_LIMITS.items():
        _bounded_text(decision, field, limit, "deployment decision")
    return decision


def _load_request(deploy_dir, deployment_id):
    path = _request_path(deploy_dir, deployment_id)
    if not path.exists():
        raise MissingRequest(f"deployment request not found: {deployment_id}")
    request = _read_record(path, "deployment request")
    return _validate_request(request, deployment_id)


def _load_decision(approval_dir, deployment_id):
    path = _approval_path(approval_dir, deployment_id)
    if not path.exists():
        return None
    decision = _read_record(path, "deployment decision")
    return _validate_decision(decision, deployment_id)


def _atomic_write(path, record):
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        except (AttributeError, OSError):
            directory_fd = None
        if directory_fd is not None:
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


@contextmanager
def _state_lock(deploy_dir, approval_dir=None):
    deploy_path = Path(deploy_dir)
    deploy_path.mkdir(parents=True, exist_ok=True)
    with open(deploy_path / ".approval.lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if approval_dir is not None:
            Path(approval_dir).mkdir(parents=True, exist_ok=True)
        yield


def create_request(deploy_dir, approval_dir, record):
    """Create one durable deployment request under the shared state lock."""
    deployment_id = validate_deployment_id(record.get("id"))
    _validate_request(record, deployment_id)

    deploy_path = Path(deploy_dir)
    approval_path = Path(approval_dir)
    request_file = _request_path(deploy_path, deployment_id)
    decision_file = _approval_path(approval_path, deployment_id)

    with _state_lock(deploy_path, approval_path):
        if request_file.exists():
            raise ExistingRequest(f"deployment request already exists: {deployment_id}")
        if decision_file.exists():
            raise ExistingRequest(f"deployment decision already exists: {deployment_id}")
        _atomic_write(request_file, record)
    return record


def record_decision(
    deploy_dir,
    approval_dir,
    deployment_id,
    decision,
    reason="",
    decided_by="operator",
):
    """Record one immutable decision, returning an idempotency-aware result."""
    deployment_id = validate_deployment_id(deployment_id)
    if decision not in ("approve", "deny"):
        raise InvalidRecord("decision must be approve or deny")
    decision_record = {
        "deployment_id": deployment_id,
        "decision": decision,
        "reason": str(reason or ""),
        "decided_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "decided_by": str(decided_by or "operator"),
    }
    _validate_decision(decision_record, deployment_id)

    with _state_lock(deploy_dir, approval_dir):
        _load_request(deploy_dir, deployment_id)
        existing = _load_decision(approval_dir, deployment_id)
        if existing:
            if existing["decision"] != decision:
                raise DecisionConflict(
                    f"deployment {deployment_id} already has decision "
                    f"{existing['decision']}; refusing conflicting {decision}"
                )
            return {
                "status": decision,
                "deployment_id": deployment_id,
                "idempotent": True,
            }

        _atomic_write(
            _approval_path(approval_dir, deployment_id),
            decision_record,
        )

    return {
        "status": decision,
        "deployment_id": deployment_id,
        "idempotent": False,
    }


def check_decision(deploy_dir, approval_dir, deployment_id):
    """Return pending or a validated immutable decision."""
    deployment_id = validate_deployment_id(deployment_id)
    with _state_lock(deploy_dir):
        _load_request(deploy_dir, deployment_id)
        return _load_decision(approval_dir, deployment_id)


def deployment_status(deploy_dir, approval_dir, deployment_id):
    """Return the validated request and optional validated decision."""
    deployment_id = validate_deployment_id(deployment_id)
    with _state_lock(deploy_dir):
        request = _load_request(deploy_dir, deployment_id)
        decision = _load_decision(approval_dir, deployment_id)
    return {"request": request, "decision": decision}


def list_pending(deploy_dir, approval_dir):
    """Return valid pending requests using the shared ID and record contract."""
    pending = []
    with _state_lock(deploy_dir):
        for path in Path(deploy_dir).glob("*.json"):
            try:
                deployment_id = validate_deployment_id(path.stem)
                request = _load_request(deploy_dir, deployment_id)
            except ApprovalStateError:
                continue
            if _approval_path(approval_dir, deployment_id).exists():
                continue
            pending.append(request)
    pending.sort(key=lambda item: item.get("created_at", ""), reverse=True)
    return pending


def _parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate-id")
    validate.add_argument("deployment_id")

    request = subparsers.add_parser("request")
    request.add_argument("--deploy-dir", required=True)
    request.add_argument("--approval-dir", required=True)
    request.add_argument("--id", required=True)
    request.add_argument("--title", required=True)
    request.add_argument("--summary", required=True)
    request.add_argument("--repository", default="")
    request.add_argument("--ref", default="")
    request.add_argument("--risk", default="medium")
    request.add_argument("--checks", default="")
    request.add_argument("--rollback", default="")
    request.add_argument("--correlation-id", required=True)
    request.add_argument("--requested-by", default="operator")

    decide = subparsers.add_parser("decide")
    decide.add_argument("--deploy-dir", required=True)
    decide.add_argument("--approval-dir", required=True)
    decide.add_argument("--id", required=True)
    decide.add_argument("--decision", choices=("approve", "deny"), required=True)
    decide.add_argument("--reason", default="")
    decide.add_argument("--by", default="operator")

    for command in ("check", "status"):
        state = subparsers.add_parser(command)
        state.add_argument("--deploy-dir", required=True)
        state.add_argument("--approval-dir", required=True)
        state.add_argument("--id", required=True)

    list_command = subparsers.add_parser("list")
    list_command.add_argument("--deploy-dir", required=True)
    list_command.add_argument("--approval-dir", required=True)
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    try:
        if args.command == "validate-id":
            print(validate_deployment_id(args.deployment_id))
            return 0
        if args.command == "request":
            record = {
                "id": args.id,
                "title": args.title,
                "summary": args.summary,
                "repository": args.repository,
                "ref": args.ref,
                "risk": args.risk,
                "checks": args.checks,
                "rollback": args.rollback,
                "correlation_id": args.correlation_id,
                "requested_by": args.requested_by,
                "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "status": "pending",
            }
            create_request(args.deploy_dir, args.approval_dir, record)
            print(json.dumps(record))
            return 0
        if args.command == "decide":
            result = record_decision(
                args.deploy_dir,
                args.approval_dir,
                args.id,
                args.decision,
                args.reason,
                args.by,
            )
            print(json.dumps(result))
            return 0
        if args.command == "check":
            result = check_decision(
                args.deploy_dir, args.approval_dir, args.id
            )
            if result is None:
                print(json.dumps({"status": "pending"}))
                return EXIT_PENDING
            print(json.dumps(result))
            return 0 if result["decision"] == "approve" else EXIT_DENIED
        if args.command == "status":
            result = deployment_status(
                args.deploy_dir, args.approval_dir, args.id
            )
            print(json.dumps(result, indent=2))
            return 0
        if args.command == "list":
            print(json.dumps(list_pending(args.deploy_dir, args.approval_dir), indent=2))
            return 0
    except DecisionConflict as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_CONFLICT
    except ApprovalStateError as exc:
        if args.command == "check":
            print(json.dumps({"status": "invalid", "error": str(exc)}))
        else:
            print(f"error: {exc}", file=sys.stderr)
        return EXIT_INVALID
    raise AssertionError(f"unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
