#!/usr/bin/env python3
"""Forwards Claude Code session-state transitions to SuperVisor's SwarmVisor module.

SuperVisor installs this file into ~/.claude/hooks/ and wires it into ~/.claude/settings.json
(Settings > SwarmVisor > Install session hooks). `HOOK_VERSION` is what the app compares against
the copy it ships to decide whether an installed script is out of date.

Only six low-frequency events are wired. Per-tool events are deliberately absent: the session
registry is the authoritative source for busy/idle/waiting state, so a hook firing on every
tool call would spawn a process per tool to report what the registry already carries. No hook
here blocks — each connects, writes one JSON object, and exits.

Fields carrying model-generated text (`message`, `last_assistant_message`, `error_details`) are
truncated here rather than in the app, so only what SuperVisor can display ever crosses the
process boundary.
"""

import json
import os
import socket
import subprocess
import sys

HOOK_VERSION = 1

SOCKET_PATH = os.path.expanduser(
    "~/Library/Application Support/SuperVisor/agent-hooks.sock"
)

# The app caps display well below this; the margin leaves room for a sentence that would
# otherwise be cut mid-word before SuperVisor ever gets to choose where to break it.
MAX_TEXT_CHARS = 400

CONNECT_TIMEOUT_SECONDS = 2


def truncate(value):
    """Bounded single-line text, or None when the field is absent or blank."""
    if not isinstance(value, str):
        return None
    collapsed = " ".join(value.split())
    if not collapsed:
        return None
    return collapsed[:MAX_TEXT_CHARS]


def get_tty():
    """The controlling terminal of the Claude Code process that invoked this hook.

    SuperVisor teleports to a session's terminal tab by tty, and hooks are the only source
    for it — the session registry does not record one. The hook runs as a child of the CLI,
    so the parent's tty is the session's.
    """
    try:
        result = subprocess.run(
            ["ps", "-p", str(os.getppid()), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty not in ("??", "-"):
            return tty if tty.startswith("/dev/") else "/dev/" + tty
    except Exception:
        pass

    for stream in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(stream.fileno())
        except (OSError, AttributeError, ValueError):
            continue
    return None


def send(state):
    """Fire-and-forget delivery. A missing app is the normal case, not an error."""
    sock = None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
    except (OSError, ValueError):
        pass
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


def build_state(data):
    event = data.get("hook_event_name", "")

    state = {
        "session_id": data.get("session_id", ""),
        "cwd": data.get("cwd", ""),
        "event": event,
        "pid": os.getppid(),
        "tty": get_tty(),
        "hook_version": HOOK_VERSION,
    }

    if event == "UserPromptSubmit":
        state["status"] = "processing"

    elif event == "Notification":
        notification_type = data.get("notification_type")
        state["status"] = (
            "waiting_for_input" if notification_type == "idle_prompt" else "notification"
        )
        state["notification_type"] = notification_type
        state["message"] = truncate(data.get("message"))

    elif event == "Stop":
        state["status"] = "waiting_for_input"
        state["last_assistant_message"] = truncate(data.get("last_assistant_message"))

    elif event == "StopFailure":
        state["status"] = "error"
        state["error"] = truncate(data.get("error"))
        state["error_details"] = truncate(data.get("error_details"))
        state["last_assistant_message"] = truncate(data.get("last_assistant_message"))

    elif event == "SessionStart":
        # Carries no state change worth surfacing; it registers the tty for the session's
        # whole life, which every later Jump depends on.
        state["status"] = "session_start"

    elif event == "SessionEnd":
        state["status"] = "ended"

    else:
        state["status"] = "unknown"

    return state


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)
    if not isinstance(data, dict):
        sys.exit(0)

    send(build_state(data))
    sys.exit(0)


if __name__ == "__main__":
    main()
