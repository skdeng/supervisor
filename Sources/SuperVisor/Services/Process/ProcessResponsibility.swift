import Darwin

/// Starts a child process as its own "responsible process" for macOS privacy decisions.
///
/// macOS attributes a child's access to protected data — the Messages database, Mail, the
/// Desktop — to the app that started it, so a child inherits whatever the app was granted. An
/// agent process is started with that responsibility disclaimed: it reads mail from anyone, and
/// the app's grants must not sit underneath its own confinement.
///
/// The call is private API, reached by symbol per the repo's private-framework rule. A missing
/// symbol leaves the attributes untouched and reports it, so a caller that depends on the
/// disclaim can refuse to proceed.
enum ProcessResponsibility {
    private typealias SetDisclaim = @convention(c) (
        UnsafeMutablePointer<posix_spawnattr_t?>,
        Int32
    ) -> Int32

    private static let setDisclaim: SetDisclaim? = {
        // RTLD_DEFAULT: search every image already loaded.
        let everyLoadedImage = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(everyLoadedImage, "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()

    static var isAvailable: Bool { setDisclaim != nil }

    /// Marks `attributes` so the spawned child is responsible for itself. Returns whether it
    /// took effect.
    static func disclaim(_ attributes: inout posix_spawnattr_t?) -> Bool {
        guard let setDisclaim else { return false }
        return setDisclaim(&attributes, 1) == 0
    }
}
