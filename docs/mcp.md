# Driving VMs from an AI agent (MCP)

`vitrinectl mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server on stdio. An
agent that speaks MCP can then create VMs with unattended Debian, Windows 11 or macOS installs, start
and stop them, look at their screens, type and click, run commands over SSH and take snapshots: for
example, to test an app in a clean Windows or Linux guest, reproduce a bug in an older macOS, or walk
through an installer.

## Setup

Build the CLI (`./scripts/build-cli.sh` → `.build/release/vitrinectl`, signed with the
virtualization entitlement) and register it with your client, using the absolute path.

Claude Code:

```bash
claude mcp add vitrine -- /path/to/vitrinectl mcp
```

Clients configured with JSON (Claude Desktop's `claude_desktop_config.json`, Cursor, and others):

```json
{
  "mcpServers": {
    "vitrine": { "command": "/path/to/vitrinectl", "args": ["mcp"] }
  }
}
```

Set `"env": { "VITRINE_HOME": "…" }` to point the server at a different VM library.

## Tools

| Tool | What it does |
|---|---|
| `create_vm` | Creates a VM and installs its OS unattended in the background: `os` = `debian-13` (`desktop: false` for headless), `windows-11` (`arch`: `arm64` or `x64`; `image` = installer ISO, default the newest cached one) or `macos` (`image` = IPSW path or `latest`; macOS 27 host). Optional `cpus`, `memory`, `disk`, `username` (default `vitrine`); `start` (default true) boots it as soon as it is created |
| `create_status` | Progress of a `create_vm` job: `creating`, `failed` (with the error), `created` or `running`, the last lines of its log, and once the VM exists its IP and whether the agent is installed |
| `clone_vm` | Instant APFS copy of a shut-down VM with its own MAC address; the guest account carries over |
| `list_vms`, `vm_info` | VMs with state, OS, backend and size; one VM's IP address and configuration |
| `start_vm` | Starts or resumes a VM in the background (`gui: true` opens a window). The VM keeps running after the server exits |
| `stop_vm` | ACPI shutdown, or `force: true` to power off |
| `suspend_vm` | Saves memory to disk; `start_vm` resumes |
| `screenshot` | The guest screen as a PNG, scaled to `max_width` (default 1280) |
| `click` | Mouse move and click at pixel coordinates of the last screenshot (`button`: left, right, none; `double`) |
| `type_text` | Text into whatever has focus: on the VM's US keyboard, or through the guest agent for characters a US keyboard lacks (`method`: `auto`, `keyboard`, `agent`; see [How input works](#how-input-works)) |
| `press_keys` | Key combinations such as `ctrl+alt+delete`, `cmd+space`, `alt+tab`, `f5` |
| `exec`, `push_file`, `pull_file` | Commands and file copies over the guest's SSH server |
| `serial_console` | Send to and read from a Linux guest's serial console, waiting for a regular expression |
| `list_snapshots`, `create_snapshot`, `restore_snapshot`, `delete_snapshot` | Snapshots (restoring needs the VM shut down) |

There is no tool that deletes a VM. Tools that change or lose state (`stop_vm`, `exec`, file copies,
`serial_console`, `restore_snapshot`, `delete_snapshot`) are marked destructive so clients can ask before running them.
So are `click`, `type_text` and `press_keys`: keyboard and mouse input can do anything a user at the
guest could, such as confirm a dialog or run a command in an open terminal. The server itself asks
for no confirmation; these annotations are hints for the client.

## Creating VMs

`create_vm` returns at once. It starts a detached `vitrinectl create-linux`, `create-windows` or
`create` process (and, with `start`, `vitrinectl run` once that succeeds), so the install carries on
if the agent or its MCP server exits. Its output goes to `.creating/<name>.log` in the VM library,
which is what `create_status` reads.

The guest account's password is random (20 letters and digits), handed to the creating process on
stdin (`--password-stdin`, so it never shows in `ps`) and kept in the VM bundle's
`guest-account.secret`, like a VM made in the app; no tool returns it. Names and usernames are
limited to letters, digits, `.`, `-` and `_`, since they end up in file names, cloud-init and
`autounattend.xml`.

After `create_status` says `running`, the guest is still finishing setup: Debian installs its
packages (and Xfce) on first boot, Windows runs Setup and restarts by itself, macOS creates the
account. `exec` works once the guest's SSH server is up, and `agentInstalled` turns true when
Vitrine's agent is in. A failed job can leave a partial VM behind; delete it with
`vitrinectl delete <name>` before trying the same name again (the MCP server has no delete tool).

## How input works

Screenshots, typing and clicks act as the VM's own display, USB keyboard and pointer, so they work
before any guest software is running: at boot menus, installers, login screens, and in macOS guests
that never granted the Vitrine agent Accessibility access.

- QEMU guests (Windows, x86_64 emulation, QEMU Linux) are driven through QEMU's QMP socket.
- Virtualization.framework guests (macOS, Linux) are driven through the process running the VM
  (Vitrine.app or `vitrinectl run`). When the VM has no window, an invisible view presents its
  display while the agent works with it; the VM is not resized.
- The same paths serve `vitrinectl screenshot`, `vitrinectl keys` and `vitrinectl click`.

`type_text` has two ways to type:

- **keyboard**: key presses on the VM's keyboard as a US layout would produce the text. Works
  everywhere above, including before any guest software runs, but only for characters a US keyboard
  has, and only comes out right when the guest uses a US input layout.
- **agent**: Vitrine's guest agent inserts the text itself (`KEYEVENTF_UNICODE` on Windows, XTEST
  with temporary keysyms on Linux/X11, Unicode key events on macOS), so accents, CJK, emoji and
  any other characters arrive as typed, whatever the guest's layout. It needs the agent connected in
  a logged-in desktop session. Newline and tab are sent as the Return and Tab keys.

  A macOS agent may only inject input once someone allows it under *Privacy & Security ▸
  Accessibility* in the guest, which no software can do for them. Until then the text is pasted
  instead: the agent puts each line on the guest clipboard and the VM's keyboard presses ⌘V (neither
  needs a permission), with Return and Tab pressed between lines. That takes about a second per line,
  so one call pastes at most 20 lines, and fields that refuse pasting (some password fields) stay
  empty. With clipboard sharing on, the guest clipboard gets the Mac's content back afterwards; the
  pasted text never reaches the Mac's clipboard.

`method: "auto"` (the default) uses the keyboard when it can type every character and the agent
otherwise; if neither can, the call fails and says why. `vitrinectl keys <vm> --text … --via
auto|keyboard|agent` does the same.

One `type_text` or `press_keys` call (and one `vitrinectl keys`) sends at most 2,000 characters or
key combinations, so it finishes well within the 30 seconds a call waits for its reply; split longer
text into several calls. Input to one VM runs one call at a time: a second call waits for the first
to finish instead of mixing its keys or clicks in.

## Security

The server runs as you and can do what `vitrinectl` can: read and write your files through
`push_file`/`pull_file`, and run anything inside guests that Vitrine has an account for. Only connect
it to agents you would let use your Terminal. It listens on stdio only; nothing is opened on the
network.

## Testing

```bash
python3 scripts/tests/mcp-e2e.py .build/release/vitrinectl <running-linux-desktop-vm>
python3 scripts/tests/mcp-create-e2e.py .build/release/vitrinectl <new-vm-name> [debian-13|windows-11|macos]
python3 scripts/tests/mcp-unicode-e2e.py .build/release/vitrinectl <running-desktop-vm> [linux|windows]
./scripts/tests/automation-qemu-e2e.sh   # screenshots, typing and clicks on a QEMU guest
```
