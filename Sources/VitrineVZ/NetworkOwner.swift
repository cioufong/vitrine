import Foundation
import vmnet
import VitrineCore

/// The owner side of `VmnetNetworks`: one `vitrinectl netd <key>` process per network in use.
///
/// Files in `VmnetNetworks.directory`, per network (`<id>` is the key in hex, plus the library for
/// named networks):
/// - `<id>.json`: the owner's PID, the subnet and the network's serialization;
/// - `<id>.users/<pid>`: one per process using the network;
/// - `<id>.lock`: serializes joining against the owner deciding to exit;
/// - `<id>.error`: why the last owner could not create the network.
enum NetworkOwner {
    struct Record: Codable {
        var pid: pid_t
        var key: String
        var subnet: String?
        /// The xpc dictionary from `vmnet_network_copy_serialization`, flattened to JSON.
        var serialization: [String: [String]]
    }

    /// Named networks are defined per library: two libraries (VITRINE_HOME) with a network of the
    /// same name get separate owners. netd inherits the environment, so it resolves the same library.
    private static func id(_ key: String) -> String {
        let hex = key.utf8.map { String(format: "%02x", $0) }.joined()
        guard key.hasPrefix("net:") else { return hex }
        return hex + "-" + GuestAppProxy.stableHash(VMLibrary.root.resolvingSymlinksInPath().standardizedFileURL.path)
    }
    private static func url(_ key: String, _ suffix: String) -> URL {
        VmnetNetworks.directory.appendingPathComponent(id(key) + suffix)
    }

    // MARK: Client

    /// Joins the network for `key`, starting its owner if needed, and registers this process as a user.
    @available(macOS 26, *)
    static func join(key: String) throws -> vmnet_network_ref {
        try FileManager.default.createDirectory(at: VmnetNetworks.directory, withIntermediateDirectories: true)
        let users = url(key, ".users")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        return try withLock(key) {
            var record = liveRecord(key: key)
            if record == nil {
                try? FileManager.default.removeItem(at: url(key, ".error"))
                try spawnOwner(key: key)
                let deadline = Date().addingTimeInterval(15)
                while record == nil, Date() < deadline {
                    if let error = try? String(contentsOf: url(key, ".error"), encoding: .utf8) {
                        throw VitrineError.backend(error.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    usleep(50_000)
                    record = liveRecord(key: key)
                }
            }
            guard let record else { throw VitrineError.backend("the network service for \(display(key)) did not start") }
            guard let serialization = decode(record.serialization) else {
                throw VitrineError.backend("could not read the network service's description of \(display(key))")
            }
            var status = vmnet_return_t.VMNET_SUCCESS
            guard let network = vmnet_network_create_with_serialization(serialization, &status) else {
                throw VitrineError.backend("could not join \(display(key)) (vmnet status \(status.rawValue))")
            }
            FileManager.default.createFile(atPath: users.appendingPathComponent("\(getpid())").path, contents: nil)
            return network
        }
    }

    static func unregister(key: String) {
        try? FileManager.default.removeItem(at: url(key, ".users").appendingPathComponent("\(getpid())"))
    }

    /// The published record, if its owner is still running.
    static func liveRecord(key: String) -> Record? {
        guard let data = try? Data(contentsOf: url(key, ".json")),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.key == key, isOwner(record.pid) else { return nil }
        return record
    }

    /// Whether `pid` is a running vitrinectl (a stale record's PID may have been reused: joining a
    /// network whose owner has gone hangs).
    private static func isOwner(_ pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buf)).lastPathComponent == "vitrinectl"
    }

    static func display(_ key: String) -> String {
        key == "host-only" ? "the host-only network" : "network “\(key.dropFirst(4))”"
    }

