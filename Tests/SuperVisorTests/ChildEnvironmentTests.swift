import Foundation
import Testing

@testable import SuperVisor

@Suite("Child environment")
struct ChildEnvironmentTests {
    @Test("The fixed list holds exactly the variables a child needs, drawn from the system's record of the user")
    func fixedList() {
        let environment = ChildEnvironment.minimal()
        #expect(environment == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "SHELL": "/bin/zsh",
        ])
        #expect(ChildEnvironment.path == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("Nothing in the list is the app's own search path or home folder variable by inheritance")
    func independentOfTheAppsEnvironment() {
        let inherited = ProcessInfo.processInfo.environment
        let environment = ChildEnvironment.minimal()
        // The test runner's PATH includes the toolchain; the child's is the fixed one.
        #expect(inherited["PATH"] != environment["PATH"])
        for name in ["DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH", "PERL5OPT", "PERL5LIB", "ZIPOPT"] {
            #expect(environment[name] == nil)
        }
    }

    @Test("Added variables join the list and replace a fixed one of the same name")
    func addingVariables() {
        let environment = ChildEnvironment.minimal(adding: [
            "SUPERVISOR_EXTRA": "1",
            "PATH": "/opt/tool/bin:" + ChildEnvironment.path,
        ])
        #expect(environment["SUPERVISOR_EXTRA"] == "1")
        #expect(environment["PATH"] == "/opt/tool/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == NSHomeDirectory())
        #expect(environment.count == ChildEnvironment.minimal().count + 1)
    }
}
