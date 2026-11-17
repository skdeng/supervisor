import Foundation
import Testing

@testable import SuperVisor

@Suite("File log mirror")
struct FileLogMirrorTests {
    @Test("The test runner writes nothing to the app's log file")
    func testRunnerDoesNotWrite() {
        #expect(!FileLogMirror.writesInThisProcess)
        #expect(Bundle.main.bundleIdentifier != AppLog.subsystem)
    }
}
