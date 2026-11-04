#!/usr/bin/env python3
"""OpenCode model list via `opencode models` with 24h file cache.

CLI: opencode_models.py [cache_path] -> JSON array of model ids on stdout.
On any failure prints the best fallback: stale cache, else [].
"""
import json
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_CACHE = Path.home() / ".cache" / "quickshell" / "chatbot" / "opencode-models.json"
_TTL_HOURS = 24


def load_cached(cache_path: Path) -> tuple:
    """Returns (ids, fresh). Corrupt/missing cache -> ([], False)."""
    try:
        data = json.loads(Path(cache_path).read_text())
        ids = data.get("ids", [])
        if not isinstance(ids, list):
            return ([], False)
        age = time.time() - float(data.get("updatedAt", 0))
        return ([str(i) for i in ids], age < _TTL_HOURS * 3600)
    except (OSError, ValueError, TypeError, AttributeError):
        return ([], False)


def fetch_models(cache_path: Path = DEFAULT_CACHE) -> list:
    ids, fresh = load_cached(cache_path)
    if fresh:
        return ids
    try:
        proc = subprocess.run(["opencode", "models"], capture_output=True,
                              text=True, timeout=30)
        if proc.returncode != 0:
            return ids
        seen = {line.strip() for line in proc.stdout.splitlines()}
        ids = sorted(i for i in seen if i and "/" in i and not i.startswith("/"))
        if not ids:
            return ids
        Path(cache_path).parent.mkdir(parents=True, exist_ok=True)
        tmp = Path(str(cache_path) + ".tmp")
        tmp.write_text(json.dumps({"updatedAt": time.time(), "ids": ids}))
        tmp.replace(cache_path)
        return ids
    except Exception:
        return ids


def main(argv: list) -> int:
    cache = Path(argv[1]) if len(argv) > 1 else DEFAULT_CACHE
    print(json.dumps(fetch_models(cache_path=cache)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
