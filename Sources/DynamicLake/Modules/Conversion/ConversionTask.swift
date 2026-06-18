import Foundation

/// The lifecycle state of a single conversion.
enum ConversionState: Equatable {
    /// Queued but not yet started (e.g. ffmpeg busy with another job).
    case queued
    /// Running; `fraction` is 0…1 progress (or nil while indeterminate).
    case running(fraction: Double?)
    /// Finished successfully.
    case finished
    /// Failed; carries a short human-readable reason.
    case failed(reason: String)
    /// User-cancelled.
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: return true
        case .queued, .running: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .running: return true
        case .finished, .failed, .cancelled: return false
        }
    }
}

/// Observable, mutable runtime state for one conversion. The recipe is the embedded
/// `ConversionJob`; this reference type tracks live progress so SwiftUI rows update in
/// place. State is mutated only on the main actor by `ConversionRunner`.
@MainActor
final class ConversionTask: ObservableObject, Identifiable {
    let job: ConversionJob
    nonisolated var id: UUID { job.id }

    @Published private(set) var state: ConversionState = .queued
    /// Wall-clock start, set when the process actually launches.
    @Published private(set) var startedAt: Date?

    init(job: ConversionJob) {
        self.job = job
    }

    func markRunning(fraction: Double?) {
        if startedAt == nil { startedAt = Date() }
        state = .running(fraction: fraction)
    }

    func markFinished() { state = .finished }
    func markFailed(_ reason: String) { state = .failed(reason: reason) }
    func markCancelled() { state = .cancelled }
}
