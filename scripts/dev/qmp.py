#!/usr/bin/env python3
"""Dev helper: send QMP commands to a socket and print replies.
Usage: qmp.py <socket> '<json-command>' ['<json-command>' ...]"""
import json, socket, sys, time

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
f = s.makefile("rw")
print(f.readline().strip()[:200])
for cmd in ['{"execute":"qmp_capabilities"}'] + sys.argv[2:]:
    f.write(cmd + "\n"); f.flush()
    while True:
        line = json.loads(f.readline())
        if "event" in line:
            print("event:", line["event"])
            continue
        print(cmd[:60], "->", json.dumps(line)[:400])
        break
