import Foundation
import Darwin

/// A QEMU child outlives a Vitrine process that dies without stopping it (crash, `kill -9`, forced
/// logout). Nothing can control it any more, it keeps the disk open, and the VM shows as stopped.
/// Whoever next takes the bundle's lock (start, snapshot, clone, delete, app launch) ends it.
///
/// A record per running QEMU lives in the temporary directory, keyed by the VM's id so that a
/// moved or renamed bundle still finds it. A process is only signalled when everything matches:
/// the pid and its start time, a `qemu-system-*` executable, an argument naming the bundle path it
/// was launched from, and a parent that is launchd (its owner is gone, so it is an orphan).
public enum QEMUOrphan {
    public struct Inspector: Sendable {
        public struct Facts: Equatable, Sendable {
            public var startTime: UInt64
            public var parent: pid_t
            public var executable: String
            public var arguments: [String]
            public init(startTime: UInt64, parent: pid_t, executable: String, arguments: [String]) {
                self.startTime = startTime; self.parent = parent; self.executable = executable; self.arguments = arguments
            }
        }
        public var facts: @Sendable (pid_t) -> Facts?
        public var signal: @Sendable (pid_t, Int32) -> Void
        public var pollInterval: TimeInterval = 0.1

        public init(facts: @escaping @Sendable (pid_t) -> Facts?, signal: @escaping @Sendable (pid_t, Int32) -> Void) {
            self.facts = facts; self.signal = signal
        }

        public static let system = Inspector(facts: systemFacts, signal: { _ = kill($0, $1) })
    }

    /// What `VMBundle.acquireRunLock` inspects and signals with (tests substitute a fake).
    nonisolated(unsafe) static var lockInspector: Inspector = .system

    struct Record: Equatable {
        var pid: pid_t
        var startTime: UInt64
        /// Bundle path QEMU was started from (nil in records from older versions).
        var launchPath: String?
    }

    /// Where a running QEMU of the VM with `id` is recorded.
    public static func recordURL(for id: UUID) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vitrine-qemu-\(id.uuidString).pid")
    }

    /// In the socket directory, keyed by the bundle path (older versions wrote only this one, as
    /// "<pid> <start time>").
    static func legacyRecordURL(for bundle: VMBundle) -> URL {
        bundle.socketDirectory.appendingPathComponent("qemu.pid")
    }

    /// Records a just-started QEMU: by id, and by bundle path too (where older versions kept it),
    /// which still finds it for a config without a saved id (that decodes a new id on every load).
    public static func record(pid: pid_t, bundle: VMBundle, id: UUID, inspector: Inspector = .system) {
        guard let start = inspector.facts(pid)?.startTime else { return }
        let text = "\(pid) \(start)\n\(bundle.url.path)\n"
        for url in [recordURL(for: id), legacyRecordURL(for: bundle)] {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Removes the records of the QEMU with `pid` once it has exited (not a newer run's records).
    public static func removeRecord(id: UUID, bundle: VMBundle, pid: pid_t) {
        for url in [recordURL(for: id), legacyRecordURL(for: bundle)] {
            if let r = read(url), r.pid == pid { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Whether a record that might name an orphan exists for the bundle (cheap; for app launch).
    public static func hasRecord(for bundle: VMBundle, id: UUID?) -> Bool {
        let fm = FileManager.default
        if let id, fm.fileExists(atPath: recordURL(for: id).path) { return true }
        return fm.fileExists(atPath: legacyRecordURL(for: bundle).path)
    }

    static func parse(_ text: String) -> Record? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count == 2, let pid = pid_t(parts[0]), pid > 1, let start = UInt64(parts[1]) else { return nil }
        let path = lines.count > 1 && !lines[1].isEmpty ? String(lines[1]) : nil
        return Record(pid: pid, startTime: start, launchPath: path)
    }

    static func read(_ url: URL) -> Record? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(parse)
    }

    enum Match { case gone, orphan, notOurs }

    /// What `record` names now: gone (stale record), our orphaned QEMU, or a process to leave alone.
    static func match(_ record: Record, inspector: Inspector) -> Match {
        guard let f = inspector.facts(record.pid), f.startTime == record.startTime else { return .gone }
        guard URL(fileURLWithPath: f.executable).lastPathComponent.hasPrefix("qemu-system-") else { return .gone }
        if let path = record.launchPath {
            // QEMU's own option syntax doubles commas in file names.
            let escaped = path.replacingOccurrences(of: ",", with: ",,")
            guard f.arguments.contains(where: { $0.contains(path + "/") || $0.contains(escaped + "/") }) else { return .notOurs }
        }
        // A live owner (this VM run elsewhere, e.g. a Finder copy with the same id) is its parent.
        return f.parent == 1 ? .orphan : .notOurs
    }

    /// Ends an orphaned QEMU of `bundle`, if any. Call only while holding the bundle's lock (no
    /// live Vitrine process then owns the VM). Returns a line for the VM log when one was ended.
    @discardableResult
    public static func reap(bundle: VMBundle, id: UUID?, inspector: Inspector = .system) -> String? {
        var notes: [String] = []
        let files = (id.map { [recordURL(for: $0)] } ?? []) + [legacyRecordURL(for: bundle)]
        for file in files {
            guard let record = read(file) else {
                try? FileManager.default.removeItem(at: file) // unreadable or absent
                continue
            }
            switch match(record, inspector: inspector) {
            case .gone: try? FileManager.default.removeItem(at: file)
            case .notOurs: continue // someone else's record: leave it
            case .orphan:
                notes.append(terminate(record, inspector: inspector))
                try? FileManager.default.removeItem(at: file)
            }
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    private static func terminate(_ record: Record, inspector: Inspector) -> String {
        func alive() -> Bool { match(record, inspector: inspector) == .orphan }
        func wait(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while alive(), Date() < deadline { Thread.sleep(forTimeInterval: inspector.pollInterval) }
        }
        inspector.signal(record.pid, SIGTERM) // swtpm runs with --terminate and follows QEMU
        wait(5)
        var how = "terminated"
        if alive() {
            inspector.signal(record.pid, SIGKILL)
            how = "killed"
            wait(2)
        }
        return "\(how) QEMU (pid \(record.pid)) left running by an earlier Vitrine process"
    }

    // MARK: Process facts

    @Sendable static func systemFacts(_ pid: pid_t) -> Inspector.Facts? {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return .init(startTime: info.pbi_start_tvsec, parent: pid_t(info.pbi_ppid),
                     executable: String(cString: buf), arguments: arguments(of: pid) ?? [])
    }

    /// argv of `pid` (KERN_PROCARGS2: argc, the executable path, padding, then the arguments).
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, data[i] != 0 { i += 1 } // executable path
        while i < size, data[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, data[i] != 0 { i += 1 }
            args.append(String(decoding: data[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
