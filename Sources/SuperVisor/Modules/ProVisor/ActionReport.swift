import Foundation

/// What a run that carried out a proposal said as it finished: the result to show, and whether
/// the person still needs to see it.
///
/// The run closes on a line saying which (`ProVisorCommand.noticeInstruction`). That line is
/// model output shaped by whatever the run read, so it decides one thing only: whether the
/// finished proposal keeps a row in the sheet. A run that leaves the line out keeps the row.
struct ActionReport: Equatable {
    /// The run's closing text with the notice line taken off, or `emptyResult` when nothing
    /// else was said.
    let result: String
    let needsNotice: Bool

    static let emptyResult = "Done."
    /// How much of the end of the text is searched for the line. A run's text can be megabytes
    /// long and is read on the main actor.
    static let searchedTailLength = 200

    init(_ text: String) {
        // The line may arrive wrapped in markdown emphasis, code marks, or a code fence, or
        // closed by a full stop. Only one at the very end of the text counts.
        let closingLine = #/(?:\A|\s)[*_`\s]*notify:[*_`\s]*(yes|no)[*_`.\s]*\z/#.ignoresCase()
        let match = text.suffix(Self.searchedTailLength).firstMatch(of: closingLine)
        let said = text[..<(match?.range.lowerBound ?? text.endIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = said.isEmpty ? Self.emptyResult : said
        needsNotice = match.map { $0.output.1.lowercased() == "yes" } ?? true
    }
}
