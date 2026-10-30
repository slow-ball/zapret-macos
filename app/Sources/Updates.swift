import SwiftUI

/// The changes of one version, from CHANGELOG.md in the project folder (CHANGELOG.en.md in English)
enum Changelog {
    static func section(for version: String, project: String) -> String? {
        guard !project.isEmpty else { return nil }
        let english = Bundle.main.preferredLocalizations.first == "en"
        if english, let s = section(for: version, file: project + "/CHANGELOG.en.md") { return s }
        return section(for: version, file: project + "/CHANGELOG.md")
    }

    static func section(for version: String, file: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        var lines: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == version
                continue
            }
            if inside { lines.append(line) }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

/// After an update: what changed, in the app's own look
struct WhatsNewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                LogoMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Что нового").font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text("zapret \(model.status.version)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in row(p) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Отлично") { dismiss() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
    }

    /// list items and their wrapped continuation lines become one paragraph each
    private var paragraphs: [String] {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("- ") || out.isEmpty || !line.hasPrefix(" ") { out.append(t) } else { out[out.count - 1] += " " + t }
        }
        return out
    }

    @ViewBuilder private func row(_ p: String) -> some View {
        if p.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Theme.aurora).frame(width: 6, height: 6).offset(y: -2)
                markdown(String(p.dropFirst(2)))
            }
        } else if p.hasPrefix("### ") {
            Text(p.dropFirst(4)).font(.system(size: 15, weight: .bold, design: .rounded)).padding(.top, 6)
        } else {
            markdown(p).foregroundStyle(.secondary)
        }
    }

    private func markdown(_ s: String) -> some View {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
    }
}
