#!/usr/bin/env python3
"""Exercise packaged agent callbacks with isolated state and optional real CLI turns."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / ".build/debug/spookky-launch"

FAKE_CLI = r'''
import json, os, re, subprocess, sys, tomllib
args = sys.argv[1:]
if "--version" in args:
    print(os.environ.get("SPOOKKY_FIXTURE_VERSION") or ("0.162.1" if os.environ["SPOOKKY_FIXTURE_PROVIDER"] == "codex" else "2.1.296"))
    sys.exit(0)
if "--help" in args:
    print("--settings --config --dangerously-bypass-hook-trust")
    sys.exit(0)
provider = os.environ["SPOOKKY_FIXTURE_PROVIDER"]
definitions = {}
if provider == "claude" and "--settings" in args:
    definitions = json.loads(args[args.index("--settings") + 1])["hooks"]
else:
    for index, item in enumerate(args):
        if item == "-c" and args[index + 1].startswith("hooks."):
            definitions.update(tomllib.loads(args[index + 1])["hooks"])
def emit(name, **fields):
    payload = dict(hook_event_name=name, session_id="fixture-parent", **fields)
    for entry in definitions.get(name, []):
        if entry.get("matcher") and not re.search(entry["matcher"], fields.get("tool_name", fields.get("notification_type", ""))):
            continue
        for hook in entry["hooks"]:
            command = [hook["command"], *hook["args"]] if "args" in hook else hook["command"]
            result = subprocess.run(command, input=json.dumps(payload), text=True, capture_output=True,
                                    shell=isinstance(command, str), timeout=2)
            assert result.returncode == 0 and not result.stdout, result
with open(os.environ["SPOOKKY_FIXTURE_ARGUMENTS"], "w") as output:
    json.dump(args, output)
emit("SessionStart")
emit("UserPromptSubmit")
emit("PreToolUse", tool_name="request_user_input" if provider == "codex" else "AskUserQuestion")
emit("PostToolUse", tool_name="request_user_input")
emit("SubagentStart", agent_id="child-1", agent_type="Explore")
emit("PostToolUse", agent_id="child-1", tool_name="Bash")
emit("SubagentStop", agent_id="child-1")
if os.environ.get("SPOOKKY_FIXTURE_FAILURE"):
    if provider == "claude": emit("StopFailure", error_details="Fixture API failure")
    sys.exit(7)
emit("Stop", last_assistant_message="Fixture turn finished")
emit("SessionEnd")
'''


def private_json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def run(provider, *, real=False, failure=False, mode="normal", helper=HELPER):
    with tempfile.TemporaryDirectory(prefix="spookky-hook-", dir="/tmp") as directory:
        root = Path(directory)
        binding, secret = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        context = dict(bindingID=binding, secret=secret, root=str(root), helper=str(helper))
        context_path = root / f"agent-terminal-{binding}.json"
        private_json(context_path, context)
        channel = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        channel.bind(str(root / "activity.sock"))
        channel.settimeout(0.1)
        events = []
        stop = threading.Event()

        def receive():
            while not stop.is_set():
                try:
                    events.append(json.loads(channel.recv(8193)))
                except socket.timeout:
                    pass

        listener = threading.Thread(target=receive)
        listener.start()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("SUPERSET_") and key != "SPOOKKY_AGENT_OWNER"}
        environment["SPOOKKY_ACTIVITY_CONTEXT"] = str(context_path)
        if real:
            executable = shutil.which(provider)
            if not executable:
                raise RuntimeError(f"{provider} is not installed")
            prompt = "Reply exactly OK. Do not use tools or change any files."
            original = (["--no-daemon", "exec", "--skip-git-repo-check", "--ephemeral", "--json", "--", prompt]
                        if provider == "codex" else ["--print", "--output-format", "json", prompt])
        else:
            executable = str(root / provider)
            Path(executable).write_text("#!" + shutil.which("python3") + "\n" + FAKE_CLI)
            Path(executable).chmod(0o700)
            environment.update(SPOOKKY_FIXTURE_PROVIDER=provider, SPOOKKY_FIXTURE_ARGUMENTS=str(root / "arguments.json"))
            if failure:
                environment["SPOOKKY_FIXTURE_FAILURE"] = "1"
            original = ["--", "literal ' 日本語 $(touch should-not-exist) `date`\n--dangerously-bypass-hook-trust"]
            if mode == "unsupported":
                environment["SPOOKKY_FIXTURE_VERSION"] = "0.1.0"
            if mode == "disabled":
                original = (["--disable", "hooks"] if provider == "codex" else ["--bare"]) + original
            if mode == "registration-failure":
                (root / f"agent-active-{binding}.json").mkdir(mode=0o700)
            if mode == "nested":
                environment["SPOOKKY_AGENT_OWNER"] = str(uuid.uuid4())
        started = time.monotonic()
        process = subprocess.Popen([str(helper), "--agent-run", provider, "--executable", executable, "--", *original],
                                   cwd=root, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            output, errors = process.communicate(timeout=120 if real else 10)
            time.sleep(0.15)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
            stop.set(); listener.join(timeout=2); channel.close()
        kinds = [event["kind"] for event in events]
        expected = {"attached", "working", "finished", "detached"} if real else {
            "attached", "working", "needsInput", "childStarted", "childActivity", "childEnded", "detached",
            "failed" if failure else "finished",
        }
        if mode == "unsupported":
            expected = {"unsupported", "detached"}
        if mode in ["disabled", "registration-failure", "nested"]:
            expected = set()
            assert not kinds, kinds
        if not expected.issubset(kinds):
            raise AssertionError(f"{provider}: missing {expected - set(kinds)}; exit={process.returncode}; stderr={errors[-800:]}")
        assert all(event["bindingID"] == binding and event["secret"] == secret for event in events)
        assert len({event["invocationID"] for event in events}) == (1 if kinds else 0)
        if not real:
            captured = json.loads((root / "arguments.json").read_text())
            assert captured[-len(original):] == original
            assert not (root / "should-not-exist").exists()
            assert process.returncode == (7 if failure else 0)
            assert not any(flag in captured for flag in ["--dangerously-bypass-hook-trust", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-skip-permissions"])
            if mode != "normal":
                assert captured == original, captured
            if mode == "normal":
                active = json.loads((root / f"agent-active-{binding}.json").read_text())
                invocation_path = root / f"agent-invocation-{active['id']}.json"
                private_json(invocation_path, active)
                for payload in [b"not JSON", b"{" + b" " * 1_048_576]:
                    callback = subprocess.run([str(helper), "--agent-hook", str(invocation_path)], input=payload, capture_output=True, timeout=3)
                    assert callback.returncode == 0 and not callback.stdout and not callback.stderr
        elif process.returncode != 0:
            raise AssertionError(f"{provider} failed: {errors[-800:]}")
        return dict(provider=provider, realCLI=real, failureFixture=failure, mode=mode, events=kinds,
                    elapsedSeconds=round(time.monotonic() - started, 3), exitCode=process.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--real", action="store_true", help="Send one minimal turn to each installed provider using its existing configuration")
    parser.add_argument("--helper", type=Path, default=HELPER)
    args = parser.parse_args()
    args.helper = args.helper.resolve()
    if not args.helper.is_file():
        parser.error("Build spookky-launch first")
    cases = [run(provider, real=args.real, failure=failure, helper=args.helper)
             for provider in ["codex", "claude"] for failure in ([False] if args.real else [False, True])]
    if not args.real:
        cases += [run(provider, mode=mode, helper=args.helper) for provider in ["codex", "claude"]
                  for mode in ["unsupported", "disabled", "registration-failure", "nested"]]
    print(json.dumps(dict(passed=True, cases=cases), indent=2))


if __name__ == "__main__":
    main()
