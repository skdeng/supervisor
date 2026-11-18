import Foundation

/// Modules raise a hold here while they keep something a relaunch would lose or undo: files
/// on the shelf, which live in memory; a call in progress, where quitting restores a
/// microphone the notch muted; music the app paused for a call and means to resume.
///
/// Only what cannot be rebuilt from disk or from the system belongs here. State the app reads
/// back at launch, such as the agent sessions SwarmVisor lists or the sites ProVisor is
/// waiting on, is no reason to keep an out-of-date app running.
@MainActor
final class RelaunchHolds {
    static let shared = RelaunchHolds()

    private(set) var owners: Set<String> = []

    var isHeld: Bool { !owners.isEmpty }

    /// Raises or drops `owner`'s hold. Setting an unchanged hold does nothing, so a module may
    /// call this from a periodic tick.
    func set(_ isHeld: Bool, for owner: String) {
        if isHeld {
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }
    }
}
