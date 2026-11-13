import Foundation

/// Chase_Wish 的纯规则：Chase_Candidate_Point、Flee_Target 选择、抓到判定（Requirement 21.4、21.5、22.1）。
public enum ChaseRules {
    /// Chaser 固定为 Resident_A。
    public static let chaser: ResidentID = .a
    /// Runner 固定为 Resident_B。
    public static let runner: ResidentID = .b

    /// Runner 可达的每条 Surface 各给出 1 或 2 个候选点（Chase_Candidate_Point）。
    ///
    /// Surface `[lo, hi]` 满足 `hi - lo > 2 × inset` 时取 `lo + inset` 和 `hi - inset`，否则取中点。
    /// 结果去重后按 `(SurfaceID, x)` 升序排列。
    public static func candidates(runnerField: HorizontalField, surfaces: [Surface], inset: Double) -> [FleePoint] {
        var points = Set<FleePoint>()
        for s in surfaces where runnerField.isReachable(s.id) {
            let lo = min(s.start.x, s.end.x)
            let hi = max(s.start.x, s.end.x)
            if hi - lo > 2 * inset {
                points.insert(FleePoint(surface: s.id, x: lo + inset))
                points.insert(FleePoint(surface: s.id, x: hi - inset))
            } else {
                points.insert(FleePoint(surface: s.id, x: (lo + hi) / 2))
            }
        }
        return points.sorted(by: pointOrder)
    }

    /// Flee_Target 选择：Chaser 路线水平总长度降序（不可达视为 +∞），Runner 长度升序，x 升序；
    /// 仍并列时取 `(SurfaceID, x)` 顺序在前的点。候选为空时返回 nil。
    public static func selectFleeTarget(_ c: [FleePoint], chaserField: HorizontalField,
                                        runnerField: HorizontalField) -> FleePoint? {
        typealias Keyed = (point: FleePoint, chaser: Double, runner: Double)
        let keyed: [Keyed] = c.sorted(by: pointOrder).map { p in
            (p,
             chaserField.length(to: p.surface, x: p.x) ?? .infinity,
             runnerField.length(to: p.surface, x: p.x) ?? .infinity)
        }
        var best: Keyed?
        for k in keyed {
            guard let b = best else { best = k; continue }
            if k.chaser != b.chaser {
                if k.chaser > b.chaser { best = k }
            } else if k.runner != b.runner {
                if k.runner < b.runner { best = k }
            } else if k.point.x < b.point.x {
                best = k
            }
        }
        return best?.point
    }

    /// 抓到判定（Requirement 22.1）：两人都有位置、在同一 Surface、都不处于 `falling`、`hanging`、`climbing`，
    /// 都不在 Hidden_Window 上，且 x 差的绝对值不超过 `distance`（含边界）。
    /// Chase_Phase 是否为 `running` 由调用方判断。
    public static func isCaught(chaser: ResidentLocation?, runner: ResidentLocation?,
                                chaserState: ResidentState, runnerState: ResidentState,
                                hidden: Set<ResidentID>, distance: Double) -> Bool {
        guard let c = chaser, let r = runner else { return false }
        guard !hidden.contains(Self.chaser), !hidden.contains(Self.runner) else { return false }
        let airborne: Set<ResidentState> = [.falling, .hanging, .climbing]
        guard !airborne.contains(chaserState), !airborne.contains(runnerState) else { return false }
        return c.surface == r.surface && abs(c.x - r.x) <= distance
    }

    private static func pointOrder(_ l: FleePoint, _ r: FleePoint) -> Bool {
        l.surface != r.surface ? l.surface < r.surface : l.x < r.x
    }
}
