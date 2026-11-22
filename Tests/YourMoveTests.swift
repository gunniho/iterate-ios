import CryptoKit
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
        XCTAssertEqual(ApprovalReviewLink.keys.absoluteString,
                       Deployment.current.issuer.absoluteString + "/keys?next=/secrets/approvals")
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

    func testAHeldConfirmIsReadAsItsRequestOnceItsTextIsChecked() throws {
        let text = #"{"act":"itx.config.confirm","args":[{"request":"Create example.org/banana","ref":"banana-1"}],"at":"/","byLoadedCode":true}"#
        let digest = ApprovalStatement.hex(SHA256.hash(data: Data(text.utf8)))
        let link = ApprovalReviewLink.inbox.absoluteString + "?digest=" + digest
        let act = try XCTUnwrap(HeldAct(text: text, reviewURL: link))
        XCTAssertEqual(act.fields, [.init(label: "Request", value: "Create example.org/banana"), .init(label: "Asked in", value: "/")])
        XCTAssertNil(act.body)
        XCTAssertNil(HeldAct(text: text + " ", reviewURL: link))
    }

    @MainActor func testASignatureRequestOpensThePlatformSigningPageAlone() throws {
        let signing = Deployment.current.issuer.absoluteString + "/statements/sign?draft=l-KyUH_55bhkhpVoXGonaw"
        let row = """
            {"id":1000000004,"kind":"signature","title":"Create example.org/banana","recipients":[],
             "heldAt":"2026-11-22T12:15:00Z","reviewURL":"\(signing)"}
            """
        let request = try AssistantCenter.decoder().decode(PendingApproval.self, from: Data(row.utf8))
        XCTAssertEqual(request.kind, .signature)
        XCTAssertEqual(ApprovalReviewLink.item(request.reviewURL)?.absoluteString, signing)
        for link in [signing + "&next=https://example.org", signing + "/x", "https://example.org/statements/sign?draft=l-KyUH_55bhkhpVoXGonaw",
                     Deployment.current.issuer.absoluteString + "/statements/sign?draft=short"] {
            XCTAssertNil(ApprovalReviewLink.item(link), link)
        }
        XCTAssertEqual(ApprovalResolution(kind: .signature, outcome: .approved).detail, "Your signature is recorded.")
    }

    @MainActor func testAReviewedActResolvesOnceItLeavesTheInbox() throws {
        func inbox(_ items: String, _ decided: String? = nil) throws -> ApprovalInbox {
            let json = "{\"items\":[" + items + "]" + (decided.map { ",\"decided\":[" + $0 + "]" } ?? "") + "}"
            return try AssistantCenter.decoder().decode(ApprovalInbox.self, from: Data(json.utf8))
        }
        let held = """
            {"id":11,"kind":"email","title":"Schedule","recipients":[],"heldAt":"2026-11-20T10:15:00Z","reviewURL":""}
            """
        let page = ApprovalReview(url: ApprovalReviewLink.inbox, approval: 11)
        let action = ApprovalReview(url: ApprovalReviewLink.inbox, approval: 12, kind: .action)
        XCTAssertNil(try inbox(held).resolution(of: page))
        XCTAssertNil(try inbox("").resolution(of: ApprovalReview(url: ApprovalReviewLink.inbox)))
        // A server that reports no decisions still lets the sheet close.
        XCTAssertEqual(try inbox("").resolution(of: page), ApprovalResolution(kind: .email, outcome: nil))
        let ended = try inbox(held, """
            {"id":12,"kind":"action","title":"Update","recipients":[],"heldAt":"2026-11-20T10:15:00Z",
             "outcome":"rejected","decidedAt":"2026-11-20T10:16:00Z"}
            """)
        XCTAssertNil(ended.resolution(of: page))
        XCTAssertEqual(ended.resolution(of: action), ApprovalResolution(kind: .action, outcome: .rejected))
        XCTAssertEqual(ended.resolution(of: action)?.detail, "The action won’t run.")
    }

    func testAHeldActIsShownOnlyWhenItsTextHashesToTheDigestItNames() throws {
        let text = #"{"act":"email.send","from":"assistant@example.org","fromName":"Assistant","replyTo":null,"to":["a@example.org","b@example.org"],"cc":[],"subject":"Thursday","text":"See you at 9.","html":null,"inReplyTo":null,"references":null,"attachments":[]}"#
        let digest = ApprovalStatement.hex(SHA256.hash(data: Data(text.utf8)))
        let link = ApprovalReviewLink.inbox.absoluteString + "?digest=" + digest
        let act = try XCTUnwrap(HeldAct(text: text, reviewURL: link))
        XCTAssertEqual(act.digest, digest)
        XCTAssertTrue(act.isMail)
        XCTAssertEqual(act.fields.map(\.label), ["From", "To", "Subject"])
        XCTAssertEqual(act.fields[0].value, "Assistant <assistant@example.org>")
        XCTAssertEqual(act.fields[1].value, "a@example.org, b@example.org")
        XCTAssertEqual(act.body, "See you at 9.")
        // A relayed text that differs by one character is another act: it is never shown.
        XCTAssertNil(HeldAct(text: text.replacingOccurrences(of: "at 9", with: "at 8"), reviewURL: link))
        XCTAssertNil(HeldAct(text: text, reviewURL: "https://example.org/secrets/approvals?digest=" + digest))
        let call = #"{"act":"itx.calendar.send","args":[{"to":"x"}],"at":"/agents/assistant"}"#
        let callLink = ApprovalReviewLink.inbox.absoluteString + "?digest=" + ApprovalStatement.hex(SHA256.hash(data: Data(call.utf8)))
        let held = try XCTUnwrap(HeldAct(text: call, reviewURL: callLink))
        XCTAssertFalse(held.isMail)
        XCTAssertEqual(held.fields.map(\.value), ["itx.calendar.send", "/agents/assistant"])
    }

    func testADecisionIsAStatementThePlatformCanVerifyWithTheDeviceKey() throws {
        XCTAssertEqual(String(decoding: ApprovalStatement.signedBytes("{}"), as: UTF8.self),
                       "DSSEv1 38 application/vnd.iterate.statement+json 2 {}")
        let digest = String(repeating: "ab", count: 32)
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let text = try ApprovalStatement.text(.rejected(reason: "Wrong day"), digest: digest, at: at, nonce: Data([0xfb, 0xff]))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(fields["mind"] as? String, Deployment.current.controlHost)
        XCTAssertEqual(fields["path"] as? String, "/approvals")
        XCTAssertEqual(fields["type"] as? String, "events.iterate.com/approval/act-rejected")
        XCTAssertEqual(fields["about"] as? [String], [digest])
        XCTAssertEqual(fields["at"] as? Int64, 1_795_000_000_000)
        XCTAssertEqual(fields["expires"] as? Int64, 1_795_000_300_000)
        XCTAssertEqual(fields["nonce"] as? String, "-_8")
        XCTAssertEqual((fields["payload"] as? [String: String])?["reason"], "Wrong day")
        XCTAssertNil(try (JSONSerialization.jsonObject(with: Data(ApprovalStatement.text(.approved, digest: digest).utf8)) as? [String: Any])?["payload"])

        // A software key stands in for the Secure Enclave's: same curve, same signature form.
        let key = P256.Signing.PrivateKey()
        let signature = try key.signature(for: ApprovalStatement.signedBytes(text)).rawRepresentation
        XCTAssertEqual(signature.count, 64)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ApprovalStatement.envelope(statement: text, key: ApprovalStatement.keyID(key.publicKey), signature: signature)) as? [String: Any])
        XCTAssertEqual(envelope["statement"] as? String, text)
        let signed = try XCTUnwrap(envelope["signature"] as? [String: String])
        XCTAssertEqual(signed["format"], "p256")
        XCTAssertEqual(signed["key"], ApprovalStatement.base64url(Data(SHA256.hash(data: key.publicKey.derRepresentation))))
        XCTAssertEqual(signed["sig"], ApprovalStatement.base64url(signature))
        XCTAssertFalse(signed["key"]!.contains("=") || signed["key"]!.contains("+") || signed["key"]!.contains("/"))
        XCTAssertEqual(ApprovalStatement.endpoint.absoluteString, Deployment.current.issuer.absoluteString + "/secrets/approvals/statements")
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
            ApprovalReviewLink.item(value)
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

    func testStatementDraftIsSignedAsTheSignPageSignsIt() throws {
        // key order and the number's form are the platform's: the payload goes in as its own text
        let payload = #"{"request":"Create example.org/banana","ref":"r-1","n":1.50}"#
        let json = try JSONSerialization.data(withJSONObject: [
            "id": "draft-0001", "mind": Deployment.current.controlHost, "path": "/apps/pages", "type": "request/confirmed",
            "payload": payload, "signerEmail": "owner@example.org", "askedBy": ["kind": "code"], "askedFrom": "/agents/assistant",
        ])
        let draft = try XCTUnwrap(StatementDraft(json: json))
        XCTAssertEqual(draft.fields.map(\.label), ["N", "Ref", "Request"])
        XCTAssertEqual(draft.fields.last?.value, "Create example.org/banana")
        XCTAssertEqual(draft.askedBy, "Code running in /agents/assistant")
        XCTAssertEqual(draft.request, "Create example.org/banana")
        XCTAssertEqual(draft.details.map(\.label), ["N", "Ref"])
        let text = try draft.statement(at: Date(timeIntervalSince1970: 1_700_000_000), nonce: Data(repeating: 7, count: 16))
        XCTAssertEqual(text, #"{"mind":""# + Deployment.current.controlHost + #"","path":"/apps/pages","type":"request/confirmed","payload":"# + payload +
            #","at":1700000000000,"expires":1700000300000,"nonce":"BwcHBwcHBwcHBwcHBwcHBw"}"#)
        XCTAssertEqual(StatementDraft.challenge(text).count, 32)
        let press = try draft.press(statement: text, credentialID: Data([1, 2]), signature: Data([3]), authenticatorData: Data([4]), clientDataJSON: Data([5]))
        XCTAssertEqual(press.url, ApprovalReviewLink.statement)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(press.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["draft": "draft-0001", "statement": text, "credentialId": "AQI", "sig": "Aw", "authenticatorData": "BA", "clientDataJSON": "BQ"])
        // a statement for another mind, or a payload that is no object, is not shown for signing
        for change in [["mind": "iterate.example.com"], ["payload": "[1]"], ["path": "apps"]] {
            var other = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            other.merge(change) { $1 }
            XCTAssertNil(StatementDraft(json: try JSONSerialization.data(withJSONObject: other)))
        }
    }
}
