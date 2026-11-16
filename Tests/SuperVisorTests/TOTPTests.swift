import Foundation
import Testing

@testable import SuperVisor

@Suite("Authenticator codes")
struct TOTPTests {
    /// The shared secrets of RFC 6238 Appendix B: the ASCII digits 1 to 0 repeated out to the
    /// length each hash function takes.
    private static func rfcSecret(_ algorithm: TOTPKey.Algorithm) -> Data {
        let length: Int
        switch algorithm {
        case .sha1: length = 20
        case .sha256: length = 32
        case .sha512: length = 64
        }
        let digits = Array("1234567890".utf8)
        return Data((0..<length).map { digits[$0 % digits.count] })
    }

    struct Vector: Sendable, CustomTestStringConvertible {
        let algorithm: TOTPKey.Algorithm
        let time: TimeInterval
        let code: String
        var testDescription: String { "\(algorithm.rawValue) at \(Int(time))" }
    }

    static let vectors: [Vector] = {
        let times: [TimeInterval] = [
            59, 1_111_111_109, 1_111_111_111, 1_234_567_890, 2_000_000_000, 20_000_000_000,
        ]
        let codes: [TOTPKey.Algorithm: [String]] = [
            .sha1: ["94287082", "07081804", "14050471", "89005924", "69279037", "65353130"],
            .sha256: ["46119246", "68084774", "67062674", "91819424", "90698825", "77737706"],
            .sha512: ["90693936", "25091201", "99943326", "93441116", "38618901", "47863826"],
        ]
        return [TOTPKey.Algorithm.sha1, .sha256, .sha512].flatMap { algorithm in
            zip(times, codes[algorithm]!).map {
                Vector(algorithm: algorithm, time: $0, code: $1)
            }
        }
    }()

    private static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    /// 20 bytes: the RFC's SHA-1 secret.
    private static let sampleSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    @Test("The test encoder reproduces the RFC's SHA-1 secret")
    func encoderMatchesKnownEncoding() {
        #expect(Self.base32(Self.rfcSecret(.sha1)) == Self.sampleSecret)
    }

