import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

// LLM 返回值校验的属性测试（design.md Property 34，任务 11.6）与 LLMTimeout.run 的超时单元测试。
//
// 期望值不调用被测的修剪逻辑：生成器按构造给出「非空白核心」和首尾/中间的空白，
// 字符串去掉首尾空白后为空，当且仅当核心为空。

// MARK: - 生成器

/// 属于 `CharacterSet.whitespacesAndNewlines` 的字符：ASCII 空白、换行、不换行空格、全角空格、行/段分隔符。
fileprivate let llmWhitespace: [Character] = [" ", "\t", "\n", "\r", "\r\n", "\u{00A0}", "\u{3000}", "\u{2028}", "\u{2029}"]

/// 不含任何空白的字符：ASCII、中文、日文、带重音字母、emoji、标点。
fileprivate let llmVisible: [Character] = ["a", "Z", "0", ".", "嘟", "都", "あ", "é", "🐹", "👨‍👩‍👧", "\"", "\\"]

fileprivate var llmWhitespaceRun: Generator<String, some SendableSequenceType> {
    Gen<Character?>.element(of: llmWhitespace).map { $0! }.string(of: 0...4)
}

/// 一个返回文本的构造：首部空白 + 核心 + 尾部空白。核心为空或以可见字符开头和结尾，中间可夹空白。
fileprivate struct LLMText: Sendable, CustomStringConvertible {
    var leading: String
    var core: String
    var trailing: String

    var text: String { leading + core + trailing }
    var description: String { "leading \(leading.debugDescription) core \(core.debugDescription) trailing \(trailing.debugDescription)" }
}

fileprivate var llmText: Generator<LLMText, some SendableSequenceType> {
    zip(
        llmWhitespaceRun,
        Gen<Character?>.element(of: llmVisible).map { $0! }.array(of: 0...4),
        llmWhitespaceRun.array(of: 3),
        llmWhitespaceRun
    ).map { leading, visible, gaps, trailing -> LLMText in
        // 可见字符之间穿插空白，使核心内部也可能含空白，但首尾都是可见字符。
        var core = ""
        for (i, c) in visible.enumerated() {
            if i > 0 { core += gaps[(i - 1) % gaps.count] }
            core.append(c)
        }
        return LLMText(leading: leading, core: core, trailing: trailing)
    }
}

fileprivate let llmFailures: [LLMFailure] = [
    .timeout, .emptyText, .transport, .invalidResponse, .httpStatus(0), .httpStatus(301), .httpStatus(404),
    .httpStatus(500), .httpStatus(503),
]

// MARK: - 属性测试

@Suite struct LLMValidationPropertyTests {
    // Feature: V2, Property 34: LLM 返回值校验
    // **Validates: Requirements 12.3**
    @Test func validateRejectsExactlyBlankText() async {
        await propertyCheck(count: 200, input: llmText) { t in
            let r = LLMTimeout.validate(.success(t.text))
            if t.core.isEmpty {
                #expect(r == .failure(.emptyText), "\(t)")
            } else {
                #expect(r == .success(t.text), "\(t)")
            }
        }
    }

    // Feature: V2, Property 34: LLM 返回值校验（失败输入保持失败）
    // **Validates: Requirements 12.3**
    @Test func validateKeepsFailures() async {
        await propertyCheck(count: 100, input: Gen<LLMFailure?>.element(of: llmFailures).map { $0! }) { f in
            #expect(LLMTimeout.validate(.failure(f)) == .failure(f))
        }
    }
}

// MARK: - 超时单元测试

/// 记录长操作结束时的情况：sleep 是否被打断、所在 Task 是否已被取消。
fileprivate actor SlowOpProbe {
    private(set) var sleepInterrupted = false
    private(set) var observedCancellation = false

    func record(sleepInterrupted: Bool, cancelled: Bool) {
        self.sleepInterrupted = sleepInterrupted
        observedCancellation = cancelled
    }
}

@Suite struct LLMTimeoutUnitTests {
    // 不断言墙钟耗时：全量并行测试时协作线程池被 CPU 密集的属性测试占满，
    // 50 毫秒的 sleep 和被取消子任务的恢复都可能排队数秒。改为断言长操作确实被取消。
    @Test func slowOperationTimesOut() async {
        let probe = SlowOpProbe()
        let r = await LLMTimeout.run(.milliseconds(50)) {
            // 30 秒的可取消等待：超时后被任务组取消，sleep 抛出 CancellationError 提前结束。
            var interrupted = false
            do { try await Task.sleep(for: .seconds(30)) } catch { interrupted = true }
            await probe.record(sleepInterrupted: interrupted, cancelled: Task.isCancelled)
            return .success("太晚了")
        }
        #expect(r == .failure(.timeout))
        // withTaskGroup 返回前会等所有子任务结束，因此此时 probe 已记录完毕。
        #expect(await probe.sleepInterrupted)
        #expect(await probe.observedCancellation)
    }

    @Test func fastOperationWinsOverTimeout() async {
        let r = await LLMTimeout.run(.seconds(5)) { .success("你好") }
        #expect(r == .success("你好"))
    }

    @Test func fastFailurePassesThrough() async {
        let r = await LLMTimeout.run(.seconds(5)) { .failure(.httpStatus(500)) }
        #expect(r == .failure(.httpStatus(500)))
    }
}
