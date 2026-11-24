import XCTest
@testable import Iterate

final class AttentionActivityTests: XCTestCase {
    private typealias Content = IterateAttentionAttributes.ContentState

    func testThePushedContentIsReadAsCountsAndListsTheMostPressingKindFirst() throws {
        // The content of a push, as `attention.js` writes it.
        let pushed = #"{"approvals":2,"signatures":1,"questions":3,"urgent":1,"since":1800000000}"#
        let state = try JSONDecoder().decode(Content.self, from: Data(pushed.utf8))
        XCTAssertEqual(state, Content(approvals: 2, signatures: 1, questions: 3, urgent: 1, since: 1_800_000_000))
        XCTAssertEqual(state.total, 7)
        XCTAssertEqual(state.kinds, [.urgent, .approvals, .signatures, .questions])
        XCTAssertEqual(state.leading, .urgent)
        XCTAssertEqual(state.line, "1 urgent · 2 to approve · 1 to sign · 3 questions")
        XCTAssertEqual(state.spoken, "Waiting for you in Iterate: 1 urgent, 2 to approve, 1 to sign, 3 questions")
        XCTAssertEqual(state.waitingSince, Date(timeIntervalSince1970: 1_800_000_000))
        // What the phone sends itself is read back the same.
        XCTAssertEqual(try JSONDecoder().decode(Content.self, from: JSONEncoder().encode(state)), state)

        let one = Content(questions: 1)
        XCTAssertEqual(one.line, "1 question")
        XCTAssertEqual(one.leading, .questions)
        XCTAssertNil(one.waitingSince)
    }

    func testTheFirstThingsAreReadInTheirOwnWordsAndTheRestAreCounted() throws {
        // The content of a push, as `attention.js` writes it.
        let pushed = """
            {"approvals":2,"signatures":1,"questions":0,"urgent":1,"since":1800000000,"items":[
              {"kind":"urgent","text":"Pay the electrician today"},
              {"kind":"approval","text":"Email to ada@example.org: Re: Friday schedule"},
              {"kind":"signature","text":"Confirm the new page"}]}
            """
        let state = try JSONDecoder().decode(Content.self, from: Data(pushed.utf8))
        XCTAssertEqual(state.items.map(\.text), ["Pay the electrician today", "Email to ada@example.org: Re: Friday schedule", "Confirm the new page"])
        XCTAssertEqual(state.items.map(\.attentionKind), [.urgent, .approvals, .signatures])
        XCTAssertEqual(state.unnamed, 1)
        XCTAssertEqual(state.spoken, "Waiting for you in Iterate: Pay the electrician today. Email to ada@example.org: Re: Friday schedule. Confirm the new page. And 1 more.")
        XCTAssertEqual(try JSONDecoder().decode(Content.self, from: JSONEncoder().encode(state)), state)

        // The first thing's kind leads the compact views, also where a kind listed earlier waits too.
        let asked = Content(urgent: 1, since: 0, items: [.init(kind: "question", text: "Which day suits you?")])
        XCTAssertEqual(asked.leading, .questions)
        XCTAssertEqual(asked.unnamed, 0)

        // Never more lines than things that wait or than the activity has room for, no empty line,
        // and no line of a kind this build does not know.
        let odd = Content(approvals: 5, items: [
            .init(kind: "approval", text: "  One  "), .init(kind: "later", text: "A newer kind"), .init(kind: "approval", text: " "),
            .init(kind: "approval", text: "Two"), .init(kind: "approval", text: "Three"), .init(kind: "approval", text: "Four"),
        ])
        XCTAssertEqual(odd.items.map(\.text), ["One", "Two", "Three"])
        XCTAssertEqual(odd.unnamed, 2)
        XCTAssertEqual(Content(approvals: 1, items: [.init(kind: "approval", text: "One"), .init(kind: "approval", text: "Two")]).items.count, 1)
        XCTAssertEqual(Content(items: [.init(kind: "approval", text: "One")]).items, [])
        // A change of words alone is a change of what the activity shows.
        XCTAssertEqual(AttentionActivityStep.from(shown: Content(urgent: 1, items: [.init(kind: "urgent", text: "One")]),
                                                  to: Content(urgent: 1, items: [.init(kind: "urgent", text: "Two")]), enabled: true), .update)
    }

