import Foundation
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// AssetRules 分类的单元测试（任务 2.9）。
/// _Requirements: 4.5, 6.3, 6.4_
@Suite struct AssetRulesTests {

    static let bubbleKeys = BubbleIcon.allCases.map(AssetCatalog.bubbleKey)
    static let flowerKeys = FlowerAssetStage.allCases.map(AssetCatalog.flowerKey)

    @Test func everyCatalogKeyHasRules() {
        #expect(AssetCatalog.all.count == 45)
        for spec in AssetCatalog.all {
            let rules = AssetRules.rules(for: spec.key)
            #expect(rules?.spec == spec, "\(spec.key) 缺少规则")
        }
        #expect(AssetRules.all.map(\.spec.key) == AssetCatalog.all.map(\.key))
        #expect(AssetRules.rules(for: "resident_c_idle") == nil)
        #expect(AssetRules.rules(for: "resident_a_flying") == nil)
        #expect(AssetRules.rules(for: "") == nil)
    }

    @Test func groundedStatesAreFiveStatesTimesTwoResidents() {
        let expectedStates: Set<ResidentState> = [.idle, .walking, .carrying, .waiting, .running]
        #expect(AssetRules.groundedStates == expectedStates)

        let expectedKeys = Set(ResidentID.allCases.flatMap { id in
            expectedStates.map { AssetCatalog.residentKey(id, $0) }
        })
        let grounded = AssetRules.all.filter(\.isGrounded)
        #expect(grounded.count == 10)
        #expect(Set(grounded.map(\.spec.key)) == expectedKeys)
        for r in AssetRules.all {
            #expect((r.alignment == .groundedPerFrame) == r.isGrounded, "\(r.spec.key)")
        }
    }

    @Test func residentRulesCarryOwnerAndPalette() {
        let residents = AssetRules.all.filter { $0.owner != nil }
        #expect(residents.count == 24)
        for id in ResidentID.allCases {
            for state in ResidentState.allCases {
                let key = AssetCatalog.residentKey(id, state)
                let r = AssetRules.rules(for: key)!
                #expect(r.owner?.residentID == id, "\(key)")
                #expect(r.palettes == [id == .a ? .residentA : .residentB], "\(key)")
                let grounded = AssetRules.groundedStates.contains(state)
                #expect(r.alignment == (grounded ? .groundedPerFrame : .nonGroundedUniform), "\(key)")
            }
        }
        #expect(AssetRules.all.filter { $0.owner == nil }.allSatisfy { !$0.isGrounded })
    }

    @Test func framedExcludesExactlyPlankLadderToolbox() {
        let unframed: Set<String> = ["plank", "ladder", "toolbox"]
        #expect(AssetRules.unframedKeys == unframed)
        #expect(Set(AssetRules.all.filter { !$0.isFramed }.map(\.spec.key)) == unframed)
        #expect(AssetRules.all.filter(\.isFramed).count == 42)
    }

    @Test func centeredBottomAssets() {
        let expected = Set(["fruit", "decor_chair", "visit_flag", "toolbox"] + Self.bubbleKeys)
        #expect(Self.bubbleKeys.count == 10)
        let actual = Set(AssetRules.all.filter { $0.alignment == .centeredBottom }.map(\.spec.key))
        #expect(actual == expected)
    }

    @Test func anchoredBaseAndTileAssets() {
        let anchored = Set(AssetRules.all.filter { $0.alignment == .anchoredBase }.map(\.spec.key))
        #expect(anchored == Set(Self.flowerKeys + ["decor_lamp_off", "decor_lamp_on"]))
        #expect(AssetRules.rules(for: "plank")?.alignment == .tile(.horizontal))
        #expect(AssetRules.rules(for: "ladder")?.alignment == .tile(.vertical))
    }

    @Test func nonResidentPalettes() {
        func palettes(_ key: String) -> [PaletteGroup]? { AssetRules.rules(for: key)?.palettes }
        for key in Self.flowerKeys { #expect(palettes(key) == [.wood, .plant], "\(key)") }
        #expect(palettes("fruit") == [.plant])
        for key in ["plank", "ladder", "toolbox", "decor_chair"] { #expect(palettes(key) == [.wood], "\(key)") }
        for key in Self.bubbleKeys + ["decor_lamp_off", "decor_lamp_on", "visit_flag"] {
            #expect(palettes(key) == [], "\(key)")
        }
    }
}
