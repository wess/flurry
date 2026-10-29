"""Measure native status and upload RSS with disposable, offline fixtures."""
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "cli/target/release/fsc"
ENVIRONMENT = {key: value for key, value in os.environ.items() if key not in ("FLURRY_URL", "FLURRY_TOKEN")}


def measure(root, command, label):
    started = time.perf_counter()
    result = subprocess.run(["/usr/bin/time", "-l", str(BINARY), "--json", *command], cwd=root, env=ENVIRONMENT, capture_output=True, text=True, check=True)
    return {"command": label, "seconds": round(time.perf_counter() - started, 3), "maxrss_bytes": int(re.search(r"(\d+)\s+maximum resident set size", result.stderr).group(1))}


def fixture(root, count, size):
    objects = root / ".flurry/objects"
    objects.mkdir(parents=True, mode=0o700)
    chunk = b"x" * min(size, 1024 * 1024)
    digest = hashlib.sha256(b"blob\0")
    first = root / "file0"
    with first.open("wb") as output:
        remaining = size
        while remaining:
            data = chunk[:min(remaining, len(chunk))]
            output.write(data)
            digest.update(data)
            remaining -= len(data)
    os.link(first, objects / digest.hexdigest())
    for index in range(1, count):
        (root / f"file{index}").write_bytes(chunk)
    revision = "1" * 64
    state = {"version": 1, "server": "http://127.0.0.1:9", "repository": str(uuid.uuid4()), "current": "main", "prefix": "", "branches": {"main": {"head": revision, "upstream": revision, "review": None}}, "remotes": {}, "tags": {}, "commits": {revision: {"parent": None, "merge_parent": None, "message": "Fixture", "files": {f"file{index}": digest.hexdigest() for index in range(count)}}}, "index": {}}
    return state


def save(root, state):
    path = root / ".flurry/state.json"
    path.write_text(json.dumps(state))
    path.chmod(0o600)


def receive(listener, local):
    connection, _ = listener.accept()
    with connection:
        headers = bytearray()
        while not headers.endswith(b"\r\n\r\n"):
            headers.extend(connection.recv(1))
        length = int(next(line.split(b":", 1)[1] for line in headers.lower().split(b"\r\n") if line.startswith(b"content-length:")))
        remaining = length
        while remaining:
            chunk = connection.recv(min(remaining, 65536))
            if not chunk:
                raise RuntimeError("Truncated upload")
            remaining -= len(chunk)
        body = json.dumps({"head": "2" * 64, "branch": "main", "commits": {local: "2" * 64}, "review_id": str(uuid.uuid4()), "protected": True}).encode()
        connection.sendall(f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)


def main():
    results = []
    for count, size in [(1, 100 * 1024 * 1024), (10000, 64)]:
        with tempfile.TemporaryDirectory(prefix="fscbench") as directory:
            root = Path(directory)
            state = fixture(root, count, size)
            save(root, state)
            result = measure(root, ["status"], "status")
            result.update(files=count, bytes=count * size)
            results.append(result)
            if count == 1:
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    listener.listen()
                    listener.settimeout(30)
                    local = str(uuid.uuid4())
                    commit = state["commits"].pop("1" * 64)
                    state["commits"][local] = commit
                    state["branches"]["main"].update(head=local, upstream=None)
                    state["server"] = f"http://127.0.0.1:{listener.getsockname()[1]}"
                    save(root, state)
                    worker = threading.Thread(target=receive, args=(listener, local), daemon=True)
                    worker.start()
                    result = measure(root, ["push"], "push to loopback streaming fixture")
                    worker.join(timeout=30)
                    if worker.is_alive():
                        raise RuntimeError("Upload fixture did not finish")
                    result.update(files=count, bytes=count * size)
                    results.append(result)
    report = {"platform": os.uname().sysname + " " + os.uname().machine, "binary_bytes": BINARY.stat().st_size, "binary_sha256": hashlib.sha256(BINARY.read_bytes()).hexdigest(), "cases": results}
    output = ROOT / "artifacts/cli/performance.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
