import Foundation
import PropertyBased
@testable import WindowfolkCore

// 存档生成器（design.md「生成器」表中的 `Gen.saveFile`）。
// 覆盖全部 Story_Stage 和未开局、任意轮次、有无 doneAt、居民有无持有物、四种 Ground_Object，
// 花有无种下时间、任意已达阶段。时间先经过 `SaveTime.normalized`（整毫秒），与存档生成时的规则一致。
// ID 只用 ASCII（UUID 字符串或数字字符串）。

extension Gen where Value == Date {
    /// 1990 到 2100 年之间的整秒加随机小数，取整到毫秒。
    static var saveDate: Generator<Date, some SendableSequenceType> {
        zip(Gen<Int>.int(in: 631_152_000...4_102_444_800), Gen<Double>.double(in: 0..<1))
            .map { SaveTime.normalized(Date(timeIntervalSince1970: Double($0) + $1)) }
    }
}

extension Gen where Value == SavedFlower {
    static var savedFlower: Generator<SavedFlower, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 1...500).optional(),
            Gen<Date>.saveDate.optional(),
            Gen<GrowthStage>.case
        ).map { SavedFlower(storyRound: $0, plantedAt: $1, reached: $2) }
    }
}

extension Gen where Value == String {
    /// Item 用 UUID 字符串，Plank 和 Ladder 用数字字符串。
    static func saveObjectID(numeric: Bool) -> Generator<String, some SendableSequenceType> {
        zip(Gen<UInt64>.value(in: 0...UInt64.max), Gen<UInt64>.value(in: 0...UInt64.max)).map { hi, lo in
            if numeric { return String(hi % 100_000) }
            var bytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<8 {
                bytes[i] = UInt8(truncatingIfNeeded: hi >> (8 * i))
                bytes[8 + i] = UInt8(truncatingIfNeeded: lo >> (8 * i))
            }
            let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            return uuid.uuidString
        }
    }
}

extension Gen where Value == Double {
    /// 屏幕 x：一半是整数，一半带任意小数；范围包含屏幕外的值。
    static var saveX: Generator<Double, some SendableSequenceType> {
        zip(Gen<Bool>.bool, Gen<Int>.int(in: -500...4000), Gen<Double>.double(in: -500...4000))
            .map { whole, i, d in whole ? Double(i) : d }
    }
}

extension Gen where Value == SaveFile {
    static var saveFile: Generator<SaveFile, some SendableSequenceType> {
        let heldItem = zip(
            Gen<SavedItemKind>.case,
            Gen<String>.saveObjectID(numeric: false),
            Gen<SavedFlower>.savedFlower
        ).map { SavedHeldItem(id: $1, kind: $0, flower: $2) }

        let resident = zip(Gen<Double>.saveX, heldItem.optional())

        let object = zip(
            Gen<SavedObjectKind>.case,
            Gen<String>.saveObjectID(numeric: false),
            Gen<String>.saveObjectID(numeric: true),
            Gen<Double>.saveX,
            Gen<SavedFlower>.savedFlower
        ).map { kind, uuid, number, x, flower in
            let isItem = kind == .flower || kind == .fruit
            return SavedObject(id: isItem ? uuid : number, kind: kind, x: x, flower: flower)
        }

        return zip(
            Gen<Date>.saveDate,
            Gen<StoryStage>.case.optional(),
            Gen<Int>.int(in: 1...1000),
            Gen<Date>.saveDate.optional(),
            Gen<Int>.int(in: 0...3),           // 居民组合：无、只有 a、只有 b、两位
            resident, resident,
            object.array(of: 0...12)
        ).map { savedAt, stage, round, doneAt, which, ra, rb, objects in
            var residents: [SavedResident] = []
            if which & 1 != 0 { residents.append(SavedResident(id: .a, x: ra.0, heldItem: ra.1)) }
            if which & 2 != 0 { residents.append(SavedResident(id: .b, x: rb.0, heldItem: rb.1)) }
            return SaveFile(
                savedAt: savedAt,
                story: SavedStory(stage: stage, round: round, doneAt: doneAt),
                residents: residents,
                groundObjects: objects)
        }
    }
}
