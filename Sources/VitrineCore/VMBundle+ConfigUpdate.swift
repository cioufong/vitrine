import Foundation

public extension VMBundle {
    /// Changes the saved configuration: loads it fresh, applies `change`, saves it if anything
    /// changed, and returns the result. Writers that go through here serialize on a short lock on
    /// the bundle directory (independent of the run lock, which a running VM's owner holds), so
    /// two of them changing different settings both keep their change. Not reentrant: don't call
    /// it from inside `change`.
    @discardableResult
    func updateConfig(_ change: (inout VMConfig) throws -> Void) throws -> VMConfig {
        try withConfigLock {
            var config = try loadConfig()
            let before = config
            try change(&config)
            if config != before { try saveConfig(config) }
            return config
        }
    }

    private func withConfigLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return try body() } // loadConfig reports what is wrong with the bundle
        defer { close(fd) } // also drops the lock
        // A file system that can't lock a directory (some network volumes) gets the edit unlocked,
        // as before, rather than no edit at all.
        while flock(fd, LOCK_EX) != 0, errno == EINTR {}
        return try body()
    }
}
