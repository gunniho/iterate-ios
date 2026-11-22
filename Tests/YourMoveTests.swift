import XCTest
@testable import Iterate

final class YourMoveTests: XCTestCase {
    @MainActor func testWhatAMemberLastReadIsRecalledOnlyForTheirPairing() {
        ReviewLists.forget()
        ReviewLists.keep(["Schedule"], as: "approvals", for: "first")
        XCTAssertEqual(ReviewLists.recall("approvals", for: "first") as [String]?, ["Schedule"])
        XCTAssertNil(ReviewLists.recall("approvals", for: "second") as [String]?)
        XCTAssertNil(ReviewLists.recall("your-move", for: "first") as [String]?)
        ReviewLists.keep(nil as [String]?, as: "approvals", for: "first")
        XCTAssertNil(ReviewLists.recall("approvals", for: "first") as [String]?)
        ReviewLists.keep(["Schedule"], as: "approvals", for: "first")
        ReviewLists.forget()
        XCTAssertNil(ReviewLists.recall("approvals", for: "first") as [String]?)
    }

    @MainActor func testApprovalsInboxDecodesBothKindsAndUsesThePlatformReviewPage() throws {
        let page = ApprovalReviewLink.inbox.absoluteString
        XCTAssertEqual(page, Deployment.current.issuer.absoluteString + "/secrets/approvals")
        let digest = String(repeating: "3e", count: 32)
        let link = page + "?digest=" + digest
        let rows = """
            [{"id":11,"kind":"email","title":"Schedule","recipients":["reader@example.org"],
              "heldAt":"2026-11-20T10:15:00Z","reviewURL":"\(link)"},
             {"id":12,"kind":"action","title":"Update meeting","recipients":[],
              "heldAt":"2026-11-20T10:15:00.250Z","reviewURL":"\(link)"}]
            """
        let approvals = try AssistantCenter.decoder().decode([PendingApproval].self, from: Data(rows.utf8))
        XCTAssertEqual(approvals.map(\.kind), [.email, .action])
        XCTAssertEqual(approvals.first?.recipients, ["reader@example.org"])
        XCTAssertEqual(approvals[1].heldAt.timeIntervalSince(approvals[0].heldAt), 0.25, accuracy: 0.001)
        XCTAssertEqual(ApprovalReviewLink.item(approvals[0].reviewURL)?.absoluteString, link)
    }

    func testTruncatedQuestionRequiresItsFullCurrentRevisionInUTF16() throws {
        let id = UUID()
        let stamp = "2026-11-21T12:03:55.327Z"
        let day = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)
        let text = "A 🚆 or a bus?"
        let question = YourMoveQuestion(id: id, title: "Travel", question: "A 🚆", updatedAt: stamp,
                                        responseLength: text.utf16.count)
        func run(_ status: RunStatus = .needsInput, date: Date? = nil, response: String = text) -> IterateRun {
            IterateRun(id: id, kind: "ask", title: "Travel", prompt: "", status: status, response: response,
                      createdAt: day, updatedAt: date ?? day, responseLength: text.utf16.count)
        }

        XCTAssertNil(question.completePreview)
        XCTAssertEqual(try question.completeText(from: run()), text)
        XCTAssertThrowsError(try question.completeText(from: run(.completed)))
        XCTAssertThrowsError(try question.completeText(from: run(date: day.addingTimeInterval(0.001))))
        XCTAssertThrowsError(try question.completeText(from: run(response: "A 🚆")))
        XCTAssertEqual(YourMoveQuestion(id: id, title: "", question: text, updatedAt: stamp,
                                        responseLength: text.utf16.count).completePreview, text)
    }

    func testOnlyCanonicalMailApprovalLinkCanOpenForReview() {
        let digest = String(repeating: "a18f", count: 16)
        let page = Deployment.current.issuer.absoluteString + "/secrets/approvals"
        let query = "?digest=" + digest
        let link = page + query
        func review(_ value: String) -> URL? {
            YourMoveApproval(id: 17, subject: "Meeting", to: [], reviewURL: value).trustedReviewURL
        }

        XCTAssertEqual(review(link)?.absoluteString, link)
        for invalid in [
            "https://" + Deployment.current.controlHost + ".example/secrets/approvals" + query,
            "https://" + Deployment.current.controlHost + "@example.org/secrets/approvals" + query,
            link.replacingOccurrences(of: "https:", with: "http:"),
            page, page + "/other" + query, page + "?digest=" + digest.uppercased(),
            String(link.dropLast()), link + "&digest=" + digest, link + "&next=/", link + "#fragment",
        ] {
            XCTAssertNil(review(invalid), invalid)
        }
    }
}
