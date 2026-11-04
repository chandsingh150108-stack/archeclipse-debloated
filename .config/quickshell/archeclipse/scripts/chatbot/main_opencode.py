#!/usr/bin/env python3
"""OpenCode backend for the ChatBot panel. Same CLI contract as main.py.

Argv: <provider/model> <message> <session_id>.
Stdin: context JSON envelope (drained and ignored — opencode brings its own
tools and cwd; the panel's workspace/clip/file chips only apply to OpenRouter).
Stdout: reply text, printed as it arrives. History: appended to the same
history.json main.py uses, so rename/delete/revert and the session list keep
working. Exits: 0 ok, 1 generic (message on stderr, "ERROR: ..." prefix).

Env:
    OPENCODE_MODEL  model id for `opencode run --model`; empty = default.
    OPENCODE_DIR    working directory (opencode sessions are per-project).
    OPENCODE_AGENT  agent name; defaults to "plan" (read-only).

Each panel chat session maps to one opencode session id, stored under
~/.cache/quickshell/chatbot/opencode/<chat-session>.sid and continued with
`opencode run --session`. opencode's `--format json` emits one JSON object per
line: {"type": "text", "part": {"text": ...}} carries the reply,
{"type": "error", ...} a failure, everything else is progress.
"""
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "quickshell" / "chatbot"
SID_DIR = CACHE_DIR / "opencode"

# stdin drain budget: QML writes once on started; quiet gap ends the drain.
_STDIN_FIRST_WAIT = 5.0
_STDIN_QUIET_GAP = 0.15
_STDIN_MAX_BYTES = 256 * 1024


def read_stdin_json(stdin=None) -> dict:
    """Drain available stdin bytes without blocking past EOF-less pipes."""
    f = stdin if stdin is not None else sys.stdin
    try:
        fd = f.fileno()
    except Exception:
        return {}
    chunks: list = []
    total = 0
    deadline = time.time() + _STDIN_FIRST_WAIT
    try:
        r, _, _ = select.select([fd], [], [], _STDIN_FIRST_WAIT)
        if not r:
            return {}
        while time.time() < deadline and total < _STDIN_MAX_BYTES:
            r, _, _ = select.select([fd], [], [], _STDIN_QUIET_GAP)
            if not r:
                break
            data = os.read(fd, 65536)
            if not data:
                break
            chunks.append(data)
            total += len(data)
    except (OSError, ValueError):
        return {}
    try:
        raw = b"".join(chunks).decode("utf-8", errors="replace")
        return json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, ValueError):
        return {}


def _check_segment(seg: str, what: str) -> None:
    if not seg or seg in (".", ".."):
        raise ValueError(f"Bad path component ({what}): {seg!r}")


def safe_history_path(model: str, session_id: str) -> Path:
    """Same location main.py uses (model validated, sessions shared)."""
    if not model or model.startswith("/"):
        raise ValueError(f"Bad model path: {model!r}")
    for seg in model.split("/"):
        _check_segment(seg, "model")
    if not session_id or "/" in session_id:
        raise ValueError(f"Bad session id: {session_id!r}")
    _check_segment(session_id, "session")
    return CACHE_DIR / "sessions" / session_id / "history.json"


def _msg(role: str, content: str, rt: int = 0) -> dict:
    return {"id": str(uuid.uuid4()), "role": role, "content": content,
            "timestamp": int(time.time() * 1000), "responseTime": rt}


