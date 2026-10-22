import AppKit
import VitrineAgentProtocol

// vitrine-agent — runs inside the macOS guest (as a LaunchAgent in the user's session).
//   vitrine-agent                 listen on vsock port AgentProtocol.vsockPort
//   vitrine-agent --unix <path>   listen on a Unix socket (development: mirror the host itself)

var endpoint = Listener.Endpoint.vsock(port: AgentProtocol.vsockPort)
var verbose = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--unix":
        guard let p = it.next() else { fatalError("--unix needs a path") }
        endpoint = .unix(path: p)
    case "--verbose", "-v": verbose = true
    case "--version": print(GuestAgent.version); exit(0)
    default:
        print("usage: vitrine-agent [--unix PATH] [--verbose]")
        exit(2)
    }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let agent = GuestAgent(listener: Listener(endpoint), verbose: verbose)
do { try agent.run() } catch {
    FileHandle.standardError.write(Data("vitrine-agent: \(error)\n".utf8))
    exit(1)
}
app.run()
