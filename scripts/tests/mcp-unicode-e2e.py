#!/usr/bin/env python3
"""End-to-end check of typing non-US text through `vitrinectl mcp`.

usage: mcp-unicode-e2e.py <vitrinectl> <vm> [linux|windows|macos]

The VM must be running, logged in to its desktop with the Vitrine agent connected, and reachable
over SSH (exec). Opens a terminal (Xfce: ctrl+alt+t; Windows: win+r powershell; macOS: Spotlight,
Terminal), has type_text write a line of accented, CJK and emoji text into a file, and reads the
file's bytes back over exec. Also checks that ASCII stays on the keyboard and that method=keyboard refuses the text."""
import base64, json, subprocess, sys, time

exe, vm = sys.argv[1], sys.argv[2]
guest = sys.argv[3] if len(sys.argv) > 3 else "linux"
proc = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
next_id = 0
SAMPLE = "héllo wörld ñ ß 字漢かな 한글 😀👍🏽 €"


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
    r = call("tools/call", {"name": tool_name, "arguments": {"name": vm, **args}})
    text = r["content"][0]["text"]
    if r.get("isError") and not expect_error:
        raise SystemExit(f"FAIL {tool_name}: {text}")
    return r.get("isError", False), text


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mcp-unicode-e2e", "version": "1"}})
proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")

err, text = tool("type_text", expect_error=True, text=SAMPLE, method="keyboard")
check(err and "can't type" in text, f"method=keyboard refuses non-US text ({text})")


def decode(out, encoding):
    try:
        return base64.b64decode(out.strip(), validate=True).decode(encoding)
    except ValueError:
        return f"<not read back: {out.strip()}>"


def wait_for_shell(command, probe):
    """Types `command` (ASCII, on the keyboard) until `probe` over exec shows the shell ran it: a
    terminal opened right after boot can take a while to take focus."""
    for _ in range(12):
        _, text = tool("type_text", text=command)
        check("on the keyboard" in text, f"ASCII stays on the keyboard ({text})")
        time.sleep(5)
        if "ready" in tool("exec", expect_error=True, command=probe)[1]:
            return
    check(False, "the terminal took the keyboard input")

if guest == "windows":
    path = "$env:TEMP\\vitrine-unicode.txt"
    tool("exec", expect_error=True, command=f"powershell -NoProfile -Command \"Remove-Item -ErrorAction SilentlyContinue {path}, $env:TEMP\\vitrine-ready.txt\"")
    tool("press_keys", keys="win+r")
    time.sleep(3)
    tool("type_text", text="powershell\n")
    time.sleep(10)  # the console window has to open and take focus
    wait_for_shell("'ready' | Set-Content $env:TEMP\\vitrine-ready.txt\n",
                   "powershell -NoProfile -Command \"Get-Content (Join-Path $env:TEMP vitrine-ready.txt)\"")
    _, text = tool("type_text", text=f"Set-Content -Encoding utf8 {path} '{SAMPLE}'\n")
    check("through the guest agent" in text or "by pasting" in text, f"auto sends the line through the agent ({text})")
    time.sleep(4)
    _, out = tool("exec", expect_error=True, command="powershell -NoProfile -Command \"[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $env:TEMP vitrine-unicode.txt)))\"")
    got = decode(out, "utf-8-sig").rstrip("\r\n")
    tool("press_keys", keys="alt+f4")
elif guest == "macos":
    path = "/tmp/vitrine-unicode.txt"
    tool("exec", command=f"rm -f {path} /tmp/vitrine-ready.txt")
    tool("press_keys", keys="cmd+space")  # Spotlight: open Terminal
    time.sleep(3)
    tool("type_text", text="Terminal")
    time.sleep(2)
    tool("press_keys", keys="ret")
    time.sleep(6)
    wait_for_shell("echo ready > /tmp/vitrine-ready.txt\n", "cat /tmp/vitrine-ready.txt")
    _, text = tool("type_text", text=f"printf '%s' '{SAMPLE}' > {path}; exit\n")
    check("through the guest agent" in text or "by pasting" in text, f"auto sends the line through the agent ({text})")
    time.sleep(3)
    _, out = tool("exec", expect_error=True, command=f"base64 < {path} | tr -d '\\n'")
    got = decode(out, "utf-8")
else:
    path = "/tmp/vitrine-unicode.txt"
    tool("exec", command=f"rm -f {path} /tmp/vitrine-ready.txt")
    tool("press_keys", keys="ctrl+alt+t")  # Xfce: open a terminal
    time.sleep(4)
    wait_for_shell("echo ready > /tmp/vitrine-ready.txt\n", "cat /tmp/vitrine-ready.txt")
    _, text = tool("type_text", text=f"printf '%s' '{SAMPLE}' > {path}; exit\n")
    check("through the guest agent" in text or "by pasting" in text, f"auto sends the line through the agent ({text})")
    time.sleep(3)
    _, out = tool("exec", expect_error=True, command=f"base64 -w0 {path}")
    got = decode(out, "utf-8")
check(got == SAMPLE, f"the guest file holds exactly the typed text (got {got!r})")

proc.stdin.close()
proc.wait(timeout=10)
print("all Unicode typing checks passed")
