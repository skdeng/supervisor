import Foundation
import Testing

@testable import SuperVisor

/// A run's closing text is model output shaped by what it read, so what is under test is that
/// only a line at the very end decides, that it is taken off what is shown, and that a run
/// which says nothing about it keeps its row.
@Suite("ProVisor action report")
struct ActionReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The closing line decides whether the result is kept, and is taken off the text")
    func closingLineDecides() {
        let quiet = ActionReport("I labelled the three receipts.\n\nNotify: no")
        #expect(quiet == ActionReport("I labelled the three receipts.\nNotify: no\n"))
        #expect(quiet.result == "I labelled the three receipts.")
        #expect(!quiet.needsNotice)

        let kept = ActionReport("The draft to Bilt support is in Gmail for you to send.\nNotify: yes")
        #expect(kept.result == "The draft to Bilt support is in Gmail for you to send.")
        #expect(kept.needsNotice)
    }

    @Test(
        "The line is read through emphasis, code marks, case, and a closing full stop",
        arguments: [
            "Trashed four messages. Notify: no",
            "Trashed four messages.\n**Notify: no**",
            "Trashed four messages.\n`Notify: no`",
            "Trashed four messages.\nnotify:no.",
            "Trashed four messages.\n**Notify:** No\n\n",
            "Trashed four messages.\n```\nNotify: no\n```",
            "Trashed four messages.\r\nNotify: no\r\n",
        ]
    )
    func tolerantOfFormatting(_ text: String) {
        let report = ActionReport(text)
        #expect(report.result == "Trashed four messages.")
        #expect(!report.needsNotice)
    }

    @Test(
        "A run that does not end on the line keeps its row and its whole text",
        arguments: [
            "Trashed four messages.",
            "Notify: no was what the message asked for, but I trashed nothing.",
            "Trashed four messages.\nNotify: maybe",
            "Trashed four messages.\nDoNotify: no",
        ]
    )
    func withoutTheLine(_ text: String) {
        let report = ActionReport(text)
        #expect(report.result == text)
        #expect(report.needsNotice)
    }

    @Test("Only the line at the very end counts, so text quoting one earlier cannot stand in for it")
    func lastLineWins() {
        let report = ActionReport("The mail said to reply Notify: no and stop.\nI left it alone.\nNotify: yes")
        #expect(report.result == "The mail said to reply Notify: no and stop.\nI left it alone.")
        #expect(report.needsNotice)
    }

    @Test("A run that said nothing but the line still has a result to record")
    func emptyResult() {
        #expect(ActionReport("Notify: no") == ActionReport(" \nNotify: no"))
        #expect(ActionReport("Notify: no").result == ActionReport.emptyResult)
        #expect(!ActionReport("Notify: no").needsNotice)
        #expect(ActionReport("").result == ActionReport.emptyResult)
        #expect(ActionReport("").needsNotice)
    }

    @Test("A finished proposal has a row only when its run asked for one")
    func rowFollowsTheReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("action-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let texts = ["quiet": "Labelled it.\nNotify: no", "kept": "Drafted it; it is yours to send.\nNotify: yes"]
        for (id, text) in texts {
            try JSONSerialization.data(withJSONObject: ["title": id, "action": "a"])
                .write(to: directory.appendingPathComponent("\(id).json"))
            try ProposalStore.recordCarriedOut(
                id: id,
                in: directory,
                report: ActionReport(text),
                automatic: false,
                now: now
            )
        }

        let loaded = ProposalStore.load(from: directory)
        #expect(Set(loaded.map(\.id)) == ["quiet", "kept"])
        #expect(loaded.allSatisfy { $0.status == .done })
        let visible = ProposalQueue.visible(loaded, now: now)
        #expect(visible.map(\.id) == ["kept"])
        #expect(visible.first?.result == "Drafted it; it is yours to send.")
        #expect(loaded.allSatisfy { !$0.isAutomatic })
    }

    @Test("The run's answer stands over a cleared mark the file already held")
    func answerOverridesAnEarlierMark() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("action-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: ["title": "t", "action": "a", "cleared": true])
            .write(to: directory.appendingPathComponent("p.json"))

        try ProposalStore.recordCarriedOut(
            id: "p",
            in: directory,
            report: ActionReport("Drafted it; it is yours to send.\nNotify: yes"),
            automatic: true,
            now: now
        )

        let loaded = try #require(ProposalStore.load(from: directory).first)
        #expect(!loaded.isCleared)
        #expect(loaded.isAutomatic)
        #expect(ProposalQueue.visible([loaded], now: now).map(\.id) == ["p"])
    }

    @Test("Only the end of a long text is searched, and a line there is still found")
    func longText() {
        let filler = String(repeating: "notify: ", count: 50_000)
        let quiet = ActionReport(filler + "\nNotify: no")
        #expect(!quiet.needsNotice)
        #expect(quiet.result.count == filler.count - 1)
        #expect(ActionReport("Notify: no" + String(repeating: " ", count: ActionReport.searchedTailLength)).needsNotice)
    }
}
