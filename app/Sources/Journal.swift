import SwiftUI

/// What zapret, its engine and the Telegram proxy wrote: the logs in /var/log, newest first, with search
struct JournalPage: View {
    enum Source: String, CaseIterable, Identifiable {
        case zapret, engine, telegram
        var id: String { rawValue }
        var title: String {
            switch self {
            case .zapret: "zapret"
            case .engine: L("Движок")
            case .telegram: "Telegram"
            }
        }
        var path: String {
            switch self {
            case .zapret: "/var/log/zapret-macos.log"
            case .engine: "/var/log/zapret-macos-nfqws.log"
            case .telegram: "/var/log/zapret-macos-telegram.log"
            }
        }
        var subtitle: String {
            switch self {
            case .zapret: L("Запуски, смена стратегий, подбор, обновления")
            case .engine: L("Ошибки движка nfqws и правил файрвола")
            case .telegram: L("Подключения прокси для Telegram")
            }
        }
    }

    @State private var source: Source = Source(rawValue: UserDefaults.standard.string(forKey: "journal") ?? "") ?? .zapret
    @State private var search = ""
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Журнал", subtitle: "Что делал zapret и что пошло не так. Пригодится, если что-то сломалось.")
            HStack(spacing: 12) {
                Picker("Журнал", selection: $source) {
                    ForEach(Source.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless).help("Скопировать")
                .disabled(shown.isEmpty)
                Button {
                    openInConsole()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless).help("Открыть в Консоли")
            }
            Text(source.subtitle).sectionTitle()
            Card(padding: 0) {
                if shown.isEmpty {
                    Text(search.isEmpty ? "Записей пока нет" : "Ничего не нашлось")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                            JournalLine(text: line)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(i % 2 == 1 ? Color.primary.opacity(0.03) : .clear)
                        }
                    }
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
                }
            }
        }
        .onChange(of: source) { _, s in UserDefaults.standard.set(s.rawValue, forKey: "journal") }
        // live while the page is open
        .task(id: source) {
            while !Task.isCancelled {
                lines = Self.tail(source.path)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// newest first, at most 1000 lines
    private var shown: [String] {
        let all = lines.reversed().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        return Array(all.prefix(1000))
    }

    /// the end of a log: the scripts keep them under a megabyte, the last 256 KB are enough
    nonisolated static func tail(_ path: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > 262_144 ? size - 262_144 : 0
        try? h.seek(toOffset: from)
        let data = (try? h.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if from > 0 { lines.removeFirst() }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown.reversed().joined(separator: "\n"), forType: .string)
        AppModel.shared.show(L("Скопировано"))
    }

    private func openInConsole() {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: source.path)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}

/// "2026-10-24 14:11:03 start nfqws general": the time dimmed, problems in red
private struct JournalLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let (time, rest) = split {
                Text(time).foregroundStyle(.tertiary)
                Text(rest).foregroundStyle(isProblem ? AnyShapeStyle(Theme.bad) : AnyShapeStyle(.primary))
            } else {
                Text(text).foregroundStyle(isProblem ? AnyShapeStyle(Theme.bad) : AnyShapeStyle(.primary))
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var split: (String, String)? {
        guard text.count > 20, text.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d "#, options: .regularExpression) != nil else { return nil }
        let i = text.index(text.startIndex, offsetBy: 19)
        return (String(text[..<i]), String(text[text.index(after: i)...]))
    }

    private var isProblem: Bool {
        let t = text.lowercased()
        return ["не удалось", "не запустился", "не работает", "недоступен", "error", "fail", "не найдена"].contains { t.contains($0) }
    }
}
