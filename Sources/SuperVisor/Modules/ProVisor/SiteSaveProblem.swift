import Foundation

/// Why opening a site's page, signing in to it, or saving it did not go through, each shown as
/// a fixed sentence. The Add Site form (`SiteFormModel`) and the sign-in window
/// (`SiteSignInModel`) share it.
enum SiteSaveProblem: Equatable {
    case invalidAddress
    case pageDidNotLoad
    case notSignedIn
    case invalidGrant
    case passwordNotConfirmed
    case passwordNotFilled
    case signInNotSeen
    /// The page cannot be told from what a visitor who is not signed in sees.
    case pageLooksPublic
    case notSaved
    /// The site a session would be saved as keeps a saved password, which the save would discard.
    case hasSavedPassword
    /// A hidden read of the start page does not show the site's stored sign-in signed in, so
    /// the person's sign-in is not recorded.
    case signInNotConfirmed

    var message: String {
        switch self {
        case .invalidAddress:
            "Enter the https address of the site's sign-in page."
        case .pageDidNotLoad:
            "The sign-in page did not finish loading. Check the address and try again."
        case .notSignedIn:
            "Finish signing in on the page first, then save."
        case .invalidGrant:
            "This sign-in could not be recorded. Try again from the sign-in page."
        case .passwordNotConfirmed:
            "SuperVisor can't tell which password worked. Type the working password in the form here, then press Sign In again."
        case .passwordNotFilled:
            "SuperVisor didn't fill the sign-in itself, so it couldn't record it. Press Sign In and let it fill the page."
        case .signInNotSeen:
            "SuperVisor didn't see a sign-in here. If the page shows your account, save it anyway. If it doesn't, sign in on the page first."
        case .pageLooksPublic:
            "SuperVisor can't tell this page from what a visitor sees, so it wouldn't notice if the site signed you out. Open a page only you can see, such as your account page, then save. Or save this page anyway."
        case .notSaved:
            "The site could not be saved to the Keychain."
        case .hasSavedPassword:
            "This site has a saved password. Use Sign In Again in Manage Sites to sign in to it."
        case .signInNotConfirmed:
            "SuperVisor couldn't confirm you're signed in. Finish signing in on the page, then press Done."
        }
    }

    /// The sentence in the sign-in window, whose button is Done and where nothing is typed into
    /// a form of the app's own.
    var signInWindowMessage: String {
        switch self {
        case .notSignedIn:
            "Finish signing in on the page first, then press Done."
        case .signInNotSeen:
            "SuperVisor didn't see a sign-in here. If the page shows your account, press Save Anyway. If it doesn't, sign in on the page first."
        case .pageLooksPublic:
            "SuperVisor can't tell this page from what a visitor sees, so it wouldn't notice if the site signed you out. Open a page only you can see, such as your account page, then press Done. Or press Save Anyway."
        case .pageDidNotLoad:
            "The page did not finish loading."
        case .invalidAddress, .invalidGrant, .passwordNotConfirmed, .passwordNotFilled, .notSaved,
             .hasSavedPassword, .signInNotConfirmed:
            message
        }
    }

    /// The refusal a person who can see the page may answer by saving on their own word, for a
    /// problem that is one; nil for any other.
    var confirmation: SiteEnrollment.Failure? {
        switch self {
        case .signInNotSeen: .signInNotSeen
        case .pageLooksPublic: .pageLooksPublic
        default: nil
        }
    }

    /// Whether the person may answer the problem by saving on their own word.
    var allowsSavingAnyway: Bool {
        confirmation != nil
    }

    /// A problem a new sign-in, not another Save, puts right.
    var needsNewSignIn: Bool {
        self == .passwordNotConfirmed || self == .passwordNotFilled
    }

    static func ofSignIn(_ error: any Error) -> SiteSaveProblem {
        (error as? SiteEnrollment.Failure) == .invalidAddress ? .invalidAddress : .pageDidNotLoad
    }

    /// Nil for an enrollment cancelled while it finished: the window is gone.
    static func ofFinish(_ error: any Error) -> SiteSaveProblem? {
        switch error as? SiteEnrollment.Failure {
        case .cancelled?: nil
        case .invalidGrant?: .invalidGrant
        case .passwordNotConfirmed?: .passwordNotConfirmed
        case .passwordNotFilled?: .passwordNotFilled
        case .signInNotSeen?: .signInNotSeen
        case .pageLooksPublic?: .pageLooksPublic
        case .invalidAddress?, .notSignedIn?, nil: .notSignedIn
        }
    }
}