    @Test("RFC 6238 Appendix B vectors, built directly", arguments: vectors)
    func rfcVectors(_ vector: Vector) throws {
        let key = try #require(TOTPKey(
            secret: Self.rfcSecret(vector.algorithm),
            digits: 8,
            period: 30,
            algorithm: vector.algorithm
        ))

        #expect(key.code(at: Date(timeIntervalSince1970: vector.time)) == vector.code)
    }

    @Test("RFC 6238 Appendix B vectors, through an otpauth URI", arguments: vectors)
    func rfcVectorsFromURI(_ vector: Vector) throws {
        let secret = Self.base32(Self.rfcSecret(vector.algorithm))
        let uri = "otpauth://totp/Example?secret=\(secret)&digits=8"
            + "&algorithm=\(vector.algorithm.rawValue.uppercased())"
        let key = try #require(TOTPKey.parse(uri))

        #expect(key.code(at: Date(timeIntervalSince1970: vector.time)) == vector.code)
    }

    @Test("A bare secret means 6 digits, 30 seconds, and SHA-1")
    func defaults() throws {
        let key = try #require(TOTPKey.parse(Self.sampleSecret))

        #expect(key.digits == 6)
        #expect(key.period == 30)
        #expect(key.algorithm == .sha1)
        #expect(key.secret == Self.rfcSecret(.sha1))
        // The 8-digit vector 94287082 at t = 59, cut to its last six digits.
        #expect(key.code(at: Date(timeIntervalSince1970: 59)) == "287082")
        // 07081804 keeps its leading zero when cut to 6 digits: 081804.
        #expect(key.code(at: Date(timeIntervalSince1970: 1_111_111_109)) == "081804")
    }

    @Test("The code changes at each period boundary and not within one")
    func periodBoundary() throws {
        let key = try #require(TOTPKey.parse(Self.sampleSecret))
        let start = Date(timeIntervalSince1970: 1_111_111_110)

        #expect(key.code(at: start) == key.code(at: start.addingTimeInterval(29)))
        #expect(key.code(at: start) != key.code(at: start.addingTimeInterval(30)))
    }

    @Test("A date before 1970 reads as the first period")
    func dateBeforeEpoch() throws {
        let key = try #require(TOTPKey.parse(Self.sampleSecret))

        #expect(key.code(at: Date(timeIntervalSince1970: -500)) == key.code(at: Date(timeIntervalSince1970: 0)))
        #expect(key.code(at: .distantFuture).count == 6)
    }

    @Test(
        "Base32 is read case-insensitively, ignoring spaces, dashes, and padding",
        arguments: [
            "gezdgnbvgy3tqojqgezdgnbvgy3tqojq",
            "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ",
            "GEZD-GNBV-GY3T-QOJQ-GEZD-GNBV-GY3T-QOJQ",
            "  GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ\n",
            "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ====",
            "gezd gnbv-GY3T qojq GEZDGNBVGY3TQOJQ==",
        ]
    )
    func tolerantBase32(_ text: String) {
        #expect(TOTPKey.parse(text)?.secret == Self.rfcSecret(.sha1))
    }

    @Test(
        "Anything that is not a usable key is refused",
        arguments: [
            "",
            "   \n",
            "GEZDGNBVGY3TQOJ1GEZDGNBVGY3TQOJQ",
            "GEZDGNBVGY3TQOJ0GEZDGNBVGY3TQOJQ",
            "GEZDGNBVGY3TQOJ8GEZDGNBVGY3TQOJQ",
            "GEZDGNBVGY3TQOJ!GEZDGNBVGY3TQOJQ",
            "GEZDGNBVGY3TQOJQ=GEZDGNBVGY3TQOJQ",
            "====",
            // 15 characters hold 75 bits, which is 9 bytes.
            "GEZDGNBVGY3TQOJ",
            "GEZDGNBV",
            "otpauth://hotp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=1",
            "otpauth://totp/Example",
            "otpauth://totp/Example?issuer=Example",
            "otpauth://totp/Example?secret=GEZDGNBV",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=5",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=9",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=six",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=-6",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=14",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=121",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=0",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&algorithm=MD5",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&algorithm=",
            "otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            "otpauth://motp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
        ]
    )
    func rejections(_ text: String) {
        #expect(TOTPKey.parse(text) == nil)
    }

    @Test("Input too large to be a key is refused")
    func oversizedInput() {
        let secret = String(repeating: "A", count: TOTPKey.maximumInputLength + 1)

        #expect(TOTPKey.parse(secret) == nil)
    }

    @Test("The bounds of digits, period, and secret length are accepted")
    func boundsAreInclusive() {
        let secret = "GEZDGNBVGY3TQOJQ"
        // 16 characters hold exactly 10 bytes.
        #expect(TOTPKey.parse(secret)?.secret.count == 10)
        for (digits, period) in [(6, 15), (8, 120)] {
            let key = TOTPKey.parse("otpauth://totp/x?secret=\(secret)&digits=\(digits)&period=\(period)")
            #expect(key?.digits == digits)
            #expect(key?.period == period)
        }
    }

    @Test("Values outside the accepted ranges cannot make a key")
    func initializerEnforcesBounds() {
        let secret = Data(repeating: 0x41, count: TOTPKey.minimumSecretBytes)
        let short = Data(repeating: 0x41, count: TOTPKey.minimumSecretBytes - 1)

        #expect(TOTPKey(secret: secret, digits: 6, period: 30, algorithm: .sha1) != nil)
        #expect(TOTPKey(secret: secret, digits: 6, period: 15, algorithm: .sha256) != nil)
        #expect(TOTPKey(secret: secret, digits: 8, period: 120, algorithm: .sha512) != nil)

        #expect(TOTPKey(secret: short, digits: 6, period: 30, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: Data(), digits: 6, period: 30, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: 5, period: 30, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: 9, period: 30, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: 0, period: 30, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: -6, period: 30, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: 6, period: 14, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: 6, period: 121, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: 6, period: 0, algorithm: .sha1) == nil)
        #expect(TOTPKey(secret: secret, digits: 6, period: -30, algorithm: .sha1) == nil)
    }

    @Test("An otpauth URI round-trips every parameter and ignores the label and issuer")
    func uriRoundTrip() throws {
        let original = try #require(TOTPKey(
            secret: Self.rfcSecret(.sha256),
            digits: 7,
            period: 45,
            algorithm: .sha256
        ))
        let secret = Self.base32(original.secret)
        let uri = "otpauth://totp/Example%20Co:alice@example.com?secret=\(secret.lowercased())"
            + "&issuer=Example%20Co&algorithm=SHA256&digits=7&period=45"

        #expect(TOTPKey.parse(uri) == original)
        #expect(TOTPKey.parse("OTPAUTH://TOTP/x?SECRET=\(secret)&DIGITS=7&PERIOD=45&ALGORITHM=sha256") == original)
        #expect(TOTPKey.parse("  \(uri)\n") == original)
    }

    @Test("A key prints as a fixed placeholder however it is rendered")
    func redaction() throws {
        let key = try #require(TOTPKey.parse(Self.sampleSecret))
        var dumped = ""
        dump(key, to: &dumped)
        let renderings = [
            key.description,
            key.debugDescription,
            "\(key)",
            String(describing: key),
            String(reflecting: key),
            dumped,
            String(describing: [key]),
            String(describing: Optional(key)),
        ]

        for rendering in renderings {
            #expect(rendering.contains("redacted"))
            #expect(!rendering.contains(Self.sampleSecret))
            #expect(!rendering.contains("1234567890"))
        }
    }
}
