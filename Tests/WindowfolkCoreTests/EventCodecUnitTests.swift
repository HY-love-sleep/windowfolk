import Foundation
import Testing
@testable import WindowfolkCore

struct EventCodecUnitTests {
    private let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!

    private func object(_ line: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    @Test func exactlyFourteenEventTypes() {
        #expect(EventType.allCases.count == 14)
        #expect(Set(EventType.allCases.map(\.rawValue)) == [
            "crossed_bridge", "climbed_ladder", "fell", "landed", "waiting_started",
            "round_started", "planted", "sprouted", "bloomed", "gift_delivered",
            "plank_placed", "plank_dropped", "ladder_placed", "ladder_dropped",
        ])
    }

    @Test func encodesFiveKeysWithNullsAndEmptyDetail() throws {
        let r = EventRecord(time: Date(timeIntervalSince1970: 1_792_500_000.75), type: .bloomed)
        let line = EventCodec.encodeLine(r, timeZone: shanghai)
        let text = try #require(String(data: line, encoding: .utf8))
        #expect(text == #"{"actor":null,"detail":{},"target":null,"time":"2026-10-20T20:40:00+08:00","type":"bloomed"}"# + "\n")
        #expect(Set(try object(line).keys) == ["time", "type", "actor", "target", "detail"])
    }

    @Test func utcUsesNumericOffset() {
        let s = EventCodec.formatTime(Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(s == "1970-01-01T00:00:00+00:00")
    }

    @Test func roundTripWithSpecialCharactersStaysOneLine() throws {
        let r = EventRecord(
            time: Date(timeIntervalSince1970: 1_792_500_123.9), type: .crossedBridge,
            actor: EventRecord.residentRef(.a), target: EventRecord.appRef("备忘录 \"Notes\"\n\\🐹"),
            detail: ["from": EventRecord.appRef("Safari"), "to": "a\nb"])
        let line = EventCodec.encodeLine(r, timeZone: shanghai)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try EventCodec.decodeLine(line) == r)
        #expect(r.time == Date(timeIntervalSince1970: 1_792_500_123))
    }

    @Test func decodeRejectsMissingOrExtraKeys() {
        let missing = Data(#"{"detail":{},"target":null,"time":"2026-10-20T03:20:00+08:00","type":"fell"}"#.utf8)
        #expect(throws: (any Error).self) { try EventCodec.decodeLine(missing) }
        let extra = Data(#"{"actor":null,"detail":{},"target":null,"time":"2026-10-20T03:20:00+08:00","type":"fell","x":1}"#.utf8)
        #expect(throws: (any Error).self) { try EventCodec.decodeLine(extra) }
        let unknownType = Data(#"{"actor":null,"detail":{},"target":null,"time":"2026-10-20T03:20:00+08:00","type":"jumped"}"#.utf8)
        #expect(throws: (any Error).self) { try EventCodec.decodeLine(unknownType) }
    }
}
