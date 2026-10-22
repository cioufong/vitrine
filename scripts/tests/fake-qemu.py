#!/usr/bin/env python3
"""Fault-injection QMP/RFB peer. Does not emulate or boot a VM."""
import json
import os
from pathlib import Path
import socket
import struct
import sys
import threading
import time

lock = threading.Lock()
state = "running"
migration = "none"
failed_once = False
log = Path(os.environ["VITRINE_FAKE_QEMU_LOG"])
mode = os.environ.get("VITRINE_FAKE_QEMU_FAILURE", "disconnect")


def record(command):
    with log.open("a") as f:
        f.write(command + "\n")


def qmp(client):
    global state, migration, failed_once
    f = client.makefile("rwb", buffering=0)
    if mode == "unrecoverable" and failed_once:
        client.shutdown(socket.SHUT_RDWR)
        client.close()
        return
    f.write(b'{"QMP":{"version":{}}}\n')
    for line in f:
        request = json.loads(line)
        command = request["execute"]
        arguments = request.get("arguments", {})
        record(command)
        reply = {}
        with lock:
            if command == "stop":
                state = "paused"
            elif command == "cont":
                state = "running"
            elif command == "migrate":
                migration = "completed" if mode in ("complete", "publish") else "active"
                partial = Path(arguments["uri"][5:])
                partial.write_bytes(b"COMPLETED-SAVE" if migration == "completed" else b"INCOMPLETE-SAVE")
                if migration == "completed":
                    state = "postmigrate"
                if mode == "publish":
                    partial.with_suffix("").mkdir()
            elif command == "query-migrate":
                if migration == "active" and not failed_once:
                    failed_once = True
                    record("injected-disconnect")
                    client.shutdown(socket.SHUT_RDWR)
                    client.close()
                    return
                reply = {"status": migration}
            elif command == "migrate_cancel":
                migration = "cancelled"
            elif command == "query-status":
                reply = {"status": state}
            elif command == "qom-list":
                reply = []
            elif command == "quit":
                os._exit(0)
        try:
            f.write(json.dumps({"return": reply}).encode() + b"\n")
        except (BrokenPipeError, ConnectionError):
            return


def receive(client, n):
    out = b""
    while len(out) < n:
        part = client.recv(n - len(out))
        if not part:
            raise EOFError()
        out += part
    return out


def rfb(client):
    client.sendall(b"RFB 003.008\n")
    receive(client, 12)
    client.sendall(b"\x01\x01")
    receive(client, 1)
    client.sendall(b"\0\0\0\0")
    receive(client, 1)
    client.sendall(struct.pack(">HH", 640, 480) + bytes(16) + struct.pack(">I", 4) + b"fake")
    while client.recv(4096):
        pass


def listen(path, handler):
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen()
    def accept():
        while True:
            client, _ = server.accept()
            threading.Thread(target=handler, args=(client,), daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()


for i, argument in enumerate(sys.argv):
    if argument == "-qmp":
        listen(sys.argv[i + 1].removeprefix("unix:").split(",")[0], qmp)
    elif argument == "-vnc":
        listen(sys.argv[i + 1].removeprefix("unix:"), rfb)
record("ready")
while True:
    time.sleep(1)
