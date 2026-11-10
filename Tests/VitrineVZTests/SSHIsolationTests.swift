import XCTest
@testable import VitrineVZ
import VitrineCore

/// Vitrine's ssh and scp must not pick up the user's ~/.ssh/config (agent or X11 forwarding,
/// RemoteForward, ProxyCommand…) and must not let a username or host from a VM's config be read
/// as an option.
final class SSHIsolationTests: XCTestCase {
    let target = AgentInstaller.Target(host: "192.168.64.5", username: "leo", password: "pw")

    private func value(of option: String, in args: [String]) -> String? {
        for (i, a) in args.enumerated() where a == "-o" && i + 1 < args.count {
            let kv = args[i + 1]
            if kv.lowercased().hasPrefix(option.lowercased() + "=") { return String(kv.dropFirst(option.count + 1)) }
        }
        return nil
    }

    func testSSHIgnoresUserConfigAndForwarding() {
        for tool in ["/usr/bin/ssh", "/usr/bin/scp"] {
            let args = AgentInstaller.sshArguments(target, tool: tool, [])
            let f = args.firstIndex(of: "-F")
            XCTAssertNotNil(f, tool)
            if let f { XCTAssertEqual(args[f + 1], "/dev/null", tool) }
            XCTAssertEqual(value(of: "ForwardAgent", in: args), "no", tool)
            XCTAssertEqual(value(of: "ForwardX11", in: args), "no", tool)
            XCTAssertEqual(value(of: "ClearAllForwardings", in: args), "yes", tool)
            XCTAssertEqual(value(of: "IdentityAgent", in: args), "none", tool)
            XCTAssertEqual(value(of: "PermitLocalCommand", in: args), "no", tool)
        }
    }

    func testDestinationFollowsDoubleDash() {
        let run = AgentInstaller.runArguments(target, command: "true")
        XCTAssertEqual(Array(run.suffix(3)), ["--", "192.168.64.5", "true"])
        XCTAssertEqual(run[run.firstIndex(of: "-l")! + 1], "leo")
        let up = AgentInstaller.uploadArguments(target, URL(fileURLWithPath: "/tmp/-x"), to: "dir")
        XCTAssertEqual(Array(up.suffix(3)), ["--", "/tmp/-x", "leo@192.168.64.5:dir"])
        let down = AgentInstaller.downloadArguments(target, "-dir", to: URL(fileURLWithPath: "/tmp/out"))
        XCTAssertEqual(Array(down.suffix(3)), ["--", "leo@192.168.64.5:-dir", "/tmp/out"])
    }

    func testEnvironmentDropsAgentSocket() {
        let env = AgentInstaller.sshEnvironment(askpass: "/tmp/a", password: "pw",
                                                base: ["SSH_AUTH_SOCK": "/tmp/agent", "PATH": "/usr/bin", "HOME": "/Users/x",
                                                       "LC_SECRET": "1", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"])
        XCTAssertNil(env["SSH_AUTH_SOCK"])
        XCTAssertNil(env["LC_SECRET"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["SSH_ASKPASS"], "/tmp/a")
        XCTAssertEqual(env["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(env["VITRINE_SSH_PASSWORD"], "pw")
    }

    func testUnsafeUsernamesAndHostsAreRefused() {
        for bad in ["-oProxyCommand=touch /tmp/pwned;#", "", "a b", "ľeo", "a@b", "a:b", "-l"] {
            XCTAssertFalse(AgentInstaller.Target.isSafeUsername(bad), bad)
        }
        for good in ["leo", "Leo", "leo.yeh", "leo_1", "l-e"] {
            XCTAssertTrue(AgentInstaller.Target.isSafeUsername(good), good)
        }
        XCTAssertFalse(AgentInstaller.Target.isSafeHost("-oProxyCommand=x"))
        XCTAssertFalse(AgentInstaller.Target.isSafeHost("a b"))
        XCTAssertTrue(AgentInstaller.Target.isSafeHost("127.0.0.1"))
        XCTAssertTrue(AgentInstaller.Target.isSafeHost("fe80::1"))
    }

    /// The real ssh parses the final argv as intended: options end before the destination, so a
    /// hostile username can't become a ProxyCommand. (ssh finds ~/.ssh/config through the password
    /// database, not $HOME, so the config isolation itself is covered by the -F check above.)
    func testRealSSHParsesArguments() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let args = AgentInstaller.sshArguments(target, tool: "/usr/bin/ssh", AgentInstaller.runArguments(target, command: "true"))
        p.arguments = ["-G"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, text)
        let lines = Set(text.split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("forwardagent no"), text)
        XCTAssertTrue(lines.contains("user leo"), text)
        XCTAssertTrue(lines.contains("hostname 192.168.64.5"), text)
        XCTAssertFalse(lines.contains { $0.hasPrefix("proxycommand ") }, text)
        XCTAssertFalse(lines.contains { $0.hasPrefix("remoteforward ") }, text)
    }
}