def save_history_atomic(path: Path, history: list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(history, f, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _fail(msg: str, code: int) -> "int":
    print(msg, file=sys.stderr)
    sys.exit(code)


def find_opencode() -> str:
    found = shutil.which("opencode")
    if found:
        return found
    for candidate in ("/usr/sbin/opencode", "/usr/local/bin/opencode"):
        if os.access(candidate, os.X_OK):
            return candidate
    _fail("ERROR: opencode binary not found in PATH", 1)


def sid_path(chat_session_id: str) -> Path:
    _check_segment(chat_session_id, "session")
    if "/" in chat_session_id:
        raise ValueError(f"Bad session id: {chat_session_id!r}")
    return SID_DIR / (chat_session_id + ".sid")


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    if len(sys.argv) < 4:
        _fail("Usage: main_opencode.py <provider/model> <message> <session_id>", 1)
    _model_arg, user_message, session_id = sys.argv[1], sys.argv[2], sys.argv[3]
    if not user_message.strip():
        _fail("ERROR: empty message", 1)

    # Drain the QML context envelope so the write end never blocks; ignored.
    read_stdin_json()

    try:
        history_path = safe_history_path(_model_arg, session_id)
    except ValueError as e:
        _fail(f"ERROR: {e}", 1)
    try:
        history = json.loads(history_path.read_text(encoding="utf-8")) \
            if history_path.exists() else []
        if not isinstance(history, list):
            history = []
    except (json.JSONDecodeError, OSError):
        history = []
    history.append(_msg("user", user_message))

    workdir = (os.environ.get("OPENCODE_DIR", "").strip()
               or str(Path.home() / "Chandd"))
    workdir = os.path.expanduser(workdir)
    if not os.path.isdir(workdir):
        _fail(f"ERROR: OpenCode directory does not exist: {workdir}", 1)
    agent = os.environ.get("OPENCODE_AGENT", "").strip() or "plan"
    model_override = os.environ.get("OPENCODE_MODEL", "").strip()

    opencode = find_opencode()
    cmd = [opencode, "run", "--format", "json", "--agent", agent]
    if model_override:
        cmd += ["--model", model_override]
    creating = True
    try:
        saved = sid_path(session_id).read_text(encoding="utf-8").strip()
    except (OSError, ValueError):
        saved = ""
    if saved:
        cmd += ["--session", saved]
        creating = False
    else:
        cmd += ["--title", f"panel-{session_id}"]
    cmd.append(user_message)

    state = {"reply": "", "opencode_sid": saved, "start": time.time()}

    def _save_partial():
        if state["reply"]:
            history.append(_msg("assistant", state["reply"],
                                int((time.time() - state["start"]) * 1000)))
            try:
                save_history_atomic(history_path, history)
            except OSError:
                pass

    child = {"proc": None}

    def _on_stop(signum, frame):
        try:
            p = child["proc"]
            if p is not None and p.poll() is None:
                p.terminate()
        finally:
            try:
                _save_partial()
            finally:
                sys.stdout.flush()
                os._exit(0)

    try:
        signal.signal(signal.SIGINT, _on_stop)
        signal.signal(signal.SIGTERM, _on_stop)
    except Exception:
        pass

    try:
        proc = subprocess.Popen(cmd, cwd=workdir, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True,
                                encoding="utf-8", errors="replace", bufsize=1)
    except OSError as e:
        _fail(f"ERROR: could not start opencode: {e}", 1)
    child["proc"] = proc

    error_msg = None
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        etype = event.get("type")
        if not state["opencode_sid"] and isinstance(event.get("sessionID"), str):
            state["opencode_sid"] = event["sessionID"]
        if etype == "text":
            chunk = event.get("part", {}).get("text", "")
            if isinstance(chunk, str) and chunk:
                state["reply"] += chunk
                print(chunk, end="", flush=True)
        elif etype == "error":
            err = event.get("error", {})
            if isinstance(err, dict):
                error_msg = err.get("message") or json.dumps(err)
            else:
                error_msg = str(err)
            break
    stderr_tail = ""
    try:
        _, stderr_tail = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        _, stderr_tail = proc.communicate()
    rc = proc.returncode

    if state["opencode_sid"] and creating:
        try:
            p = sid_path(session_id)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(state["opencode_sid"] + "\n", encoding="utf-8")
        except OSError:
            pass

    if error_msg:
        _save_partial()
        _fail(f"ERROR: {error_msg}", 1)
    if rc not in (0, None):
        _save_partial()
        tail = (stderr_tail or "").strip().splitlines()
        detail = tail[-1] if tail else f"exit code {rc}"
        _fail(f"ERROR: opencode failed: {detail}", 1)
    if not state["reply"]:
        _fail("ERROR: Empty response from OpenCode", 1)
    history.append(_msg("assistant", state["reply"],
                        int((time.time() - state["start"]) * 1000)))
    try:
        save_history_atomic(history_path, history)
    except OSError as e:
        _fail(f"ERROR: could not save history: {e}", 1)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
