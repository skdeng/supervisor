import Foundation
import FoundationModels

enum OnDeviceModelError: Error, LocalizedError, Sendable {
    case unavailable
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The on-device language model is unavailable."
        case let .generationFailed(message):
            return message.isEmpty
                ? "The on-device language model could not generate a response."
                : message
        case .cancelled:
            return "The on-device language model request was cancelled."
        }
    }
}

/// Isolates the system language-model API from the app's provider-agnostic routing code.
struct OnDeviceTextModel: Sendable {
    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        guard isAvailable else {
            throw OnDeviceModelError.unavailable
        }

        do {
            try Task.checkCancellation()
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            try Task.checkCancellation()
            return response.content
        } catch is CancellationError {
            throw OnDeviceModelError.cancelled
        } catch {
            if Task.isCancelled {
                throw OnDeviceModelError.cancelled
            }
            throw OnDeviceModelError.generationFailed(error.localizedDescription)
        }
    }
}
