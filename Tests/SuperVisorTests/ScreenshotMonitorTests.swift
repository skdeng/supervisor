import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import SuperVisor

/// Exercises the in-file capture marker on images generated to order, since a real capture
/// cannot be taken inside the test process.
@Suite("Screenshot capture comment")
struct ScreenshotMonitorTests {
    private func writeImage(
        as type: UTType,
        userComment: String?
    ) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "bin")

        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try #require(context?.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        )

        var properties: [CFString: Any] = [:]
        if let userComment {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: userComment
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("An image carrying the capture comment is recognized", arguments: [UTType.png, .jpeg])
    func markedImageIsRecognized(type: UTType) throws {
        let url = try writeImage(as: type, userComment: "Screenshot")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ScreenshotMonitor.carriesCaptureComment(url))
    }

    @Test("An image with no comment is not a capture")
    func plainImageIsRejected() throws {
        let url = try writeImage(as: .png, userComment: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!ScreenshotMonitor.carriesCaptureComment(url))
    }

    @Test("Only the exact capture comment counts")
    func otherCommentIsRejected() throws {
        let url = try writeImage(as: .png, userComment: "Screenshot of my cat")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!ScreenshotMonitor.carriesCaptureComment(url))
    }

    @Test("A file that is not an image is not a capture")
    func nonImageIsRejected() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-an-image-\(UUID().uuidString).png")
        try Data("plain text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!ScreenshotMonitor.carriesCaptureComment(url))
    }
}
