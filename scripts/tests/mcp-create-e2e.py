#!/usr/bin/env python3
"""End-to-end check of creating a VM through `vitrinectl mcp`.

usage: mcp-create-e2e.py <vitrinectl> <new-vm-name> [debian-13|windows-11|macos] [timeout-minutes] [image]

Speaks MCP over stdio: rejects bad requests inline, then create_vm (headless Debian by default),
polls create_status until the VM runs, waits for exec to answer, checks the password never reached
the process list, then shuts the VM down and exercises clone_vm and create/delete_snapshot on the
clone. The VMs it makes are left in place; delete them with `vitrinectl delete`."""
import json, subprocess, sys, time

exe, vm = sys.argv[1], sys.argv[2]
os_kind = sys.argv[3] if len(sys.argv) > 3 else "debian-13"
timeout = 60 * float(sys.argv[4] if len(sys.argv) > 4 else 30)
image = sys.argv[5] if len(sys.argv) > 5 else None  # installer ISO or IPSW; default: cached/latest
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


def tool(tool_name, expect_error=False, **args):
    r = call("tools/call", {"name": tool_name, "arguments": args})
    text = r["content"][0]["text"]
    if r.get("isError") and not expect_error:
        raise SystemExit(f"FAIL {tool_name}: {text}")
    return r.get("isError", False), text


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp-create-e2e", "version": "1"}})
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
names = {t["name"] for t in call("tools/list")["tools"]}
check({"create_vm", "create_status", "clone_vm", "delete_snapshot"} <= names, "tools/list has the creation tools")

err, text = tool("create_vm", expect_error=True, name="../x", os="debian-13")
check(err, "a path-like VM name is refused")
err, text = tool("create_vm", expect_error=True, name=vm, os="debian-13", username="x; reboot")
check(err, "a shell-unsafe username is refused")
err, text = tool("create_vm", expect_error=True, name=vm, os="debian-13", memory="lots")
check(err, "a bad memory size is refused before anything starts")
_, text = tool("create_status", name=vm)
check(json.loads(text)["state"] == "unknown", "create_status knows no job yet")

start = time.time()
args = {"name": vm, "os": os_kind}
if os_kind == "debian-13":
    args["desktop"] = False
if image:
    args["image"] = image
_, text = tool("create_vm", **args)
print("     " + text)
err, text = tool("create_vm", expect_error=True, **args)
check(err and ("already" in text or "exists" in text), "a second create_vm with the same name is refused")

ps = subprocess.run(["ps", "-axww", "-o", "command="], capture_output=True, text=True).stdout
check("--password " not in ps and "--password-stdin" in ps, "the creating process takes the password on stdin (not in ps)")

state = ""
while time.time() - start < timeout:
    st = json.loads(tool("create_status", name=vm)[1])
    if st["state"] != state:
        state = st["state"]
        print(f"     {int(time.time() - start)}s {state}: {(st['log'] or [''])[-1]}", flush=True)
    if state in ("running", "failed"):
        break
    time.sleep(10)
check(state == "running", f"create_status reaches running ({int(time.time() - start)} s)")

out = ""
probe = "whoami" if os_kind == "windows-11" else "uname -sm; id -un"
while time.time() - start < timeout:
    err, out = tool("exec", expect_error=True, name=vm, command=probe)
    if not err:
        break
    time.sleep(15)
check(not err and "vitrine" in out, f"exec answers as the guest account ({int(time.time() - start)} s): {out.strip()!r}")

_, text = tool("stop_vm", name=vm)
deadline = time.time() + 600  # Windows can take minutes to shut down
while time.time() < deadline:
    vms = json.loads(call("tools/call", {"name": "list_vms", "arguments": {}})["content"][0]["text"])
    if any(v["name"] == vm and v["state"] == "stopped" for v in vms):
        break
    time.sleep(5)
check(any(v["name"] == vm and v["state"] == "stopped" for v in vms), "stop_vm shuts it down")
st = json.loads(tool("create_status", name=vm)[1])
check(st["state"] == "created", "create_status reports created once the VM is off")

clone = vm + "-clone"
_, text = tool("clone_vm", name=vm, new_name=clone)
check("cloned" in text, f"clone_vm makes {clone}")
tool("create_snapshot", name=clone, snapshot="e2e")
snaps = json.loads(tool("list_snapshots", name=clone)[1])
check(any(s["name"] == "e2e" for s in snaps), "create_snapshot on the clone")
tool("delete_snapshot", name=clone, snapshot="e2e")
snaps = json.loads(tool("list_snapshots", name=clone)[1])
check(not any(s["name"] == "e2e" for s in snaps), "delete_snapshot removes it")
print(f"all good; left {vm} and {clone} (vitrinectl delete to remove)")
