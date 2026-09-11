#!/usr/bin/env python3
"""Real-PTY bridge smoke test. Uses only Python's standard library; no model calls."""
import fcntl
import base64
import json
import os
import select
import signal
import struct
import sys
import termios
import time


def run(binary):
    master, slave = os.openpty()
    before = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 38, 120, 0, 0))
    child_in, parent_out = os.pipe()
    parent_in, child_out = os.pipe()
    start = time.monotonic()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        for target in (0, 1, 2):
            os.dup2(slave, target)
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        os.dup2(child_in, 3)
        os.dup2(child_out, 4)
        os.closerange(5, 256)
        os.environ["TERM"] = "xterm-256color"
        # Capture clipboard transport without touching the tester's clipboard.
        os.environ["BEAM_AGENT_ION_CLIPBOARD"] = "osc52"
        # Keep the controlling session alive until modes are checked. macOS
        # invalidates tcgetattr on the parent's slave after its session exits.
        frontend = os.fork()
        if frontend == 0:
            os.execv(binary, [binary])
        os.close(3)
        os.close(4)
        _, status = os.waitpid(frontend, 0)
        restored = termios.tcgetattr(0) == before
        os._exit(os.waitstatus_to_exitcode(status) if restored else 90)
    os.close(child_in)
    os.close(child_out)
    screen = bytearray()

    def wait_screen(text, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if text.encode() in screen:
                return
            if select.select([master], [], [], 0.05)[0]:
                screen.extend(os.read(master, 65536))
        raise AssertionError(f"screen missing {text!r}: {screen[-1800:]!r}")

    def send(packet):
        data = json.dumps(packet).encode()
        os.write(parent_out, struct.pack(">I", len(data)) + data)

    def read_exact(count):
        result = bytearray()
        deadline = time.monotonic() + 5
        while len(result) < count:
            assert time.monotonic() < deadline, f"bridge action timed out: {screen[-1200:]!r}"
            readable = select.select([parent_in, master], [], [], 0.05)[0]
            if master in readable:
                screen.extend(os.read(master, 65536))
            if parent_in in readable:
                chunk = os.read(parent_in, count - len(result))
                assert chunk, f"bridge closed: {screen[-1200:]!r}"
                result.extend(chunk)
        return bytes(result)

    def action():
        length = struct.unpack(">I", read_exact(4))[0]
        return json.loads(read_exact(length))

    def type_text(text):
        os.write(master, text.encode())

    try:
        wait_screen("CONNECTING")
        first_paint = (time.monotonic() - start) * 1000
        # Initial screen precedes the first backend packet; typing is safe here.
        type_text("early draft\r")
        time.sleep(0.15)
        assert not select.select([parent_in], [], [], 0)[0], "submitted before init"
        send({"type": "init", "session_id": "smoke-root", "workspace": "/fixture",
              "profile": "echo", "model": "echo", "approval_mode": "ask", "entries": [],
              "workspace_files": ["my file.ex"]})
        wait_screen("READY")
        send({"type": "model_catalog", "combined": True, "model_strategy": "auto", "revision": "r1",
              "models": [{"profile": "fixture", "model": "coder", "enabled": True, "health": "available"}]})
        wait_screen("Loom picks")
        type_text("\x1b[B\r")
        assert action() == {"type": "provider_settings", "action": "lock", "profile": "fixture", "model": "coder", "revision": "r1"}
        send({"type": "settings_applied", "profile": "fixture", "model": "coder", "model_strategy": "manual"})
        wait_screen("MODEL LOCKED")
        type_text("\x1b[A\r")
        assert action() == {"type": "provider_settings", "action": "automatic", "revision": "r1"}
        send({"type": "settings_applied", "profile": "fixture", "model": "coder", "model_strategy": "auto"})
        wait_screen("LOOM PICKS")
        type_text("\x1b")
        time.sleep(0.05)
        type_text("\r")
        assert action() == {"type": "submit", "prompt": "early draft", "attachments": []}
        send({"type": "turn_started", "prompt": "early draft"})
        send({"type": "stream", "event": {"type": "runtime_event", "durability": "durable", "goal_seq": 1,
              "scope": {"session_id": "smoke-root", "root?": True},
              "payload": {"type": "tool_called", "data": {"tool_call_id": "read-1", "name": "read_file", "arguments": {"path": "ACTIVITY_FIXTURE.ex"}}}}})
        wait_screen("ACTIVITY_FIXTURE.ex")
        send({"type": "stream", "event": {"type": "runtime_event", "durability": "durable", "goal_seq": 2,
              "scope": {"session_id": "smoke-root", "root?": True},
              "payload": {"type": "tool_result", "data": {"tool_call_id": "read-1", "name": "read_file", "content": "TOOL_DETAIL_FIXTURE", "is_error": False}}}})
        type_text("\x14")
        wait_screen("TOOL_DETAIL_FIXTURE")
        type_text("\x14")
        send({"type": "stream", "event": {"type": "reasoning_summary_delta", "response_id": "r", "item_id": "summary-1", "summary_index": 0, "delta": "PUBLIC_SUMMARY_FIXTURE"}})
        wait_screen("PUBLIC_SUMMARY_FIXTURE")
        send({"type": "stream", "event": {"type": "text_delta", "response_id": "r", "delta": "ORBITAL_RESULT"}})
        wait_screen("ORBITAL_RESULT")
        type_text("keep it small\r")
        assert action() == {"type": "command", "command": "steer", "query": "keep it small"}
        send({"type": "approval_requested", "approval": {"approval_id": "gate-1", "session_id": "smoke-root",
              "tool": "run_command", "arguments": {"command": "mix test"}}})
        wait_screen("AUTHORITY GATE")
        type_text("\x1b[C\r")
        assert action() == {"type": "approval", "approval_id": "gate-1", "decision": "allow_once"}
        # Differential rendering may retain unchanged letters from the last frame.
        wait_screen("Awaiting runtime")
        type_text("\r")
        time.sleep(0.15)
        assert not select.select([parent_in], [], [], 0)[0], "duplicate approval while resolving"
        send({"type": "approval_resolved", "approval_id": "gate-1", "decision": "allow_once"})
        send({"type": "turn_finished", "ok": True})
        time.sleep(0.15)
        type_text("\x1b[200~line one\n/auto\x1b[201~")
        time.sleep(0.15)
        assert not select.select([parent_in], [], [], 0)[0], "paste submitted a command"
        type_text("\r")
        assert action()["prompt"] == "line one\n/auto"
        send({"type": "turn_finished", "ok": True})
        time.sleep(0.1)
        type_text("Read @my\r")
        time.sleep(0.15)
        assert not select.select([parent_in], [], [], 0)[0], "reference picker submitted"
        type_text("\r")
        assert action()["prompt"] == 'Read @"my file.ex"'
        send({"type": "turn_finished", "ok": True})
        time.sleep(0.15)
        type_text("\x1b[A")
        time.sleep(0.1)
        assert not select.select([parent_in], [], [], 0)[0], "history recall submitted"
        type_text("\r")
        assert action()["prompt"] == 'Read @"my file.ex"'
        send({"type": "turn_finished", "ok": True})
        time.sleep(0.15)
        type_text("/a\t")
        time.sleep(0.1)
        assert not select.select([parent_in], [], [], 0)[0], "slash completion executed"
        type_text("\r")
        assert action() == {"type": "command", "command": "auto", "query": ""}
        type_text("\x19")
        wait_screen("\x1b]52;c;" + base64.b64encode(b"ORBITAL_RESULT").decode() + "\x07")
        assert not select.select([parent_in], [], [], 0)[0], "copy reached the runtime"
        type_text("/providers\r")
        assert action() == {"type": "provider_settings", "action": "list"}
        send({"type": "provider_settings", "revision": "r1", "model_strategy": "auto",
              "providers": [{"profile": "echo", "provider": "echo", "model": "echo"}], "kinds": []})
        time.sleep(0.15)
        type_text("u")
        wait_screen("SAVE & USE MODEL")
        type_text("\x15new-model\x13")
        packet = action()
        assert packet["action"] == "select" and packet["model"] == "new-model"
        assert packet["strategy"] == "manual" and packet["revision"] == "r1"
        assert packet["team_mode"] == "solo"
        send({"type": "settings_applied", "profile": "echo", "model": "new-model", "model_strategy": "manual"})
        time.sleep(0.15)
        type_text("\x1b")
        type_text("\x11")
        assert action() == {"type": "exit"}
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.01)[0]:
                screen.extend(os.read(master, 65536))
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                pid = None
                assert os.waitstatus_to_exitcode(status) == 0, "frontend failed or terminal modes not restored"
                print(f"PASS: first frame {first_paint:.1f} ms before init; submit, stream, steer, approval ACK, paste, @ reference, history, slash completion, clipboard, provider settings, exit, terminal restoration")
                return
            time.sleep(0.05)
        raise AssertionError("frontend did not exit")
    finally:
        if pid:
            os.killpg(pid, signal.SIGKILL)
            os.close(master)
            master = None
            os.waitpid(pid, 0)
        for fd in (master, slave, parent_out, parent_in):
            if fd is not None:
                os.close(fd)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
