import Foundation

struct Status: Decodable, Equatable {
    var version = ""
    /// the version before the last update, if the app can go back to it (3.0 or later)
    var previous = ""
    var installed = false
    var running = false
    var strategy = ""
    var engine = "nfqws"
    var scope = "all"
    var game = "off"
    var autostart = false
    var autofix = false
    var autoupdate = false
    var vpn = false
    var ipv6 = false
    var found = 0
    var sites = 0
    var project = ""
    var telegram = false
    var telegramRunning = false
    /// Telegram itself holds a connection to the proxy: nothing left to connect
    var telegramConnected = false
    /// the proxy itself reaches Telegram (it notes every try): connected to a proxy that can't is no help
    var telegramReachable = true
    var telegramLink = ""
    var flowsealTelegram = false
    /// the fresh strategies in use (pack.sh): "1.10.4+20261023.2006", empty — the release's
    var pack = ""
    var packOn = true
    /// the adaptive strategy: sites that found their own trick on its ladder
    var ladder = 0
    /// YouTube video over QUIC; off — over TCP, which the adaptive strategy tunes (zapret.sh video)
    var videoQuic = true

    init() {}

    /// fields the script doesn't know yet keep their defaults: the root copy of the script
    /// may be older than the app, and one missing key must not throw the whole status away
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ key: Keys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        version = get(.version, version); previous = get(.previous, previous)
        installed = get(.installed, installed); running = get(.running, running)
        strategy = get(.strategy, strategy); engine = get(.engine, engine); scope = get(.scope, scope); game = get(.game, game)
        autostart = get(.autostart, autostart); autofix = get(.autofix, autofix); autoupdate = get(.autoupdate, autoupdate)
        vpn = get(.vpn, vpn); ipv6 = get(.ipv6, ipv6); found = get(.found, found); sites = get(.sites, sites)
        project = get(.project, project); telegram = get(.telegram, telegram); telegramRunning = get(.telegramRunning, telegramRunning)
        telegramConnected = get(.telegramConnected, telegramConnected); telegramReachable = get(.telegramReachable, telegramReachable)
        telegramLink = get(.telegramLink, telegramLink); flowsealTelegram = get(.flowsealTelegram, flowsealTelegram)
        pack = get(.pack, pack); packOn = get(.packOn, packOn); ladder = get(.ladder, ladder); videoQuic = get(.videoQuic, videoQuic)
    }

    private enum Keys: String, CodingKey {
        case version, previous, installed, running, strategy, engine, scope, game, autostart, autofix, autoupdate, vpn, ipv6
        case found, sites, project, telegram, telegramRunning, telegramConnected, telegramReachable, telegramLink, flowsealTelegram, pack, packOn, ladder,
            videoQuic
    }
}

struct Strategy: Identifiable, Hashable {
    let name: String
    var id: String { name }
    /// the Windows version's strategies are named "nfqws <name>"; our own and the ones the deep search
    /// found have no prefix
    var isWindows: Bool { name.hasPrefix("nfqws ") }
    var kind: String { isWindows ? "Windows" : isAdaptive ? Strategy.adaptiveKind : "macOS" }
    static let adaptiveKind = L("Авто")
    static let adaptive = Strategy(name: "Адаптивная")
    /// the ladder of the engine: one strategy that finds its own trick for every site
    var isAdaptive: Bool { name == "Адаптивная" }
    /// name without the prefix: "general (ALT13)"; the adaptive one in the language of the app
    var title: String { isWindows ? String(name.dropFirst(6)) : isAdaptive ? L("Адаптивная") : name }
}

/// The adaptive strategy at work (zapret.sh ladder --live --json): the sites used most and the latest moves
struct LadderLive: Decodable, Equatable {
    /// a key of the engine's ladder in words: a group of YouTube's video servers, a site over QUIC, Discord voice
    static func title(_ key: String) -> String {
        if key == "voice" { return L("Голос Discord") }
        if key.hasPrefix("quic:") { return title(String(key.dropFirst(5))) + " · QUIC" }
        if key.hasPrefix("sn-"), key.hasSuffix(".googlevideo.com") {
            return L("Видео YouTube") + " · " + String(key.prefix { $0 != "." })
        }
        return key
    }

    struct Site: Decodable, Equatable, Identifiable {
        let site: String
        let connections: Int
        let last: Int
        let rung: Int
        let kbps: Int
        let trick: String
        var id: String { site }
    }
    struct Event: Decodable, Equatable, Identifiable {
        let time: String
        let site: String
        let rung: Int
        let reason: String
        var id: String { time + site }

        /// what made the ladder move, in words
        var reasonText: String {
            switch reason {
            case "faster": L("быстрее")
            case "rst": L("провайдер сбросил соединение")
            case "redirect": L("провайдер подменил страницу")
            default: L("запросы без ответа")
            }
        }
    }
    var sites: [Site] = []
    var events: [Event] = []
}

