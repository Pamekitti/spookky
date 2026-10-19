#!/usr/bin/env python3
"""Check native Claude resume and attach in disposable, offline state."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

from check_agent_hooks import private_json
from runtime_paths import tmux_path

MARKER = "SPOOKKY_CLAUDE_OFFLINE_RESUME"
REPLY = "SPOOKKY_CLAUDE_SAVED_REPLY"


def owned_background_ids(rows, session, checkout):
    return {row["id"] for row in rows if isinstance(row, dict) and row.get("kind") == "background"
            and (session is None or row.get("sessionId") == session) and isinstance(row.get("cwd"), str)
            and os.path.realpath(row["cwd"]) == os.path.realpath(checkout)
            and isinstance(row.get("id"), str) and 0 < len(row["id"]) <= 256
            and row["id"].isascii() and row["id"][0].isalnum()
            and all(character.isalnum() or character in "-_" for character in row["id"])}


class ResponseStub(http.server.BaseHTTPRequestHandler):
    calls = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(min(length, 2_000_000)))
        route = self.path.split("?")[0]
        self.calls.append({"path": route, "stream": request.get("stream"), "messages": len(request.get("messages", []))})
        if route == "/v1/messages/count_tokens":
            self.reply({"input_tokens": 10})
            return
        if route != "/v1/messages":
            self.reply({})
            return
        response = {"id": "msg_fixture", "type": "message", "role": "assistant", "model": request.get("model", "fixture"),
                    "content": [{"type": "text", "text": REPLY}], "stop_reason": "end_turn", "stop_sequence": None,
                    "usage": {"input_tokens": 10, "output_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}
        if not request.get("stream"):
            self.reply(response)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        events = [
            ("message_start", {"type": "message_start", "message": dict(response, content=[], stop_reason=None)}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": REPLY}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 10}}),
            ("message_stop", {"type": "message_stop"})]
        for name, data in events:
            self.wfile.write(("event: " + name + "\ndata: " + json.dumps(data) + "\n\n").encode())
            self.wfile.flush()

    def reply(self, value):
        payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def check(executable, *, activity_helper=None):
    result = {"checks": {}, "observations": {},
              "activity_integration": activity_helper is not None,
              "scope": "Owned loopback response, isolated Claude configuration, disposable checkout and private tmux. No external model request or user session."}

    def record(name, passed, **details):
        result["checks"][name] = passed
        if not passed:
            result["observations"].setdefault("first_failure", {"check": name, **details})
        return passed

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ResponseStub)
    ResponseStub.calls = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="spookky-claude-ownership-", dir="/private/tmp") as folder:
            root = Path(folder)
            checkout, config = root / "checkout", root / "config"
            checkout.mkdir()
            config.mkdir(mode=0o700)
            environment = {key: value for key, value in os.environ.items()
                           if key in ("PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM")}
            environment.update(CLAUDE_CONFIG_DIR=str(config), ANTHROPIC_API_KEY="spookky-disposable-loopback-key",
                               ANTHROPIC_BASE_URL="http://127.0.0.1:" + str(server.server_port),
                               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1",
                               NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
            session = str(uuid.uuid4())
            terminal_prefix = [executable]
            if activity_helper is not None:
                binding = str(uuid.uuid4()).upper()
                context = root / ("agent-terminal-" + binding + ".json")
                private_json(context, {"bindingID": binding, "secret": str(uuid.uuid4()),
                    "root": str(root), "helper": str(activity_helper)})
                environment["SPOOKKY_ACTIVITY_CONTEXT"] = str(context)
                terminal_prefix = [str(activity_helper), "--agent-run", "claude", "--executable", executable, "--"]
            socket = root / "tmux.sock"
            tmux_config = root / "tmux.conf"
            tmux_config.write_text("set -g remain-on-exit on\n")

            def cli(*arguments, timeout=15):
                return subprocess.run([executable, *arguments], cwd=checkout, env=environment,
                                      capture_output=True, text=True, timeout=timeout)

            def tmux(*arguments):
                return subprocess.run([tmux_path(), "-S", str(socket), *arguments], env=environment,
                                      capture_output=True, text=True, timeout=5)

            def registry():
                listing = cli("agents", "--json")
                listing.check_returncode()
                rows = json.loads(listing.stdout)
                if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
                    raise RuntimeError("Claude ownership response is not a list of records")
                return rows

            def capture(name):
                output = tmux("capture-pane", "-p", "-t", name, "-S", "-200")
                output.check_returncode()
                return output.stdout

            background_baseline = None
            try:
                result["provider"] = cli("--version").stdout.strip()
                first = cli("--session-id", session, "--print", MARKER, timeout=30)
                record("native_history_created", first.returncode == 0 and REPLY in first.stdout,
                       status=first.returncode, stderr=first.stderr[:2_000])
                record("exact_id_persisted", bool(list(config.rglob(session + ".jsonl"))))
                if not all(result["checks"].values()):
                    return result
                tmux("-f", str(tmux_config), "new-session", "-d", "-s", "resume", "-x", "150", "-y", "48", "-c", str(checkout),
                     *terminal_prefix, "--resume", session).check_returncode()
                accepted = set()
                for _ in range(120):
                    text = capture("resume")
                    if REPLY in text:
                        break
                    lower = text.lower()
                    for stage, phrases, keys in [
                        ("theme", ["choose the text style"], ["Enter"]),
                        ("api-key", ["do you want to use this api key"], ["Up", "Enter"]),
                        ("security", ["security notes"], ["Enter"]),
                        ("trust", ["trust this folder", "trust the files", "trust this directory"], ["Down", "Enter"])]:
                        if stage not in accepted and any(phrase in lower for phrase in phrases):
                            for key in keys:
                                tmux("send-keys", "-t", "resume", key).check_returncode()
                                time.sleep(0.15)
                            accepted.add(stage)
                            break
                    time.sleep(0.1)
                result["observations"]["onboarding"] = sorted(accepted)
                if not record("foreground_resume_displays_saved_reply", REPLY in text, terminal=text[-4_000:]):
                    return result
                owners = [row for row in registry() if row.get("sessionId") == session and row.get("cwd") == str(checkout)]
                if not record("foreground_exact_owner_reported", any(row.get("kind") == "interactive" and row.get("pid", 0) > 0 for row in owners), owners=owners):
                    return result
                tmux("kill-session", "-t", "=resume").check_returncode()
                released = False
                for _ in range(30):
                    if not any(row.get("sessionId") == session and row.get("kind") == "interactive" for row in registry()):
                        released = True
                        break
                    time.sleep(0.05)
                if not record("foreground_owner_released_before_explicit_background_start", released):
                    return result
                background_baseline = owned_background_ids(registry(), None, checkout)
                background = cli("--background", "--resume", session, timeout=20)
                background.check_returncode()
                identifiers = owned_background_ids(registry(), session, checkout) - background_baseline
                record("explicit_background_start_preserves_exact_id", len(identifiers) == 1)
                if len(identifiers) == 1:
                    identifier = next(iter(identifiers))
                    tmux("new-session", "-d", "-s", "attach", "-x", "150", "-y", "48", "-c", str(checkout), *terminal_prefix, "attach", identifier).check_returncode()
                    for _ in range(60):
                        if REPLY in capture("attach"):
                            break
                        time.sleep(0.1)
                    attached_text = capture("attach")
                    record("native_attach_displays_saved_reply", REPLY in attached_text, terminal=attached_text[-4_000:])
                result["observations"]["loopback_calls"] = ResponseStub.calls
                record("resume_and_attach_send_no_extra_model_turn", sum(call["path"] == "/v1/messages" for call in ResponseStub.calls) == 1)
                return result
            except Exception as error:
                result["checks"]["fixture_completed"] = False
                result["observations"].setdefault("first_failure", {"type": type(error).__name__, "message": str(error)[:2_000]})
                return result
            finally:
                try:
                    if background_baseline is not None:
                        for identifier in owned_background_ids(registry(), None, checkout) - background_baseline:
                            cli("stop", identifier).check_returncode()
                except Exception as error:
                    result["checks"]["owned_cleanup_completed"] = False
                    result["observations"]["cleanup_failure"] = str(error)[:1_000]
                tmux("kill-server")
    finally:
        server.shutdown()
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", default=shutil.which("claude"), help="Installed native Claude executable, outside any Spookky shell wrapper")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--activity-helper", type=Path, help="Also exercise resume and attach through the bundled activity integration")
    arguments = parser.parse_args()
    if not arguments.executable:
        parser.error("An installed Claude executable is required")
    if arguments.activity_helper is not None:
        arguments.activity_helper = arguments.activity_helper.resolve()
        if not os.access(arguments.activity_helper, os.X_OK):
            parser.error("The activity helper must be an executable from a tested app bundle")
    report = check(os.path.realpath(arguments.executable), activity_helper=arguments.activity_helper)
    report["pass"] = bool(report["checks"]) and all(report["checks"].values())
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["pass"] else 1)


if __name__ == "__main__":
    main()
