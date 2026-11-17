import Foundation
import Testing

@testable import SuperVisor

@Suite("Site navigation policy")
struct SiteNavigationPolicyTests {
    private let policy = SiteNavigationPolicy(browseHosts: ["example.com", "www.example.com"])

    private func allows(_ text: String, _ policy: SiteNavigationPolicy? = nil) -> Bool {
        guard let url = URL(string: text) else { return false }
        return (policy ?? self.policy).allowsMainFrame(url)
    }

    // MARK: Main frame

    @Test(
        "An https address on a listed host is allowed",
        arguments: [
            "https://example.com/",
            "https://example.com",
            "https://www.example.com/account?tab=cards#top",
            "HTTPS://EXAMPLE.COM/Path",
            "https://example.com/a/b/c.html",
        ]
    )
    func allowedMainFrame(_ address: String) {
        #expect(allows(address))
    }

    @Test(
        "Anything else is refused as a main-frame load",
        arguments: [
            "https://example.com.evil.test/",
            "https://evilexample.com/",
            "https://example.com.evil.test/https://example.com/",
            "https://evil.test/?u=https://example.com/",
            "https://sub.example.com/",
            "https://a.www.example.com/",
            "https://example.org/",
            "https://example.com./",
            "http://example.com/",
            "https://example.com:8443/",
            "https://example.com:443/",
            "https://user@example.com/",
            "https://user:secret@example.com/",
            "https://@example.com/",
            "https://example.com@evil.test/",
            "https://evil.test@example.com/",
            "javascript:alert(1)",
            "data:text/html,<p>x</p>",
            "blob:https://example.com/0b1f4c2a-4a6e-4f6f-8f0b-0a7c1e2d3f4a",
            "file:///etc/hosts",
            "ftp://example.com/",
            "about:blank",
            "https:///path",
            "https://127.0.0.1/",
            "//example.com/",
            "/relative",
        ]
    )
    func refusedMainFrame(_ address: String) {
        #expect(!allows(address))
    }

    @Test("An empty list allows nothing, and the enrollment policy allows any plain https host")
    func emptyAndAnyHost() {
        let none = SiteNavigationPolicy(browseHosts: [])
        #expect(!allows("https://example.com/", none))

        let any = SiteNavigationPolicy.anyHTTPSHost
        #expect(allows("https://example.com/login", any))
        #expect(allows("https://auth.some-bank.co.uk/", any))
        #expect(!allows("http://example.com/", any))
        #expect(!allows("https://example.com:8443/", any))
        #expect(!allows("https://user@example.com/", any))
        #expect(!allows("https://127.0.0.1/", any))
        #expect(!allows("https://[::1]/", any))
        #expect(!allows("https://localhost/", any))
        #expect(!allows("javascript:alert(1)", any))
        #expect(!allows("file:///etc/hosts", any))
    }

    // MARK: Subframes

    @Test(
        "A subframe may be https on any host or an about: blank",
        arguments: [
            "https://example.com/frame",
            "https://www.google.com/recaptcha/api2/anchor",
            "https://anything.test/",
            "HTTPS://Anything.test/",
            "about:blank",
            "about:srcdoc",
        ]
    )
    func allowedSubframe(_ address: String) throws {
        #expect(policy.allowsSubframe(try #require(URL(string: address))))
    }

    @Test(
        "A subframe may not be anything else",
        arguments: [
            "http://example.com/frame",
            "javascript:alert(1)",
            "data:text/html,x",
            "blob:https://example.com/abc",
            "file:///etc/hosts",
            "about:config",
            "about:blank#fragment",
            "ftp://example.com/",
            "https:///nohost",
        ]
    )
    func refusedSubframe(_ address: String) {
        #expect(URL(string: address).map(policy.allowsSubframe) != true)
    }

    // MARK: Links

    private func offers(_ text: String, _ address: String) -> Bool {
        guard let url = URL(string: address) else { return false }
        return policy.offers(linkText: text, url: url)
    }

    @Test(
        "Ordinary links are offered, and exact words leave look-alikes alone",
        arguments: [
            ("Payment methods", "https://example.com/payment-methods"),
            ("Statements", "https://example.com/statements?year=2026"),
            ("Cards", "https://www.example.com/cards"),
            ("Account activity", "https://example.com/activity"),
            ("Paypal", "https://example.com/paypal"),
            ("Sender details", "https://example.com/senders"),
            ("Applying for a card", "https://example.com/applying"),
            ("Transfers history", "https://example.com/transfers"),
            ("Removal policy", "https://example.com/removal"),
            ("Cancelled orders", "https://example.com/cancelled"),
            ("", "https://example.com/"),
            ("Home", "https://example.com/#top"),
            ("Payments", "https://example.com/billing/payment-methods"),
            ("Payment", "https://example.com/payments"),
            ("Applications", "https://example.com/applications"),
            ("Sender", "https://example.com/sender"),
            ("Statements for 2026", "https://example.com/statements/2026"),
            ("Account overview", "https://example.com/account/overview"),
            ("Closed accounts", "https://example.com/accounts/closed"),
            ("Unsubscribed lists", "https://example.com/lists"),
        ]
    )
    func offered(_ text: String, _ address: String) {
        #expect(offers(text, address))
    }

