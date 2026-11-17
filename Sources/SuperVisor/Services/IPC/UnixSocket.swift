import Darwin

/// Socket plumbing shared by both ends of a Unix-domain stream connection.
enum UnixSocket {
    /// The bytes `sun_path` holds, terminating NUL included.
    static let maximumPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// The address for `path`, or nil when the path is empty, holds a NUL, or does not fit
    /// `sun_path`.
    static func address(for path: String) -> sockaddr_un? {
        let pathBytes = path.utf8CString
        guard pathBytes.count > 1,
              pathBytes.count <= maximumPathBytes,
              !path.utf8.contains(0)
        else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { bytes in
                _ = pathBytes.withUnsafeBufferPointer {
                    memcpy(bytes, $0.baseAddress, pathBytes.count)
                }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A connected, blocking descriptor to the socket at `path`, or nil when nothing accepts
    /// there.
    static func connect(to path: String) -> Int32? {
        guard var address = address(for: path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        prepare(descriptor)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Makes `descriptor` blocking, closed across `exec`, and exempt from SIGPIPE.
    ///
    /// A connection accepted from a non-blocking listener inherits `O_NONBLOCK`. The close-on-exec
    /// flag keeps a spawned child from inheriting the connection. SIGPIPE exemption set here
    /// fails with `EINVAL` on a connection whose peer has already closed, so a listener sets it
    /// on its listening socket, which its accepted connections inherit.
    static func prepare(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        exemptFromSIGPIPE(descriptor)
    }

    /// Makes a write to a closed peer fail with `EPIPE` instead of raising SIGPIPE.
    static func exemptFromSIGPIPE(_ descriptor: Int32) {
        var noPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    /// Bounds how long a write may block on a peer that has stopped reading.
    static func setSendTimeout(_ seconds: Int, on descriptor: Int32) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
}
