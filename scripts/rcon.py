#!/usr/bin/env python3
"""Minimal Minecraft RCON client (stdlib only).

Used by backup-world.sh and the systemd unit to ask the server to flush/save or
stop. RCON is firewalled (ufw only allows 25565/tcp) and the password lives in a
0600 file, so this stays local-only.

Password resolution order:
  1. $RCON_PASSWORD
  2. /opt/minecraft/rcon.password  (one line, 0600, owned by the service user)

Usage:
  ./rcon.py "save-all flush"
  ./rcon.py --host 127.0.0.1 --port 25575 "stop"
Exit codes: 0 ok, 2 connection/auth failure (callers treat as "server down").
"""
import argparse
import os
import socket
import struct
import sys

AUTH = 3
COMMAND = 2
RESPONSE = 0


def _pack(req_id: int, kind: int, body: str) -> bytes:
    payload = struct.pack("<ii", req_id, kind) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed by server")
        buf += chunk
    return buf


def _read_packet(sock: socket.socket):
    (length,) = struct.unpack("<i", _recv_exact(sock, 4))
    if length < 10 or length > 1 << 20:
        raise ConnectionError(f"implausible packet length {length}")
    data = _recv_exact(sock, length)
    req_id, kind = struct.unpack("<ii", data[:8])
    return req_id, kind, data[8:-2].decode("utf-8", "replace")


def run(command: str, host: str, port: int, password: str, timeout: float) -> str:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(_pack(1, AUTH, password))
        req_id, _, _ = _read_packet(sock)
        if req_id == -1:
            raise PermissionError("RCON authentication failed (wrong password)")
        sock.sendall(_pack(2, COMMAND, command))
        _, _, body = _read_packet(sock)
        return body


def main() -> int:
    ap = argparse.ArgumentParser(description="Send one command to a Minecraft server over RCON")
    ap.add_argument("command", help="command to run, e.g. 'save-all flush'")
    ap.add_argument("--host", default=os.environ.get("RCON_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("RCON_PORT", "25575")))
    ap.add_argument("--timeout", type=float, default=10.0)
    args = ap.parse_args()

    password = os.environ.get("RCON_PASSWORD", "")
    if not password:
        path = os.environ.get("RCON_PASSWORD_FILE", "/opt/minecraft/rcon.password")
        try:
            with open(path, "r", encoding="utf-8") as fh:
                password = fh.readline().strip()
        except OSError:
            pass
    if not password:
        print("rcon.py: no password (set $RCON_PASSWORD or create rcon.password)", file=sys.stderr)
        return 2

    try:
        out = run(args.command, args.host, args.port, password, args.timeout)
    except (OSError, PermissionError, ConnectionError) as exc:
        print(f"rcon.py: {exc}", file=sys.stderr)
        return 2
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