    func testACountThatIsMissingOrNoCountIsReadAsNothingWaiting() throws {
        let odd = #"{"approvals":-4,"signatures":"two","urgent":5000,"later":true,"items":"none"}"#
        let state = try JSONDecoder().decode(Content.self, from: Data(odd.utf8))
        XCTAssertEqual(state, Content(urgent: 999))
        XCTAssertEqual(state.since, 0)
        // Counts with no words are told as counts.
        XCTAssertEqual(state.spoken, "Waiting for you in Iterate: 999 urgent")
        let none = try JSONDecoder().decode(Content.self, from: Data("{}".utf8))
        XCTAssertEqual(none.total, 0)
        XCTAssertNil(none.leading)
        XCTAssertEqual(none.line, "")
        XCTAssertEqual(none.spoken, "Nothing needs you in Iterate")
    }

    func testTheActivityStartsFollowsAndEndsWithWhatWaits() {
        let two = Content(approvals: 2), three = Content(approvals: 2, urgent: 1), none = Content()
        XCTAssertEqual(AttentionActivityStep.from(shown: nil, to: two, enabled: true), .start)
        XCTAssertEqual(AttentionActivityStep.from(shown: two, to: two, enabled: true), .none)
        XCTAssertEqual(AttentionActivityStep.from(shown: two, to: three, enabled: true), .update)
        XCTAssertEqual(AttentionActivityStep.from(shown: three, to: none, enabled: true), .end)
        XCTAssertEqual(AttentionActivityStep.from(shown: nil, to: none, enabled: true), .none)
        // A member who turned Live Activities off is shown none, and one that is up is taken away.
        XCTAssertEqual(AttentionActivityStep.from(shown: nil, to: two, enabled: false), .none)
        XCTAssertEqual(AttentionActivityStep.from(shown: two, to: three, enabled: false), .end)
        // The counts a member swiped away do not come back. A change does.
        XCTAssertEqual(AttentionActivityStep.from(shown: nil, to: two, enabled: true, dismissed: two), .none)
        XCTAssertEqual(AttentionActivityStep.from(shown: nil, to: three, enabled: true, dismissed: two), .start)
    }

    func testWhatNeedsTheMemberIsReadWithItsUrgentTodosAndOnlyASecureListAddress() throws {
        let answer = """
            {"approvals":1,"signatures":0,"questions":1,"urgent":1,"since":1800000000,"until":1800000900000,
             "urgentTodos":[{"id":7,"text":"Pay the electrician","project":"House"}],"todoList":"https://todo.example.org/"}
            """
        let summary = try JSONDecoder().decode(AttentionSummary.self, from: Data(answer.utf8))
        XCTAssertEqual(summary.state, Content(approvals: 1, questions: 1, urgent: 1, since: 1_800_000_000))
        XCTAssertEqual(summary.until, Date(timeIntervalSince1970: 1_800_000_900))
        XCTAssertEqual(summary.urgentTodos, [.init(id: 7, text: "Pay the electrician", project: "House")])
        XCTAssertEqual(summary.todoList?.absoluteString, "https://todo.example.org/")

        // An older mind answers the counts alone, and no address but a secure one is followed.
        let bare = try JSONDecoder().decode(AttentionSummary.self, from: Data(#"{"approvals":1,"until":0}"#.utf8))
        XCTAssertEqual(bare, AttentionSummary(state: Content(approvals: 1)))
        for address in ["http://todo.example.org/", "javascript:alert(1)", "todo"] {
            let odd = try JSONDecoder().decode(AttentionSummary.self, from: Data(#"{"todoList":"\#(address)"}"#.utf8))
            XCTAssertNil(odd.todoList, address)
        }
    }
}
