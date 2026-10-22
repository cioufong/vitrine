import Foundation
import vmnet

/// A vmnet interface: Ethernet frames in and out of a vmnet network (macOS 26 API, unprivileged)
/// or a bridged/shared/host network started the classic way (root only).
public final class VmnetPort: @unchecked Sendable {
    public let maxPacketSize: Int
    private let iface: interface_ref
    private let queue: DispatchQueue
    private var stopped = false
    private let lock = NSLock()
    private static let batch = 32
    private let buffers: UnsafeMutableRawPointer
    private let iovs = UnsafeMutablePointer<iovec>.allocate(capacity: VmnetPort.batch)
    private let descs = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: VmnetPort.batch)

    private init(iface: interface_ref, queue: DispatchQueue, maxPacketSize: Int) {
        self.iface = iface
        self.queue = queue
        self.maxPacketSize = maxPacketSize
        buffers = .allocate(byteCount: maxPacketSize * Self.batch, alignment: 16)
    }

    deinit {
        buffers.deallocate()
        iovs.deallocate()
        descs.deallocate()
    }

    /// An interface on `network`. The guest's own MAC address is used on the wire.
    @available(macOS 26, *)
    public static func start(on network: vmnet_network_ref) throws -> VmnetPort {
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(desc, vmnet_allocate_mac_address_key, false)
        let queue = DispatchQueue(label: "vitrine.vmnet")
        return try wait(queue: queue, what: "join the network") { done in
            vmnet_interface_start_with_network(network, desc, queue, done)
        }
    }

    /// A classic interface (`vmnet_start_interface`): bridged to `interface`, or shared/host when nil.
    /// Needs root (or Apple's restricted com.apple.vm.networking entitlement).
    public static func startClassic(mode: operating_modes_t, bridging interface: String? = nil) throws -> VmnetPort {
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(mode.rawValue))
        xpc_dictionary_set_bool(desc, vmnet_allocate_mac_address_key, false)
        if let interface { xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, interface) }
        xpc_dictionary_set_string(desc, vmnet_interface_id_key, UUID().uuidString)
        let queue = DispatchQueue(label: "vitrine.vmnet")
        return try wait(queue: queue, what: interface.map { "bridge to \($0)" } ?? "start vmnet") { done in
            vmnet_start_interface(desc, queue, done)
        }
    }

    private static func wait(queue: DispatchQueue, what: String,
                             start: (@escaping vmnet_start_interface_completion_handler_t) -> interface_ref?) throws -> VmnetPort {
        let sem = DispatchSemaphore(value: 0)
        var status = vmnet_return_t.VMNET_FAILURE
        var maxPacket = 1514
        let iface = start { st, params in
            status = st
            if let params {
                let n = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
                if n > 0 { maxPacket = n }
            }
            sem.signal()
        }
        guard let iface else { throw VmnetError(what: what, status: .VMNET_FAILURE) }
        guard sem.wait(timeout: .now() + 15) == .success else { throw VmnetError(what: what, status: nil) }
        guard status == .VMNET_SUCCESS else {
            _ = vmnet_stop_interface(iface, queue) { _ in }
            throw VmnetError(what: what, status: status)
        }
        return VmnetPort(iface: iface, queue: queue, maxPacketSize: maxPacket)
    }

    /// Delivers incoming frames on the port's queue until `stop`.
    public func onFrames(_ handler: @escaping (UnsafeRawBufferPointer) -> Void) {
        let size = maxPacketSize, batch = Self.batch
        vmnet_interface_set_event_callback(iface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, _ in
            guard let self, !self.isStopped else { return }
            let (buffers, iovs, descs) = (self.buffers, self.iovs, self.descs)
            while true {
                for i in 0..<batch {
                    iovs[i] = iovec(iov_base: buffers + i * size, iov_len: size)
                    descs[i] = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: iovs + i, vm_pkt_iovcnt: 1, vm_flags: 0)
                }
                var count = Int32(batch)
                guard vmnet_read(self.iface, descs, &count) == .VMNET_SUCCESS, count > 0 else { return }
                for i in 0..<Int(count) {
                    handler(UnsafeRawBufferPointer(start: buffers + i * size, count: descs[i].vm_pkt_size))
                }
                if count < batch { return }
            }
        }
    }

    /// Sends one frame to the network. Oversized frames are dropped.
    public func write(_ frame: UnsafeRawBufferPointer) {
        guard frame.count > 0, frame.count <= maxPacketSize, !isStopped, let base = frame.baseAddress else { return }
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: frame.count)
        withUnsafeMutablePointer(to: &iov) { iovp in
            var desc = vmpktdesc(vm_pkt_size: frame.count, vm_pkt_iov: iovp, vm_pkt_iovcnt: 1, vm_flags: 0)
            var count: Int32 = 1
            _ = vmnet_write(iface, &desc, &count)
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    public func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        vmnet_interface_set_event_callback(iface, .VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
        let sem = DispatchSemaphore(value: 0)
        _ = vmnet_stop_interface(iface, queue) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
    }
}

public struct VmnetError: LocalizedError {
    public let what: String
    /// nil: macOS didn't answer in time.
    public let status: vmnet_return_t?
    public var errorDescription: String? {
        guard let status else { return "could not \(what): vmnet did not respond" }
        let reason: String
        switch status {
        case .VMNET_INVALID_ACCESS: reason = "permission denied"
        case .VMNET_INVALID_ARGUMENT: reason = "invalid argument"
        case .VMNET_MEM_FAILURE: reason = "out of memory"
        default: reason = "vmnet status \(status.rawValue)"
        }
        return "could not \(what) (\(reason))"
    }
}

public enum VmnetInterfaces {
    /// Interfaces macOS can bridge VMs onto (Wi-Fi, Ethernet, Thunderbolt…), by BSD name.
    public static func bridgeable() -> [String] {
        guard let list = vmnet_copy_shared_interface_list() else { return [] }
        var out: [String] = []
        for i in 0..<xpc_array_get_count(list) {
            if let s = xpc_array_get_string(list, i) { out.append(String(cString: s)) }
        }
        return out
    }
}
