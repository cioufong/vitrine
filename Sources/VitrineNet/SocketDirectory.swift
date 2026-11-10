import Foundation

/// The directory vitrine-bridged keeps its sockets in (/var/run/vitrine). Root creates sockets
/// there and hands each to a user, so the directory has to be root's alone: a real directory, not
/// a symlink, owned by root, and writable by nobody else.
public enum SocketDirectory {
    public struct Refused: Error, CustomStringConvertible {
        public let description: String
    }

    /// Makes `path` a directory owned by `owner` (root, except in tests) with mode 0755 (and, where it can, no ACL).
    /// A symlink or other non-directory there is removed and replaced; an existing directory has
    /// group and world write taken away. A directory owned by anyone else is refused, not fixed:
    /// whoever owns it may have left something inside.
    public static func prepare(_ path: String, owner: uid_t = 0) throws {
        func fail(_ what: String) -> Refused {
            Refused(description: "\(path): \(what) (\(String(cString: strerror(errno))))")
        }
        var st = stat()
        if lstat(path, &st) == 0 {
            if st.st_mode & S_IFMT != S_IFDIR {
                // unlink removes a symlink itself, never what it points to.
                guard unlink(path) == 0 else { throw fail("cannot remove the non-directory in the way") }
            }
        } else if errno != ENOENT {
            throw fail("cannot inspect")
        }
        if mkdir(path, 0o755) != 0 && errno != EEXIST { throw fail("cannot create") }
        // Everything from here on goes through the descriptor, so the path can't be swapped under us.
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fail("is not a directory") }
        defer { close(fd) }
        guard fstat(fd, &st) == 0 else { throw fail("cannot inspect") }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw Refused(description: "\(path): is not a directory") }
        guard st.st_uid == owner else {
            throw Refused(description: "\(path): owned by uid \(st.st_uid), not \(owner); remove it and restart")
        }
        guard fchmod(fd, 0o755) == 0 else { throw fail("cannot set its mode") }
        // Best effort: only root can put an ACL on a root-owned directory in the first place.
        if let empty = acl_init(0) {
            _ = acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED)
            acl_free(UnsafeMutableRawPointer(empty))
        }
    }
}
