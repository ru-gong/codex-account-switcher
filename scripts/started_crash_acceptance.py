#!/usr/bin/env python3
"""T42: kill an owned synthetic worker after app-start state and a target refresh.

Builds the unchanged production core with a test-only entry point. Never launches
Codex, reads production auth, or uses the production Keychain.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import signal
import subprocess
import tempfile
import time


def require(condition, label):
    if not condition:
        raise RuntimeError(label)


def run_acceptance(repo, evidence):
    result = {"case": "T42", "scope": "E0 synthetic subprocesses", "status": "FAIL",
              "started_at": datetime.datetime.now().astimezone().isoformat(),
              "writer_detection": "injected synthetic marker", "real_app_launched": False,
              "real_account_switched": False, "checks": []}
    core = sorted((repo / "Sources/SwitcherCore").glob("*.swift"))
    worker_source = repo / "Tests/AcceptanceHarness/StartedCrashWorker.swift"
    result["source_sha256"] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in [*core, worker_source]}
    try:
        with tempfile.TemporaryDirectory(prefix="switcher-started-build-") as build:
            binary = pathlib.Path(build) / "started-crash-worker"
            compiled = subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5",
                                       *map(str, core), str(worker_source), "-o", str(binary)],
                                      capture_output=True, text=True, timeout=90)
            (evidence / "build.log").write_text(compiled.stdout + compiled.stderr)
            require(compiled.returncode == 0, "compile_failed")
            result["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
            with tempfile.TemporaryDirectory(prefix="switcher-started-crash-") as temporary:
                root = pathlib.Path(temporary).resolve()
                auth = root / "codex-home/auth.json"
                index = root / "state/accounts.json"

                def run(operation, expected=0):
                    p = subprocess.run([str(binary), str(root), operation],
                                       capture_output=True, text=True, timeout=10)
                    require(p.returncode == expected, "worker_exit_" + operation)
                    require("SYNTHETIC_REFRESH" not in p.stdout + p.stderr, "secret_in_output")
                    return p.stdout.strip()

                def ledger():
                    return json.loads(index.read_text())

                def account_b():
                    return next(a for a in ledger()["accounts"]
                                if a["identity"]["workspace"] == "demo-workspace-B")

                run("init")
                original_a = auth.read_bytes()
                child = subprocess.Popen([str(binary), str(root), "started-wait"],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 10
                    while not (root / "ready").exists():
                        require(child.poll() is None, "worker_exited_before_ready")
                        require(time.monotonic() < deadline, "barrier_timeout")
                        time.sleep(.01)
                    require(ledger()["transaction"]["phase"] == "pendingConfirmation", "wrong_phase")
                    refreshed_b = auth.read_bytes()
                    require(b"SYNTHETIC_REFRESH_B_9" in refreshed_b, "missing_refresh")
                    require(account_b()["generation"] == 1, "refresh_already_saved")
                    before_index = index.read_bytes()
                    child.kill()
                    out, err = child.communicate(timeout=10)
                    require(child.returncode == -signal.SIGKILL, "not_sigkill")
                    require(b"SYNTHETIC_REFRESH" not in out + err, "secret_in_child_output")
                    result["checks"].append("SIGKILL after pendingConfirmation and unsaved B refresh")

                    require(run("rollback", expected=1) == "writersRunning", "missing_writer_guard")
                    require(auth.read_bytes() == refreshed_b and index.read_bytes() == before_index,
                            "blocked_recovery_mutated_state")
                    result["checks"].append("new process refuses rollback while synthetic writer is active")

                    (root / "synthetic-writer-active").unlink()
                    run("rollback")
                    require(auth.read_bytes() == original_a, "A_not_restored")
                    require(ledger().get("transaction") is None, "pending_after_rollback")
                    b = account_b()
                    require(b["generation"] == 2 and len(b["secretHistory"]) == 2, "B_generation_not_retained")
                    require((root / "fake-secrets" / b["secret"]).read_bytes() == refreshed_b,
                            "saved_B_not_latest")
                    result["checks"].append("new process retains latest B as generation 2 and restores complete A")

                    run("select-b-again")
                    require(auth.read_bytes() == refreshed_b and ledger().get("transaction") is None,
                            "next_selection_downgrades_B")
                    result["checks"].append("next explicit B selection uses the refreshed generation")
                    result["status"] = "PASS"
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=10)
            require(not root.exists(), "synthetic_root_not_cleaned")
            result["synthetic_root_cleaned"] = True
    except Exception as error:
        result["error_type"] = type(error).__name__
        if isinstance(error, RuntimeError):
            result["failed_check"] = str(error)
    result["completed_at"] = datetime.datetime.now().astimezone().isoformat()
    (evidence / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result["status"] == "PASS"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="evidence/started-crash-acceptance")
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    evidence = pathlib.Path(args.output_dir).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    raise SystemExit(0 if run_acceptance(repo, evidence) else 1)
