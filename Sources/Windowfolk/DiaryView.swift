import Observation
import SwiftUI
import WindowfolkCore

/// Diary_Window 的显示状态。
@MainActor
@Observable
final class DiaryViewModel {
    /// 已按日期从新到旧排好（`DiaryBatch.displayOrder`）。
    var entries: [DiaryEntry] = []
    /// 至少读取过一次。读取前不显示空状态，避免一闪而过。
    var loaded = false
    /// 「写今天的日记」进行中。
    var isWriting = false
    @ObservationIgnored var onWriteToday: (() -> Void)?
}

/// Diary_Window 的内容：顶部「写今天的日记」，下方按日期分组列出日记，没有日记时显示空状态（Requirement 13.12）。
struct DiaryView: View {
    let model: DiaryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                if model.isWriting {
                    ProgressView().controlSize(.small)
                }
                Button("写今天的日记") { model.onWriteToday?() }
                    .disabled(model.isWriting)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(minWidth: 320, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty {
            if model.loaded {
                ContentUnavailableView(
                    "还没有日记",
                    systemImage: "book.closed",
                    description: Text("都都和嘟嘟过完一天后会写下日记，也可以点「写今天的日记」。"))
            } else {
                Spacer()
            }
        } else {
            List {
                ForEach(sections, id: \.date) { section in
                    Section(section.date.description) {
                        ForEach(section.entries, id: \.key) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ResidentName(entry.resident).rawValue).font(.headline)
                                Text(entry.text).textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    /// 按日期分组，保持 `entries` 的顺序（已是从新到旧）。
    private var sections: [(date: LocalDate, entries: [DiaryEntry])] {
        var out: [(date: LocalDate, entries: [DiaryEntry])] = []
        for e in model.entries {
            if out.last?.date == e.date {
                out[out.count - 1].entries.append(e)
            } else {
                out.append((e.date, [e]))
            }
        }
        return out
    }
}
