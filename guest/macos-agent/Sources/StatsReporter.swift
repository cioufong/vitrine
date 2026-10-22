import Darwin
import Foundation
import VitrineAgentProtocol

/// CPU, memory and disk use for the host's status bar. CPU is measured between two calls.
final class StatsReporter {
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func snapshot() -> GuestStats {
        var s = GuestStats()
        s.cpuPercent = cpuPercent()
        s.memoryTotal = ProcessInfo.processInfo.physicalMemory
        s.memoryUsed = memoryUsed().map { min($0, ProcessInfo.processInfo.physicalMemory) }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let total = (attrs[.systemSize] as? NSNumber)?.uint64Value,
           let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value {
            s.diskTotal = total
            s.diskUsed = total - min(free, total)
        }
        s.uptimeSeconds = UInt64(ProcessInfo.processInfo.systemUptime)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        s.osName = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        return s
    }

    private func cpuPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        let now = (busy: user + system + nice, total: user + system + idle + nice)
        defer { lastTicks = now }
        guard let last = lastTicks, now.total > last.total else { return nil }
        return min(100, Double(now.busy - last.busy) / Double(now.total - last.total) * 100)
    }

    /// Activity Monitor's "Memory Used": app memory (anonymous pages that can't be purged) plus
    /// wired and compressed.
    private func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }
}
