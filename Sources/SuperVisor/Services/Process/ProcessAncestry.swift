import Darwin

/// When a process started, as the kernel records it. Two processes that held the same pid at
/// different times differ here.
struct ProcessStartTime: Equatable, Sendable {
    let seconds: Int
    let microseconds: Int
}

/// Reads process parentage and identity from the kernel's process table.
enum ProcessAncestry {
    /// The parent of `pid`, or nil when the process no longer exists or names itself as its own
    /// parent.
    static func parentPID(of pid: pid_t) -> pid_t? {
        guard let info = processInfo(of: pid) else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent == pid ? nil : parent
    }

    /// When `pid` started, or nil when no such process exists.
    static func startTime(of pid: pid_t) -> ProcessStartTime? {
        guard let info = processInfo(of: pid) else { return nil }
        let started = info.kp_proc.p_starttime
        return ProcessStartTime(seconds: Int(started.tv_sec), microseconds: Int(started.tv_usec))
    }

    private static func processInfo(of pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride
        else { return nil }
        return info
    }
}
