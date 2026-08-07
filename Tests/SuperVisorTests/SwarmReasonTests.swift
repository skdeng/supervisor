import Foundation
import Testing

@testable import SuperVisor

@Suite("Attention row text")
struct SwarmReasonTests {
    @Test("An approval names the tool it is waiting on")
    func approvalSplitsOutTheTool() {
        let parts = SwarmReason.parts(of: .waiting(detail: "approve Bash"), showsMessages: true)

        #expect(parts.label == "Approve")
        #expect(parts.detail == "Bash")
    }

    @Test("A waiting phrase that names no tool reads as its own label")
    func otherWaitingPhrasesBecomeLabels() {
        let parts = SwarmReason.parts(of: .waiting(detail: "sandbox request"), showsMessages: true)

        #expect(parts.label == "Sandbox request")
        #expect(parts.detail == nil)
    }

    @Test("An error code reads as words")
    func errorCodeIsHumanised() {
        let parts = SwarmReason.parts(
            of: .failed(error: "rate_limit", details: nil),
            showsMessages: true
        )

        #expect(parts.label == "Rate limit")
    }

    @Test("A finished turn carries its length in the label")
    func finishedCarriesDuration() {
        let parts = SwarmReason.parts(
            of: .finished(turnDuration: 754, summary: "All green."),
            showsMessages: true
        )

        #expect(parts.label == "Done 12m")
        #expect(parts.detail == "All green.")
    }

    @Test("An idle prompt says only that, carrying no text of its own")
    func needsInputHasNoDetail() {
        let parts = SwarmReason.parts(of: .needsInput, showsMessages: true)

        #expect(parts.label == "Needs input")
        #expect(parts.detail == nil)
    }

    /// The setting exists so nothing a session said sits on a floating panel during a screen
    /// share; states and tool names are fixed vocabulary and stay visible either way.
    @Test("Session content hides when messages are off, and labels do not", arguments: [
        AttentionReason.asked(question: "Which auth approach?"),
        AttentionReason.finished(turnDuration: 60, summary: "Shipped it."),
        AttentionReason.failed(error: "rate_limit", details: "retry after 60s"),
    ])
    func contentIsGatedButLabelsAreNot(reason: AttentionReason) {
        let shown = SwarmReason.parts(of: reason, showsMessages: true)
        let hidden = SwarmReason.parts(of: reason, showsMessages: false)

        #expect(shown.detail != nil)
        #expect(hidden.detail == nil)
        #expect(hidden.label == shown.label)
    }

    @Test("A tool name stays visible with messages off")
    func toolNameIsNotGated() {
        let parts = SwarmReason.parts(of: .waiting(detail: "approve Bash"), showsMessages: false)

        #expect(parts.detail == "Bash")
    }

    @Test("A blocked session outranks a finished one")
    func blockingOutranksFinished() {
        #expect(AttentionReason.failed(error: "rate_limit", details: nil).rank
            > AttentionReason.waiting(detail: "approve Bash").rank)
        #expect(AttentionReason.waiting(detail: "approve Bash").rank
            > AttentionReason.asked(question: "?").rank)
        #expect(AttentionReason.asked(question: "?").rank
            > AttentionReason.finished(turnDuration: nil, summary: nil).rank)
        #expect(AttentionReason.finished(turnDuration: nil, summary: nil).rank
            > AttentionReason.needsInput.rank)

        #expect(AttentionReason.waiting(detail: "approve Bash").isBlocking)
        #expect(AttentionReason.failed(error: "rate_limit", details: nil).isBlocking)
        #expect(!AttentionReason.finished(turnDuration: nil, summary: nil).isBlocking)
    }
}

@MainActor
@Suite("Untrusted text handling")
struct SwarmSanitizationTests {
    @Test("A multi-line message collapses to one line")
    func newlinesCollapse() {
        let sanitized = AgentFleetCenter.displayMessage("Done.\n\nThree files changed.\n")

        #expect(sanitized == "Done. Three files changed.")
    }

    @Test("Control characters are dropped")
    func controlCharactersAreStripped() {
        let sanitized = AgentFleetCenter.displayMessage("clean\u{0007}\u{001B}[31mtext")

        #expect(sanitized == "clean[31mtext")
    }

    @Test("An overlong message is capped")
    func longMessageIsCapped() {
        let sanitized = AgentFleetCenter.displayMessage(String(repeating: "a", count: 5_000))

        #expect(sanitized?.count == 400)
    }

    @Test("Blank and absent messages produce nothing")
    func blankMessagesBecomeNil() {
        #expect(AgentFleetCenter.displayMessage(nil) == nil)
        #expect(AgentFleetCenter.displayMessage("   \n\t ") == nil)
    }
}

@Suite("Registry parsing")
struct FleetSessionTests {
    private func session(status: FleetSessionStatus, waitingFor: String?) -> FleetSession {
        FleetSession(
            pid: 1,
            sessionID: "s",
            name: "n",
            cwd: "/tmp",
            status: status,
            statusUpdatedAt: Date(),
            kind: "interactive",
            waitingFor: waitingFor
        )
    }

    @Test("A waiting session reports the tool its approval is for")
    func approvalToolIsExtracted() {
        #expect(session(status: .waiting, waitingFor: "approve Edit").pendingApprovalTool == "Edit")
    }

    @Test("A phrase naming no tool yields none")
    func nonApprovalPhrasesYieldNoTool() {
        #expect(session(status: .waiting, waitingFor: "input needed").pendingApprovalTool == nil)
        #expect(session(status: .waiting, waitingFor: "approve ").pendingApprovalTool == nil)
    }

    @Test("A stale phrase on a session that is no longer waiting is ignored")
    func nonWaitingStatusYieldsNoTool() {
        #expect(session(status: .idle, waitingFor: "approve Edit").pendingApprovalTool == nil)
    }
}

@Suite("Hook payload validation")
struct FleetHookEventTests {
    private func event(
        lastAssistantMessage: String? = nil,
        error: String? = nil,
        tty: String? = nil
    ) -> FleetHookEvent {
        FleetHookEvent(
            sessionID: "s",
            cwd: "/tmp",
            event: "Stop",
            pid: 42,
            tty: tty,
            status: .waitingForInput,
            notificationType: nil,
            message: nil,
            lastAssistantMessage: lastAssistantMessage,
            error: error,
            errorDetails: nil
        )
    }

    @Test("A well-formed payload validates")
    func wellFormedPayloadIsValid() {
        #expect(event(lastAssistantMessage: "Done.", tty: "/dev/ttys001").isValid)
    }

    @Test("An oversized message is rejected rather than truncated")
    func oversizedTextIsRejected() {
        let overCap = String(repeating: "a", count: FleetHookEvent.maximumTextLength + 1)

        #expect(!event(lastAssistantMessage: overCap).isValid)
        #expect(event(lastAssistantMessage: String(overCap.dropLast())).isValid)
    }

    @Test("An oversized error code is rejected")
    func oversizedErrorIsRejected() {
        #expect(!event(error: String(repeating: "e", count: 129)).isValid)
    }
}