struct FoundSite: Decodable, Identifiable, Hashable {
    let site: String
    let strategy: String
    /// what the provider did to it, as the engine saw: rst, redirect, silence; none when the engine didn't say
    var why: String?
    var id: String { site }

    var whyText: String? {
        switch why {
        case "rst": L("сброс соединения")
        case "redirect": L("переадресация на заглушку")
        case "silence": L("запросы без ответа")
        default: nil
        }
    }
}

struct CheckResult: Identifiable, Equatable {
    let name: String
    let ok: Bool
    let kbps: Int
    let voice: Bool
    var id: String { name }
}

struct CheckRun: Equatable {
    var total = 0
    var results: [CheckResult] = []
    var baseline: String?
    var best: String?
    var finished = false
    var error: String?
    /// the user stopped it: the strategy from before runs again
    var cancelled = false
    var progress: Double { total == 0 ? 0 : min(Double(results.count) / Double(total), 1) }
}

struct SiteResult: Decodable, Equatable {
    var site = ""
    /// why it didn't open (site_reason of the script): open, dpi, dns, nodns, ip, geo; nil when the script didn't tell
    var reason: String?
    /// the DNS for neural networks that is on, if any
    var dns: String?
    var added = false
    var direct = false
    var works = false
    var strategy = ""
    var error: String?
}

struct DeepRun: Equatable {
    var site: String
    var tested = 0
    var total = 0
    var option = ""
    var finished = false
    var strategy: String?
    var reason: String?
    var error: String?
    var cancelled = false
}

struct DiagItem: Identifiable {
    enum Kind { case ok, bad, warn, info }
    let id = UUID()
    let kind: Kind
    let text: String
    /// a fix the script suggests for this line (@fix in diag --tags)
    var fix: String?
}

struct DiagSection: Identifiable {
    let id = UUID()
    let title: String
    var items: [DiagItem]
}

// MARK: what the script prints

/// one event line of the script's --json output: {"event":"…", …} with string values; nil for anything else
func scriptEvent(_ line: String) -> [String: String]? {
    guard let data = line.data(using: .utf8),
        let e = try? JSONSerialization.jsonObject(with: data) as? [String: String], e["event"] != nil
    else { return nil }
    return e
}

extension CheckRun {
    /// the events of check --json
    mutating func apply(_ e: [String: String]) {
        switch e["event"] {
        case "start":
            total = Int(e["total"] ?? "") ?? 0
        case "base":
            baseline = e["pass"]
        case "result":
            results.append(
                CheckResult(
                    name: e["name"] ?? "", ok: e["ok"] == "1",
                    kbps: Int(e["kbps"] ?? "") ?? 0, voice: e["voice"] == "1"))
        case "finish":
            best = (e["best"] ?? "").isEmpty ? nil : e["best"]
            if best == nil { error = L("Ни одна стратегия не прошла все проверки") }
        case "error":
            error = e["message"]
        default:
            break
        }
    }
}

extension DeepRun {
    /// the events of deep --json
    mutating func apply(_ e: [String: String]) {
        switch e["event"] {
        case "start":
            total = Int(e["total"] ?? "") ?? 0
        case "progress":
            tested = Int(e["tested"] ?? "") ?? tested
            option = e["option"] ?? ""
        case "finish":
            strategy = (e["strategy"] ?? "").isEmpty ? nil : e["strategy"]
            reason = e["reason"]
            finished = true
        case "error":
            error = e["message"]
        default:
            break
        }
    }
}

extension DiagSection {
    /// the output of diag --tags: a line at the left edge starts a section, an indented one is an item
    /// (✓ ok, ✗ bad, ! warning, anything else info), "@fix code" gives the item above it a fix button
    static func parse(_ out: String) -> [DiagSection] {
        var sections: [DiagSection] = []
        for raw in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if text.hasPrefix("@fix ") {
                if !sections.isEmpty, !sections[sections.count - 1].items.isEmpty {
                    let s = sections.count - 1
                    sections[s].items[sections[s].items.count - 1].fix = String(text.dropFirst(5))
                }
                continue
            }
            if !line.hasPrefix(" ") {
                sections.append(DiagSection(title: text, items: []))
                continue
            }
            let kind: DiagItem.Kind
            switch text.first {
            case "✓": kind = .ok
            case "✗": kind = .bad
            case "!": kind = .warn
            default: kind = .info
            }
            let body = text.drop { "✓✗!· ".contains($0) }
            if sections.isEmpty { sections.append(DiagSection(title: "zapret", items: [])) }
            sections[sections.count - 1].items.append(DiagItem(kind: kind, text: String(body)))
        }
        return sections
    }
}
