import CryptoKit
import Foundation

/// A time-based one-time password key (RFC 6238) and the codes it produces.
///
/// The secret is the second factor for a site, so it never reaches a log: every textual
/// rendering, `dump` included, is a fixed placeholder.
struct TOTPKey: Equatable, Sendable {
    enum Algorithm: String, Sendable {
        case sha1, sha256, sha512
    }

    static let digitRange = 6...8
    static let periodRange = 15...120
    /// The shortest secret accepted: 80 bits, which is 16 base32 characters.
    static let minimumSecretBytes = 10
    static let maximumInputLength = 2048

    let secret: Data
    let digits: Int
    let period: Int
    let algorithm: Algorithm

    /// Nil when the secret is under `minimumSecretBytes` or `digits` or `period` is outside its
    /// range.
    init?(secret: Data, digits: Int, period: Int, algorithm: Algorithm) {
        guard secret.count >= Self.minimumSecretBytes,
              Self.digitRange.contains(digits),
              Self.periodRange.contains(period)
        else { return nil }
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// Accepts a bare base32 secret (case-insensitive; whitespace, dashes, and trailing `=`
    /// padding ignored) with the defaults of 6 digits, 30 seconds, and SHA-1, or an
    /// `otpauth://totp/…` URI carrying `secret` and optionally `digits`, `period`, and
    /// `algorithm`.
    static func parse(_ text: String) -> TOTPKey? {
        guard text.count <= maximumInputLength else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: "otpauth:", options: [.anchored, .caseInsensitive]) != nil {
            return parse(uri: trimmed)
        }
        return key(secret: trimmed, digits: nil, period: nil, algorithm: nil)
    }

    /// The code for the period containing `date`, zero-padded to `digits`.
    func code(at date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        // A date before 1970 or beyond any real clock reads as the nearest bound.
        let bounded = seconds.isFinite ? min(max(seconds, 0), 1e15) : 0
        let counter = UInt64(bounded) / UInt64(period)
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let truncated = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let code = String(truncated % modulus)
        return String(repeating: "0", count: digits - code.count) + code
    }

    // MARK: Parsing

    private static func parse(uri: String) -> TOTPKey? {
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp"
        else { return nil }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard ["secret", "digits", "period", "algorithm"].contains(name) else { continue }
            // Two values for one parameter leave it unclear which key the issuer meant.
            guard values[name] == nil, let value = item.value else { return nil }
            values[name] = value
        }
        guard let secret = values["secret"] else { return nil }

        var digits: Int?
        if let text = values["digits"] {
            guard let number = integer(text) else { return nil }
            digits = number
        }
        var period: Int?
        if let text = values["period"] {
            guard let number = integer(text) else { return nil }
            period = number
        }
        var algorithm: Algorithm?
        if let text = values["algorithm"] {
            guard let known = Algorithm(rawValue: text.lowercased()) else { return nil }
            algorithm = known
        }
        return key(secret: secret, digits: digits, period: period, algorithm: algorithm)
    }

    private static func key(
        secret text: String,
        digits: Int?,
        period: Int?,
        algorithm: Algorithm?
    ) -> TOTPKey? {
        guard let secret = decodeBase32(text) else { return nil }
        return TOTPKey(
            secret: secret,
            digits: digits ?? 6,
            period: period ?? 30,
            algorithm: algorithm ?? .sha1
        )
    }

    private static func integer(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 4, text.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return Int(text)
    }

    /// RFC 4648 base32. Whitespace and dashes are dropped and trailing `=` padding is
    /// ignored; any other character outside the alphabet rejects the input. Bits left over
    /// after the last whole byte are discarded.
    static func decodeBase32(_ text: String) -> Data? {
        var characters = text.unicodeScalars.filter { scalar in
            scalar != "-" && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while characters.last == "=" { characters.removeLast() }
        guard !characters.isEmpty else { return nil }

        var output = Data()
        var buffer: UInt32 = 0
        var bufferedBits = 0
        for scalar in characters {
            let value: UInt32
            switch scalar.value {
            case 0x41...0x5A: value = scalar.value - 0x41
            case 0x61...0x7A: value = scalar.value - 0x61
            case 0x32...0x37: value = scalar.value - 0x32 + 26
            default: return nil
            }
            buffer = (buffer << 5) | value
            bufferedBits += 5
            if bufferedBits >= 8 {
                bufferedBits -= 8
                output.append(UInt8((buffer >> UInt32(bufferedBits)) & 0xFF))
                buffer &= (1 << UInt32(bufferedBits)) - 1
            }
        }
        return output
    }
}

extension TOTPKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "TOTPKey(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
