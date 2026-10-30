import AppKit
import Foundation

/// The problem report: collected without anything personal, opened as a GitHub issue
extension AppModel {
    /// everything needed to understand a problem, without anything personal: addresses, names and
    /// home paths are replaced, the user's own site lists are not included at all
    func buildReport() async -> String {
        if diagnostics.isEmpty { await runDiagnostics() }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var arch = utsname()
        uname(&arch)
        let machine = withUnsafeBytes(of: &arch.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        func state(_ s: Health.State) -> String {
            switch s {
            case .ok(let d): "работает" + (d.map { " (\($0))" } ?? "")
            case .fail: "НЕ работает"
            case .checking: "проверяется"
            case .unknown: "не проверялось"
            }
        }
        var lines = [
            "zapret \(status.version), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(machine)",
            "стратегия: \(status.strategy), сайты: \(status.scope), игры: \(status.game)",
            "автопочинка: \(status.autofix), автообновление: \(status.autoupdate), VPN: \(status.vpn), IPv6: \(status.ipv6)",
            "Telegram: \(status.telegram ? (status.telegramRunning ? "прокси работает" : "прокси не запущен") : "выключен")",
            "DNS для нейросетей: \(dns.isEmpty ? "выкл" : dns)",
            "",
            "YouTube: \(state(youtube)); Discord: \(state(discord)); голос Discord: \(state(voice))",
        ]
        if let run = check {
            lines.append("")
            lines.append("подбор: без zapret \(run.baseline ?? "?"), лучшая: \(run.best ?? "нет")")
            for r in run.results.prefix(12) {
                lines.append("  \(r.ok ? "✓" : "✗") \(r.name)\(r.ok ? " \(speedText(r.kbps)), голос \(r.voice ? "✓" : "✗")" : "")")
            }
        }
        if let d = deep, d.finished {
            lines.append("глубокий подбор: \(d.strategy ?? d.reason ?? d.error ?? "?")")
        }
        lines.append("")
        for s in diagnostics where !s.items.isEmpty {
            lines.append(s.title)
            for i in s.items {
                let mark =
                    switch i.kind {
                    case .ok: "✓";
                    case .bad: "✗";
                    case .warn: "!";
                    case .info: "·"
                    }
                lines.append("  \(mark) \(i.text)")
            }
        }
        lines += Self.journal()
        return Self.scrub(lines.joined(separator: "\n"))
    }

    nonisolated static func scrub(_ text: String) -> String {
        var t = text
        let home = NSHomeDirectory()
        t = t.replacingOccurrences(of: home, with: "~")
        for name in [NSUserName(), Host.current().localizedName ?? ""] where name.count > 2 {
            t = t.replacingOccurrences(of: name, with: "…")
        }
        // IPv6: three colons or more, or "::" — a time like 12:34:56 has two
        let patterns = [
            #"\b(\d{1,3}\.){3}\d{1,3}\b"#: "x.x.x.x",
            #"\b[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}\b"#: "x:x::x",
            #"\b[0-9a-fA-F]{1,4}::[0-9a-fA-F]{0,4}\b"#: "x:x::x",
        ]
        for (p, r) in patterns {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return t
    }

    /// the last events of zapret and its engine. lines about sites the user looked at are left out:
    /// the report promises not to show the user's own sites
    nonisolated static func journal() -> [String] {
        var out: [String] = []
        for (title, path, n) in [("журнал:", "/var/log/zapret-macos.log", 25), ("движок:", "/var/log/zapret-macos-nfqws.log", 10)] {
            let lines = withoutSites(JournalPage.tail(path)).suffix(n)
            if !lines.isEmpty { out += ["", title] + lines.map { "  " + $0 } }
        }
        return out
    }

    /// "2026-10-28 12:00:00 site example.com: …" and the like go; the time is the first 20 characters
    nonisolated static func withoutSites(_ lines: [String]) -> [String] {
        let personal = ["site ", "learn:", "deep "]
        return lines.filter { line in
            let message = line.count > 20 ? String(line.dropFirst(20)) : line
            return !personal.contains { message.hasPrefix($0) }
        }
    }

    /// the issue form of the repository with the report filled in
    func openIssue(_ report: String) {
        var text = report
        if text.count > 6000 { text = String(text.prefix(6000)) + "\n… (обрезано)" }
        var c = URLComponents(string: "https://github.com/slow-ball/zapret-macos/issues/new")!
        c.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "title", value: "Не работает: "),
            URLQueryItem(name: "report", value: text),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
