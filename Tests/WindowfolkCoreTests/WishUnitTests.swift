import Foundation
import Testing
@testable import WindowfolkCore

struct WishUnitTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func wishTypeCaseOrder() {
        #expect(WishType.allCases == [.flower, .chair, .lamp, .visit, .chase])
    }

    @Test func participantsByType() {
        var book = WishBook()
        for (type, expected) in [
            (WishType.flower, Set<ResidentID>([.a, .b])), (.chase, [.a, .b]),
            (.chair, [.b]), (.lamp, [.b]), (.visit, [.b]),
        ] {
            let w = Wish(id: book.makeID(), type: type, wisher: .b, createdAt: t0)
            #expect(w.participants == expected)
        }
    }

    @Test func busyAndWishOfFollowActive() {
        var book = WishBook()
        #expect(book.busy.isEmpty)
        #expect(book.wish(of: .a) == nil)
        let chair = Wish(id: book.makeID(), type: .chair, wisher: .a, createdAt: t0)
        book.active = [chair]
        #expect(book.busy == [.a])
        #expect(book.wish(of: .a) == chair)
        #expect(book.wish(of: .b) == nil)
        let flower = Wish(id: book.makeID(), type: .flower, wisher: .b, createdAt: t0)
        book.active = [flower]
        #expect(book.busy == [.a, .b])
        #expect(book.wish(of: .a) == flower)
    }

    @Test func makeIDIsIncreasingAndInitAvoidsCollisions() {
        var book = WishBook()
        let first = book.makeID()
        let second = book.makeID()
        #expect(first < second)

        let late = Wish(id: WishID(7), type: .visit, wisher: .a, createdAt: t0,
                        visitTarget: VisitTarget(window: 3, ownerName: "Finder"))
        let early = Wish(id: WishID(2), type: .chair, wisher: .b, createdAt: t0)
        var restored = WishBook(active: [late, early])
        #expect(restored.active.map(\.id) == [WishID(2), WishID(7)])
        #expect(restored.makeID() == WishID(8))
        #expect(restored.flowerCount == 0 && restored.nextCheckAt == nil && restored.lastFlowerDoneAt == nil)
    }
}
