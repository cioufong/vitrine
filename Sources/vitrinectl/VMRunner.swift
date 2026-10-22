import AppKit
import Virtualization
import VitrineCore
import VitrineVZ
import VitrineQEMU

/// Foreground VM process for `vitrinectl run`. SIGINT/SIGTERM → graceful shutdown; `vitrinectl
/// stop|suspend` arrive over the control socket.
@MainActor
enum VMRunner {
    static var controller: VirtualMachineController?
    static var window: NSWindow?
    static var signalSources: [DispatchSourceSignal] = []

    nonisolated static func run(bundle: VMBundle, gui: Bool, recovery: Bool, console: Bool = false) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(gui ? .regular : .prohibited)
            do {
                let c = try VirtualMachineController(bundle: bundle)
                controller = c
                c.lifecycleRequestHandler = { perform($0, on: c) }
                installSignalHandlers(c)
                Task { @MainActor in
                    do {
                        try await c.start(recovery: recovery)
                        print("\(bundle.name) is running (pid \(getpid())). Ctrl-C to shut down, `vitrinectl suspend \(bundle.name)` to suspend.")
                        if gui { showWindow(c) }
                        c.displayViewProvider = { window?.contentView as? GuestDisplayView }
                        if console { tailConsole(bundle) }
                        watch(c)
                    } catch {
                        FileHandle.standardError.write(Data("vitrinectl: \(error.localizedDescription)\n".utf8))
                        exit(1)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("vitrinectl: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            app.run()
        }
        exit(0)
    }

    static func installSignalHandlers(_ c: VirtualMachineController) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { perform(.stop, on: c) } }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Carries out a shutdown signal or a `stop`/`suspend`/`forceStop` control request.
    static func perform(_ op: VMControl.Request.Op, on c: VirtualMachineController) {
        Task { @MainActor in
            switch op {
            case .suspend:
                do { try await c.suspend() } catch { print("suspend failed: \(error.localizedDescription)") }
            case .forceStop: await c.forceStop()
            default:
                print("\nshutting down \(c.bundle.name)…")
                await c.stop()
            }
        }
    }

    /// Streams the guest serial console (console.log) to stdout.
    static func tailConsole(_ bundle: VMBundle) {
        guard let h = try? FileHandle(forReadingFrom: bundle.consoleLogURL) else { return }
        h.seekToEndOfFile()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            let d = h.availableData
            if !d.isEmpty { FileHandle.standardOutput.write(d) }
        }
    }

    /// Exits once the VM is no longer running.
    static func watch(_ c: VirtualMachineController) {
        Task { @MainActor in
            var lastAgent = ""
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if c.agentStatus != lastAgent {
                    lastAgent = c.agentStatus
                    let caps = c.agent?.guestHello?.capabilities.sorted().joined(separator: " ") ?? ""
                    print("agent: \(lastAgent)" + (caps.isEmpty ? "" : " [\(caps)]"))
                    if c.agentLacksPermissions, c.agent?.guestHello?.capabilities.contains("permissions") == true {
                        print("agent: for seamless mode, run `vitrinectl agent permissions \(c.bundle.name)` and allow both prompts in the VM")
                    }
                }
                switch c.state {
                case .stopped, .suspended:
                    if c.windowsSetup == .restarting { continue } // Windows setup finished; booting again
                    print("\(c.bundle.name) \(c.state.rawValue)")
                    exit(0)
                case .error:
                    // A failed suspend can leave an owned backend whose state is unknown. Keep
                    // the signal/control owner alive so a deliberate force-stop remains possible.
                    if c.qemu?.isRunning == true { continue }
                    print("\(c.bundle.name) stopped with error: \(c.lastError ?? "unknown")")
                    exit(1)
                default: continue
                }
            }
        }
    }

    static func showWindow(_ c: VirtualMachineController) {
        let view: NSView
        if let vm = c.virtualMachine {
            let v = GuestDisplayView()
            v.virtualMachine = vm
            v.capturesSystemKeys = true
            v.automaticallyReconfiguresDisplay = c.config.display.autoResize
            view = v
        } else if let rfb = c.qemu?.rfb {
            view = QEMUDisplayView(rfb: rfb)
        } else {
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(c.config.display.widthPixels) / scale * 0.8,
                          height: CGFloat(c.config.display.heightPixels) / scale * 0.8)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = c.bundle.name
        w.contentView = view
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
