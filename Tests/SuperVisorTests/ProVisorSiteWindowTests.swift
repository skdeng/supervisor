import AppKit
import Foundation
import Testing
import WebKit

@testable import SuperVisor

/// The Add Site window keeps the size it was given whatever the form shows, holds the
/// enrollment's web view, and ends the enrollment when it closes.
///
/// The window is put on screen, as layout runs there the way it does in the app, at zero
/// opacity and ignoring the mouse, so nobody at the machine sees or touches it while the suite
/// runs.
@Suite("ProVisor site window", .serialized)
@MainActor
struct ProVisorSiteWindowTests {
    private func settle(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @Test("Form changes leave the window's size alone, and the page is in the window", .timeLimit(.minutes(1)))
    func formChangesKeepSize() async throws {
        _ = NSApplication.shared
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
        let model = SiteFormModel()
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        window.show(center: center, enrollment: enrollment, model: model)
        let content = try #require(window.contentView)
        #expect(content.frame.size == SiteEnrollmentWindow.initialContentSize)
        #expect(window.contentMinSize == SiteEnrollmentWindow.minimumContentSize)

        window.orderFront(nil)
        try await settle(window)
        let frame = window.frame

        let webView = enrollment.browser.webView
        #expect(webView.window === window)
        #expect(webView.isDescendant(of: content))
        #expect(webView.frame.width > 0 && webView.frame.height > 0)

        // Fields appear and disappear, problems show, and the page loads beside them.
        model.codeKind = .authenticator
        model.authenticatorKey = "not-a-key"
        try await settle(window)
        model.codeKind = .email
        model.codeSender = "no reply"
        model.address = "http://example.com"
        try await settle(window)
        model.codeKind = .text
        model.address = "example.com/login"
        model.username = bank.username
        model.password = bank.password
        model.codeKind = .none
        await model.signIn(using: enrollment)
        try await settle(window)

        #expect(enrollment.currentHost == "example.com")
        #expect(window.frame == frame)
        #expect(content.frame.size == SiteEnrollmentWindow.initialContentSize)
        #expect(webView.window === window)
    }

    @Test("Closing the window ends the enrollment and takes the page out of it", .timeLimit(.minutes(1)))
    func closingCancels() async throws {
        _ = NSApplication.shared
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: { _ in nil },
            settling: .fast
        )
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        window.show(center: center, enrollment: enrollment, model: SiteFormModel())
        window.orderFront(nil)
        try await settle(window)
        #expect(enrollment.browser.webView.window === window)

        window.performClose(nil)

        #expect(!window.isVisible)
        #expect(window.enrollment == nil)
        #expect(enrollment.browser.webView.superview == nil)
        await #expect(throws: SiteBrowser.Failure.closed) {
            _ = try await enrollment.browser.open(URL(string: "https://example.com/")!)
        }
    }

    @Test("Showing another enrollment in the window ends the one it showed", .timeLimit(.minutes(1)))
    func replacingCancels() async throws {
        _ = NSApplication.shared
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        func makeEnrollment() -> SiteEnrollment {
            SiteEnrollment(
                dataStore: .nonPersistent(),
                codes: CodeStub().codes,
                simulatedPages: { _ in nil },
                settling: .fast
            )
        }
        let first = makeEnrollment()
        let second = makeEnrollment()
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        window.show(center: center, enrollment: first, model: SiteFormModel())
        window.orderFront(nil)
        try await settle(window)
        window.show(center: center, enrollment: second, model: SiteFormModel())
        try await settle(window)

        #expect(window.enrollment === second)
        #expect(first.browser.webView.superview == nil)

        // A save of the earlier enrollment that completes now does not close the later one.
        window.close(showing: first)
        #expect(window.isVisible)
        #expect(window.enrollment === second)
        #expect(second.browser.webView.window === window)
        await #expect(throws: SiteBrowser.Failure.closed) {
            _ = try await first.browser.open(URL(string: "https://example.com/")!)
        }
    }

    @Test("Keys a person types into a password field on the page are reported", .timeLimit(.minutes(1)))
    func typingIntoThePageIsReported() async throws {
        let application = NSApplication.shared
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }
        window.show(center: center, enrollment: enrollment, model: SiteFormModel())
        window.makeKeyAndOrderFront(nil)
        try await settle(window)

        var typed = 0
        let observer = enrollment.browser.passwordTypedObserver
        enrollment.browser.passwordTypedObserver = {
            typed += 1
            observer?()
        }
        let webView = enrollment.browser.webView
        _ = try await enrollment.browser.open(URL(string: "https://example.com/login")!)
        window.makeFirstResponder(webView)
        _ = try await enrollment.browser.run("document.getElementById('pass').focus();")
        try await Task.sleep(for: .milliseconds(100))

        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ))
            application.sendEvent(event)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while typed == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let length = try await enrollment.browser.run("return document.getElementById('pass').value.length;")

        #expect(length.int == 1)
        #expect(typed == 1)
    }
}
