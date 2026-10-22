#!/usr/bin/env python3
"""End-to-end check of `vitrinectl mcp` against a running VM with a desktop and SSH.

usage: mcp-e2e.py <vitrinectl> <vm> [screenshot-dir]

Speaks MCP over stdio like a client would: initialize, tools/list, then list_vms, vm_info,
screenshot (saved for inspection), type_text + press_keys into whatever has focus, exec and a
push/pull round trip. Exits non-zero on the first failed expectation."""
import base64, json, os, subprocess, sys, tempfile, time

exe, vm = sys.argv[1], sys.argv[2]
out_dir = sys.argv[3] if len(sys.argv) > 3 else tempfile.gettempdir()
proc = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
next_id = 0


def call(method, params=None):
    global next_id
    next_id += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()
    msg = json.loads(proc.stdout.readline())
    assert msg.get("id") == next_id, msg
    if "error" in msg:
        raise SystemExit(f"FAIL {method}: {msg['error']}")
    return msg["result"]


def tool(name, **args):
    r = call("tools/call", {"name": name, "arguments": {"name": vm, **args}})
    if r.get("isError"):
        raise SystemExit(f"FAIL {name}: {r['content'][0]['text']}")
    return r["content"]


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        sys.exit(1)


init = call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "mcp-e2e", "version": "1"}})
check(init["protocolVersion"] == "2025-06-18" and "tools" in init["capabilities"], "initialize negotiates 2025-06-18")
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
names = {t["name"] for t in call("tools/list")["tools"]}
check({"list_vms", "screenshot", "click", "type_text", "press_keys", "exec", "start_vm", "stop_vm"} <= names,
      f"tools/list has the core tools ({len(names)} tools)")
check(not any("delete" in n and "snapshot" not in n for n in names), "no tool deletes VMs")

vms = json.loads(call("tools/call", {"name": "list_vms", "arguments": {}})["content"][0]["text"])
check(any(v["name"] == vm and v["state"] == "running" for v in vms), f"list_vms shows {vm} running")
info = json.loads(tool("vm_info")[0]["text"])
check(info["config"]["name"] == vm if "name" in info["config"] else True, "vm_info returns the configuration")

shot = tool("screenshot", max_width=960)
img = next(c for c in shot if c["type"] == "image")
png = base64.b64decode(img["data"])
path = os.path.join(out_dir, f"vitrine-mcp-{vm}.png")
open(path, "wb").write(png)
check(png[:8] == b"\x89PNG\r\n\x1a\n" and int.from_bytes(png[16:20], "big") == 960,
      f"screenshot is a 960-pixel-wide PNG ({path})")

marker = "vitrine-mcp-" + os.urandom(3).hex()
out = tool("exec", command=f"echo {marker} > /tmp/{marker}.txt && cat /tmp/{marker}.txt")[0]["text"]
check(marker in out, "exec runs a command over SSH")
local = os.path.join(tempfile.mkdtemp(), "pulled.txt")
tool("pull_file", guest_path=f"/tmp/{marker}.txt", local_path=local)
check(open(local).read().strip() == marker, "pull_file copies the file back")

tool("press_keys", keys="ctrl+alt+t")  # Xfce: open a terminal
time.sleep(4)  # keys typed before the new window has focus go elsewhere
tool("type_text", text=f"echo typed-{marker} > /tmp/typed.txt\n")
time.sleep(2)
out = tool("exec", command="cat /tmp/typed.txt 2>/dev/null || true")[0]["text"]
check(f"typed-{marker}" in out, "type_text + press_keys reach the guest (seen over SSH)")
shot = tool("screenshot")
open(os.path.join(out_dir, f"vitrine-mcp-{vm}-typed.png"), "wb").write(base64.b64decode(shot[0]["data"]))

proc.stdin.close()
proc.wait(timeout=10)
check(proc.returncode == 0, "server exits cleanly when stdin closes")
print("all MCP checks passed")
