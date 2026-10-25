import Darwin
import Foundation

/// A kernel-held, machine-wide lock shared by all copies of the app.
/// Keep the inode in place: unlinking a lock file could let two processes lock different files.
public final class InstanceLock {
    public enum Status: Equatable { case acquired, alreadyRunning, unavailable(Int32) }
    public let status: Status
    private var descriptor: Int32 = -1

    public init(path: String = "/tmp/dev.swoosh.launcher.instance") {
        let fd = open(path, O_CREAT | O_RDONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o644))
        guard fd >= 0 else { status = .unavailable(errno); return }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(fd); status = .unavailable(EINVAL); return
        }
        // The file contains no data. Other login accounts need read access to take the lock.
        if metadata.st_uid == geteuid() { _ = fchmod(fd, mode_t(0o644)) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd; status = .acquired
        } else {
            let code = errno
            close(fd)
            status = code == EWOULDBLOCK ? .alreadyRunning : .unavailable(code)
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
