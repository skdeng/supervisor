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
        model.method = .signsInForMe
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

    @Test("Switching how the site is kept, and opening the page, leave the window's size alone", .timeLimit(.minutes(1)))
    func methodChangesKeepSize() async throws {
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
        let model = SiteFormModel(
            unreadableSite: SiteRecord(id: "example.com", name: "Bank", added: Date(timeIntervalSince1970: 0)),
            requestedBy: "p"
        )
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        window.show(center: center, enrollment: enrollment, model: model)
        #expect(window.requestID == "p")
        window.orderFront(nil)
        try await settle(window)
        let frame = window.frame

        model.method = .signsInForMe
        model.codeKind = .authenticator
        try await settle(window)
        model.method = .keepsSession
        try await settle(window)
        model.address = "example.com/login"
        await model.openPage(using: enrollment)
        try await settle(window)

        #expect(enrollment.currentHost == "example.com")
        #expect(bank.site.posts.isEmpty)
        #expect(window.frame == frame)
        #expect(window.contentView?.frame.size == SiteEnrollmentWindow.initialContentSize)

        window.close()
        #expect(window.requestID == nil)
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

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the window never reached the expected state")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("The sign-in window opens its page by itself, and a sign-in neither resizes nor closes it", .timeLimit(.minutes(1)))
    func signInWindowOpensAndStays() async throws {
        _ = NSApplication.shared
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast,
            recheckInterval: .milliseconds(50)
        )
        let model = SiteSignInModel(
            host: "example.com",
            record: nil,
            start: .opensPage(URL(string: "https://example.com/login")!),
            proposalID: "p",
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        window.show(center: center, enrollment: enrollment, signIn: model)
        #expect(window.content == .signIn(host: "example.com"))
        #expect(window.requestID == "p")
        #expect(window.title == "Sign In")
        window.orderFront(nil)
        try await settle(window)
        let frame = window.frame
        try await waitFor { model.hasOpenedPage && !model.isWorking && enrollment.currentHost == "example.com" }
        #expect(enrollment.browser.webView.window === window)

        _ = try await enrollment.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["username": bank.username, "password": bank.password])
        try await waitFor { enrollment.appearsSignedIn }
        try await settle(window)

        #expect(window.isVisible)
        #expect(window.enrollment === enrollment)
        #expect(window.frame == frame)
        #expect(window.contentView?.frame.size == SiteEnrollmentWindow.initialContentSize)
        #expect(center.sites.isEmpty)

        window.close()
        #expect(window.content == nil)
        #expect(window.requestID == nil)
    }

    @Test("The password panel replaces Done without resizing the window, and closing it ends the enrollment and its hold", .timeLimit(.minutes(1)))
    func passwordPanelKeepsSize() async throws {
        _ = NSApplication.shared
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        let holds = FollowUpHoldsStub()
        let enrollment = SiteEnrollment.recordingCredentials(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast,
            recheckInterval: .milliseconds(50)
        )
        let model = SiteSignInModel(
            host: "example.com",
            record: nil,
            start: .opensPage(URL(string: "https://example.com/login")!),
            proposalID: nil,
            needsPerson: false,
            offersPasswords: true,
            followUps: holds
        )
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        window.show(center: center, enrollment: enrollment, signIn: model)
        window.orderFront(nil)
        try await settle(window)
        let frame = window.frame
        try await waitFor { model.hasOpenedPage && !model.isWorking && enrollment.currentHost == "example.com" }

        _ = try await enrollment.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            """, arguments: ["username": bank.username, "password": bank.password])
        enrollment.browser.noteCredential(try #require(typedCredential([
            "kind": "username", "value": bank.username, "name": "username", "id": "user",
            "autocomplete": "username", "type": "text",
        ])))
        enrollment.browser.noteCredential(try #require(typedCredential(["value": bank.password, "name": "password", "id": "pass"])))
        _ = try await enrollment.browser.run("HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);")
        try await waitFor { enrollment.appearsSignedIn }

        #expect(await model.done(using: enrollment, into: center) == .savedAndAsking)
        try await settle(window)

        #expect(model.panel == .offer(siteName: "example.com", username: bank.username, host: "example.com"))
        #expect(window.isVisible)
        #expect(window.enrollment === enrollment)
        #expect(window.frame == frame)
        #expect(window.contentView?.frame.size == SiteEnrollmentWindow.initialContentSize)
        #expect(holds.isHeld)

        window.close()
        #expect(enrollment.isCancelled)
        #expect(enrollment.passwordOffer == nil)
        #expect(!holds.isHeld)
        #expect(center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("An offer left unanswered closes the window as Session Only does", .timeLimit(.minutes(1)))
    func unansweredOfferClosesTheWindow() async throws {
        _ = NSApplication.shared
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        let holds = FollowUpHoldsStub()
        let enrollment = SiteEnrollment.recordingCredentials(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast,
            recheckInterval: .milliseconds(50)
        )
        let model = SiteSignInModel(
            host: "example.com",
            record: nil,
            start: .opensPage(URL(string: "https://example.com/login")!),
            proposalID: nil,
            needsPerson: false,
            offersPasswords: true,
            followUps: holds,
            offerTimeout: .milliseconds(300)
        )
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        window.show(center: center, enrollment: enrollment, signIn: model)
        window.orderFront(nil)
        try await waitFor { model.hasOpenedPage && !model.isWorking && enrollment.currentHost == "example.com" }
        _ = try await enrollment.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            """, arguments: ["username": bank.username, "password": bank.password])
        enrollment.browser.noteCredential(try #require(typedCredential(["value": bank.password, "name": "password", "id": "pass"])))
        _ = try await enrollment.browser.run("HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);")
        try await waitFor { enrollment.appearsSignedIn }

        #expect(await model.done(using: enrollment, into: center) == .savedAndAsking)
        #expect(window.isVisible)
        #expect(holds.isHeld)

        try await waitFor { !window.isVisible }
        #expect(window.enrollment == nil)
        #expect(enrollment.isCancelled)
        #expect(!holds.isHeld)
        #expect(center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("Showing the sign-in window ends an Add Site enrollment, and the reverse", .timeLimit(.minutes(1)))
    func signInAndAddSiteReplaceEachOther() async throws {
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
        let adding = makeEnrollment()
        let signingIn = makeEnrollment()
        let addingAgain = makeEnrollment()
        let window = SiteEnrollmentWindow()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }
        let model = SiteSignInModel(
            host: "example.com",
            record: nil,
            start: .asksForAddress(host: "example.com"),
            proposalID: nil,
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )

        window.show(center: center, enrollment: adding, model: SiteFormModel())
        window.orderFront(nil)
        try await settle(window)
        #expect(window.content == .form(.adding))

        window.show(center: center, enrollment: signingIn, signIn: model)
        try await settle(window)
        #expect(window.enrollment === signingIn)
        #expect(window.content == .signIn(host: "example.com"))
        #expect(adding.isCancelled)
        #expect(adding.browser.webView.superview == nil)
        #expect(signingIn.browser.webView.window === window)

        window.show(center: center, enrollment: addingAgain, model: SiteFormModel())
        try await settle(window)
        #expect(window.enrollment === addingAgain)
        #expect(window.content == .form(.adding))
        #expect(signingIn.isCancelled)
        #expect(signingIn.browser.webView.superview == nil)
        #expect(addingAgain.browser.webView.window === window)
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
