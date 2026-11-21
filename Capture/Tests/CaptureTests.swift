import XCTest
@testable import Iterate

final class CaptureTests: XCTestCase {
    func testOnlyAnExplicitScreenPhraseCanSubmitTheCurrentFrame() {
        XCTAssertTrue(IterateScreenShare.isScreenQuestion("Hey Iterate, look at my screen. Which train is this?"))
        XCTAssertTrue(IterateScreenShare.isScreenQuestion("Read my screen"))
        XCTAssertTrue(IterateScreenShare.isScreenQuestion("What's on my screen?"))
        XCTAssertFalse(IterateScreenShare.isScreenQuestion("Don't look at my screen."))
        XCTAssertFalse(IterateScreenShare.isScreenQuestion("She said look at my screen."))
        XCTAssertFalse(IterateScreenShare.isScreenQuestion("Read my screensaver instructions."))
        XCTAssertFalse(IterateScreenShare.isScreenQuestion("What's happening today?"))
    }

    @MainActor
    func testAnIdleSessionCannotSendAScreen() async {
        let sharing = IterateScreenShare()
        do {
            _ = try await sharing.ask("Describe this.")
            XCTFail("A screen question needs a user-selected live sharing session.")
        } catch {
            XCTAssertEqual(sharing.phase, .idle)
            XCTAssertFalse(sharing.hasFrame)
            XCTAssertFalse(sharing.asking)
        }
    }

    func testBinaryAttachmentsAreBoundedBeforeUpload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.pdf")
        let bytes = Data("%PDF-local-test".utf8)
        try bytes.write(to: url)
        let file = try CapturedFile.read(url, suggestedName: "../sample.pdf", type: .pdf)
        XCTAssertEqual(file.name, "sample.pdf")
        XCTAssertEqual(file.contentType, "application/pdf")
        XCTAssertEqual(file.data, bytes)
        try Data(repeating: 0, count: IterateAttachment.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try CapturedFile.read(url, type: .pdf))
    }

    func testCaptureValidationMatchesTheServersTextAndFilenameRules() throws {
        let emoji = String(repeating: "🚲", count: 8_000)
        XCTAssertNoThrow(try CaptureDraft(text: emoji).validate())
        XCTAssertThrowsError(try CaptureDraft(text: emoji + "a").validate())
        let file = try CapturedFile(name: "C:\\folder\\Bike\nroute.pdf", contentType: "application/pdf", data: Data([1]))
        XCTAssertEqual(file.name, "Bike route.pdf")
    }

    func testACaptureDraftRetainsItsRetryIdentifier() throws {
        let original = CaptureDraft(text: "Local capture fixture", remember: true)
        try IterateCaptureInbox.save(original)
        defer { try? IterateCaptureInbox.remove(original.id) }
        let recovered = try IterateCaptureInbox.draft(original.id)
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.text, original.text)
        XCTAssertEqual(recovered.remember, original.remember)
        XCTAssertEqual(recovered.submissionID, original.submissionID)
        var edited = recovered
        edited.text += " after editing"
        XCTAssertNotEqual(edited.submissionID, original.submissionID)
    }
}