    private static func withLock<T>(_ key: String, _ body: () throws -> T) throws -> T {
        let fd = open(url(key, ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VitrineError.backend("cannot lock \(display(key)): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Starts `vitrinectl netd <key>` in its own session, inheriting no descriptors (it must not
    /// keep VM run locks or sockets open after this process exits).
    private static func spawnOwner(key: String) throws {
        guard let exe = BuildLayout.executable(named: "vitrinectl") else {
            throw VitrineError.backend("vitrinectl is missing; it runs the network service for \(display(key))")
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, url(key, ".log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let args = [exe.path, "netd", key]
        var argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let r = posix_spawn(&pid, exe.path, &actions, &attr, &argv, environ)
        guard r == 0 else { throw VitrineError.backend("could not start the network service: \(String(cString: strerror(r)))") }
        // Its own session doesn't make it someone else's child: reap it, or every idle exit leaves
        // a zombie behind in a long-running app.
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
    }

    // MARK: Owner

    /// `vitrinectl netd <key>`: creates the network, publishes it and serves until unused.
    @available(macOS 26, *)
    public static func serve(key: String) -> Never {
        let fail = { (message: String) -> Never in
            try? message.write(to: url(key, ".error"), atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
        guard let def = VmnetNetworks.definition(forKey: key) else { fail("there is no network named “\(key.dropFirst(4))”") }
        let network: vmnet_network_ref
        do { network = try VmnetNetworks.create(def) } catch { fail(error.localizedDescription) }
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let serialization = vmnet_network_copy_serialization(network, &status), let flat = encode(serialization) else {
            fail("could not share \(display(key)) (vmnet status \(status.rawValue))")
        }
        var host = in_addr(), mask = in_addr()
        vmnet_network_get_ipv4_subnet(network, &host, &mask)
        let m = UInt32(bigEndian: mask.s_addr), h = UInt32(bigEndian: host.s_addr)
        let subnet = m == 0 ? nil : "\(IPv4Subnet.format(h & m))/\(m.nonzeroBitCount)"
        let record = Record(pid: getpid(), key: key, subnet: subnet, serialization: flat)
        do {
            try JSONEncoder().encode(record).write(to: url(key, ".json"), options: .atomic)
        } catch { fail("could not publish \(display(key)): \(error.localizedDescription)") }
        FileHandle.standardError.write(Data("serving \(display(key)) on \(subnet ?? "?")\n".utf8))

        let cleanUp = {
            if (try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url(key, ".json"))))?.pid == getpid() {
                try? FileManager.default.removeItem(at: url(key, ".json"))
            }
        }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { cleanUp(); exit(0) }
            s.resume()
            return s
        }
        var idle = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            idle = activeUsers(key) == 0 ? idle + 2 : 0
            guard idle >= 6 else { return }
            // Decide under the lock so a process joining right now isn't left with a dead network.
            let quit = (try? withLock(key) { () -> Bool in
                guard activeUsers(key) == 0 else { return false }
                cleanUp()
                return true
            }) ?? true
            if quit {
                withExtendedLifetime(network) {}
                exit(0)
            }
            idle = 0
        }
        timer.resume()
        withExtendedLifetime((signals, timer)) { dispatchMain() }
    }

    /// Registered users still running; forgets the ones that have exited.
    private static func activeUsers(_ key: String) -> Int {
        let dir = url(key, ".users")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var alive = 0
        for name in names {
            if let pid = pid_t(name), pid > 0, kill(pid, 0) == 0 || errno == EPERM {
                alive += 1
            } else {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        return alive
    }

    // MARK: Serialization as JSON

    /// [key: [type, value]] for the plain value types a serialization holds.
    static func encode(_ object: xpc_object_t) -> [String: [String]]? {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else { return nil }
        var out: [String: [String]] = [:]
        var ok = true
        xpc_dictionary_apply(object) { key, value in
            let k = String(cString: key)
            let t = xpc_get_type(value)
            if t == XPC_TYPE_DATA, let p = xpc_data_get_bytes_ptr(value) {
                out[k] = ["data", Data(bytes: p, count: xpc_data_get_length(value)).base64EncodedString()]
            } else if t == XPC_TYPE_STRING, let p = xpc_string_get_string_ptr(value) {
                out[k] = ["string", String(cString: p)]
            } else if t == XPC_TYPE_UINT64 {
                out[k] = ["uint64", String(xpc_uint64_get_value(value))]
            } else if t == XPC_TYPE_INT64 {
                out[k] = ["int64", String(xpc_int64_get_value(value))]
            } else if t == XPC_TYPE_BOOL {
                out[k] = ["bool", xpc_bool_get_value(value) ? "1" : "0"]
            } else if t == XPC_TYPE_UUID, let p = xpc_uuid_get_bytes(value) {
                out[k] = ["uuid", Data(bytes: p, count: 16).base64EncodedString()]
            } else {
                ok = false
            }
            return ok
        }
        return ok ? out : nil
    }

    static func decode(_ flat: [String: [String]]) -> xpc_object_t? {
        let dict = xpc_dictionary_create(nil, nil, 0)
        for (k, v) in flat {
            guard v.count == 2 else { return nil }
            switch v[0] {
            case "data":
                guard let d = Data(base64Encoded: v[1]) else { return nil }
                d.withUnsafeBytes { xpc_dictionary_set_data(dict, k, $0.baseAddress!, d.count) }
            case "string": xpc_dictionary_set_string(dict, k, v[1])
            case "uint64":
                guard let n = UInt64(v[1]) else { return nil }
                xpc_dictionary_set_uint64(dict, k, n)
            case "int64":
                guard let n = Int64(v[1]) else { return nil }
                xpc_dictionary_set_int64(dict, k, n)
            case "bool": xpc_dictionary_set_bool(dict, k, v[1] == "1")
            case "uuid":
                guard let d = Data(base64Encoded: v[1]), d.count == 16 else { return nil }
                d.withUnsafeBytes { xpc_dictionary_set_uuid(dict, k, $0.bindMemory(to: UInt8.self).baseAddress!) }
            default: return nil
            }
        }
        return dict
    }
}
