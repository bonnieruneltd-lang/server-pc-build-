#!/usr/bin/env python3
"""Mock Minecraft RCON server for testing scripts/rcon.py and backup-world.sh.

Speaks the real protocol (little-endian length-prefixed packets, AUTH type 3,
COMMAND type 2) and appends every command it receives to $RCON_LOG so tests can
assert on the save-off/save-all flush/save-on sequence.

Usage: mock_rcon.py --port 0 --password secret --log /tmp/cmds.log
Prints "PORT <n>" on stdout once listening, then serves until stdin closes.
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

AUTH, COMMAND = 3, 2


def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def handle(conn, password, log_path, state):
    with conn:
        try:
            while True:
                (length,) = struct.unpack("<i", read_exact(conn, 4))
                data = read_exact(conn, length)
                req_id, kind = struct.unpack("<ii", data[:8])
                body = data[8:-2].decode("utf-8", "replace")

                if kind == AUTH:
                    ok = body == password
                    resp_id = req_id if ok else -1
                    state["authed"] = ok
                    _send(conn, resp_id, 0, "")
                    continue

                if kind == COMMAND:
                    if not state.get("authed"):
                        _send(conn, -1, 0, "")
                        continue
                    with open(log_path, "a", encoding="utf-8") as fh:
                        fh.write(body + "\n")
                    if body.strip() == "stop":
                        _send(conn, req_id, 0, "Stopping the server")
                        return
                    _send(conn, req_id, 0, f"ok: {body}")
        except (ConnectionError, OSError):
            return


def _send(conn, req_id, kind, body):
    payload = struct.pack("<ii", req_id, kind) + body.encode() + b"\x00\x00"
    conn.sendall(struct.pack("<i", len(payload)) + payload)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--password", default="testpass")
    ap.add_argument("--log", default="/tmp/mock-rcon-commands.log")
    args = ap.parse_args()

    open(args.log, "w").close()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(8)
    port = srv.getsockname()[1]
    print(f"PORT {port}", flush=True)

    def acceptor():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(
                target=handle, args=(conn, args.password, args.log, {}), daemon=True
            ).start()

    threading.Thread(target=acceptor, daemon=True).start()
    # Serve until killed (tests use timeout / explicit kill).
    try:
        while True:
            time.sleep(0.2)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