    @Test(
        "A link whose text reads as a session or account action is refused",
        arguments: [
            "Sign out", "Signout", "Log out", "Logout", "Sign off", "SIGN-OUT", "(Log out)",
            "Delete card", "Remove", "Cancel", "Close account", "Deactivate", "Enroll now",
            "Enrol", "Confirm", "Pay now", "Pay", "Transfer funds", "Send money", "Unsubscribe",
            "Submit", "Redeem points", "Apply now", "Your card - Pay-now", "Click here to delete",
            "signoff", "logoff", "Log off", "LogOff", "Cancellation", "Unenroll", "Unenrol",
            "Terminate", "Revoke access", "PayPal", "Close account", "Account close",
            "doLogout", "cancelOrder", "payNow", "Pay2Day", "deleteAccount", "LogOut",
        ]
    )
    func refusedText(_ text: String) {
        #expect(!offers(text, "https://example.com/neutral"))
    }

    @Test(
        "A link whose address names a session or account action is refused",
        arguments: [
            "https://example.com/logout",
            "https://example.com/LogOut",
            "https://example.com/signout",
            "https://example.com/signoff",
            "https://example.com/account/delete",
            "https://example.com/a?action=remove",
            "https://example.com/cancel/123",
            "https://example.com/deactivate",
            "https://example.com/enroll",
            "https://example.com/enrol",
            "https://example.com/confirm",
            "https://example.com/pay",
            "https://example.com/cards/pay-bill",
            "https://example.com/transfer",
            "https://example.com/unsubscribe",
            "https://example.com/redeem",
            "https://example.com/sign-out",
            "https://example.com/log_out",
            "https://example.com/sign.off",
            "https://example.com/close-account",
            "https://example.com/%6Cogout",
            "https://example.com/app#/logout",
            "https://example.com/x?next=/logout",
            "https://example.com/x?return=%2Fsignout",
            "https://example.com/orders/cancelOrder",
            "https://example.com/deleteAccount",
            "https://example.com/doLogout",
            "https://example.com/payNow",
            "https://example.com/Account/LogOff",
            "https://example.com/account/close",
            "https://example.com/close/account",
            "https://example.com/logoff",
            "https://example.com/cancellation",
            "https://example.com/unenroll",
            "https://example.com/unenrol",
            "https://example.com/terminate",
            "https://example.com/revoke",
            "https://example.com/send",
            "https://example.com/submit",
            "https://example.com/apply",
            "https://example.com/x?do=cancel2",
            "https://example.com/pay2",
            "https://example.com/log-off",
            "https://example.com/Sign_Off",
        ]
    )
    func refusedAddress(_ address: String) {
        #expect(!offers("Neutral", address))
    }

    @Test(
        "Words split at punctuation, at a lowercase letter meeting an uppercase one, and between letters and digits",
        arguments: [
            ("cancelOrder", ["cancel", "order"]),
            ("/orders/cancelOrder", ["orders", "cancel", "order"]),
            ("doLogout", ["do", "logout"]),
            ("Payment methods", ["payment", "methods"]),
            ("pay2day", ["pay", "2", "day"]),
            ("statements/2026", ["statements", "2026"]),
            ("LOGOUT", ["logout"]),
            ("LogOff", ["log", "off"]),
            ("sign-out_now", ["sign", "out", "now"]),
            ("", []),
            ("///--", []),
        ]
    )
    func wordSplitting(_ text: String, _ expected: [String]) {
        #expect(SiteNavigationPolicy.words(in: text) == expected)
    }

    @Test("A letter and a digit that touch stay one word when asked")
    func wordsKeepingDigits() {
        #expect(SiteNavigationPolicy.words(in: "2fa_token", splittingDigits: false) == ["2fa", "token"])
        #expect(SiteNavigationPolicy.words(in: "2fa_token") == ["2", "fa", "token"])
    }

    @Test("A link off the listed hosts or off https is never offered")
    func offersNeedAnAllowedAddress() {
        #expect(!offers("Cards", "https://evil.test/cards"))
        #expect(!offers("Cards", "https://example.com.evil.test/cards"))
        #expect(!offers("Cards", "http://example.com/cards"))
        #expect(!offers("Cards", "https://example.com:8443/cards"))
        #expect(!offers("Cards", "javascript:void(0)"))
        #expect(!offers("Cards", "mailto:help@example.com"))
        #expect(!offers("Cards", "/cards"))
    }
}
