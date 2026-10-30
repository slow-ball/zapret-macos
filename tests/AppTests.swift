// Tests of the app's logic: how it reads what the script prints and what it writes itself.
// No Xcode: built together with the app's sources, which then have no main of their own.
//   xcrun swiftc -parse-as-library -D TESTING app/Sources/*.swift tests/AppTests.swift -o /tmp/apptests && /tmp/apptests

import Foundation

@main
struct AppTests {
    static var passed = 0
    static var failed = 0

    static func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1; print("FAIL: \(what) \(detail())") }
    }

    static func eq<T: Equatable>(_ what: String, _ got: T, _ want: T) {
        check(what, got == want, "получено «\(got)», ожидалось «\(want)»")
    }

    @MainActor
    static func main() {
        status()
        strategies()
        events()
        diagnostics()
        changelog()
        report()
        print("app: \(passed) прошло, \(failed) не прошло")
        exit(failed == 0 ? 0 : 1)
    }

    // status --json of the script
    static func status() {
        let full =
            #"{"version":"1.1.0","previous":"1.0.0","installed":true,"running":true,"strategy":"nfqws general (ALT13)","engine":"nfqws","scope":"smart","game":"off","telegram":true,"telegramRunning":false,"telegramLink":"tg://x","flowsealTelegram":false,"autostart":true,"autofix":false,"autoupdate":true,"vpn":false,"ipv6":true,"found":3,"sites":1,"project":"/p"}"#
        let s = try? JSONDecoder().decode(Status.self, from: Data(full.utf8))
        eq("статус: версия", s?.version, "1.1.0")
        eq("статус: предыдущая", s?.previous, "1.0.0")
        eq("статус: режим", s?.scope, "smart")
        eq("статус: найдено", s?.found, 3)
        // the root copy of the script may be older than the app: missing keys keep their defaults
        let old = try? JSONDecoder().decode(Status.self, from: Data(#"{"version":"2.2.1","running":true}"#.utf8))
        eq("старый скрипт: версия", old?.version, "2.2.1")
        eq("старый скрипт: предыдущей нет", old?.previous, "")
        eq("старый скрипт: режим по умолчанию", old?.scope, "smart")
        // one key of a wrong type doesn't throw the whole status away
        let odd = try? JSONDecoder().decode(Status.self, from: Data(#"{"version":"1.1.0","found":"много","running":true}"#.utf8))
        eq("кривой ключ: остальное на месте", odd?.running, true)
        eq("кривой ключ: свой по умолчанию", odd?.found, 0)
        eq("старый скрипт: Telegram не подключён", old?.telegramConnected, false)
        // the keys of the ladder in words
        eq("лестница: группа видео", LadderLive.title("sn-4g5e6nsz.googlevideo.com"), "Видео YouTube · sn-4g5e6nsz")
        eq("лестница: QUIC", LadderLive.title("quic:youtube.com"), "youtube.com · QUIC")
        eq("лестница: голос", LadderLive.title("voice"), "Голос Discord")
        eq("лестница: сайт", LadderLive.title("github.com"), "github.com")
        // found sites: why the engine took them, absent when it didn't say
        let found = try? JSONDecoder().decode(
            [FoundSite].self, from: Data(#"[{"site":"a.com","strategy":"","why":"rst"},{"site":"b.com","strategy":"x"}]"#.utf8))
        eq("найденный: причина", found?.first?.whyText, L("сброс соединения"))
        eq("найденный от старого скрипта: без причины", found?.last?.whyText, nil)
    }

    static func strategies() {
        let w = Strategy(name: "nfqws general (ALT13)")
        eq("Windows: название без префикса", w.title, "general (ALT13)")
        eq("Windows: вид", w.kind, "Windows")
        let m = Strategy(name: "macos (ALT5)")
        eq("своя: название как есть", m.title, "macos (ALT5)")
        eq("своя: вид", m.kind, "macOS")
        eq("найденная глубоким подбором — macOS", Strategy(name: "Глубокий подбор: example.com").kind, "macOS")
    }

    // check --json and deep --json
    static func events() {
        check("не событие: обычный текст", scriptEvent("  ✓ zapret запущен") == nil)
        check("не событие: JSON без event", scriptEvent(#"{"site":"x"}"#) == nil)
        var run = CheckRun()
        for line in [
            #"{"event":"start","total":"37"}"#, #"{"event":"base","pass":"1/4","voice":"0"}"#,
            #"{"event":"result","name":"nfqws general","ok":"1","pass":"4/4","kbps":"6950","voice":"1"}"#,
            #"{"event":"result","name":"macos","ok":"0","pass":"0/4"}"#,
            #"{"event":"finish","best":"nfqws general","kbps":"6950","voice":"1"}"#,
        ] {
            if let e = scriptEvent(line) { run.apply(e) }
        }
        eq("подбор: всего", run.total, 37)
        eq("подбор: без zapret", run.baseline, "1/4")
        eq("подбор: результатов", run.results.count, 2)
        eq("подбор: скорость", run.results.first?.kbps, 6950)
        eq("подбор: голос", run.results.first?.voice, true)
        eq("подбор: неудачная", run.results.last?.ok, false)
        eq("подбор: лучшая", run.best, "nfqws general")
        eq("подбор: без ошибки", run.error, nil)
        var none = CheckRun()
        none.apply(["event": "finish", "best": ""])
        check("подбор: ничего не нашлось — ошибка", none.best == nil && none.error != nil)

        var deep = DeepRun(site: "example.com")
        deep.apply(["event": "start", "site": "example.com", "total": "110"])
        deep.apply(["event": "progress", "tested": "7", "option": "--dpi-desync=fake"])
        eq("глубокий: всего", deep.total, 110)
        eq("глубокий: проверено", deep.tested, 7)
        deep.apply(["event": "progress", "tested": "", "option": "x"])
        eq("глубокий: пустое число не обнуляет", deep.tested, 7)
        deep.apply(["event": "finish", "strategy": "", "reason": "open"])
        check("глубокий: открывается и так", deep.finished && deep.strategy == nil && deep.reason == "open")
    }

    // diag --tags
    static func diagnostics() {
        let out = """
            zapret-macos 1.1.0, macOS 26.1, arm64

            zapret
              ✓ установлен
              ✗ не запущен
                @fix start
              · автопочинка выключена

            Сеть
              ! включён VPN — пока он работает, zapret не участвует
            """
        let s = DiagSection.parse(out)
        eq("диагностика: разделов", s.count, 3)
        eq("диагностика: раздел", s[1].title, "zapret")
        eq("диагностика: пунктов", s[1].items.count, 3)
        check("диагностика: ✓ — норма", s[1].items[0].kind == .ok)
        check("диагностика: ✗ — плохо", s[1].items[1].kind == .bad)
        eq("диагностика: кнопка у пункта выше", s[1].items[1].fix, "start")
        eq("диагностика: без кнопки", s[1].items[0].fix, nil)
        check("диагностика: · — сведения", s[1].items[2].kind == .info)
        eq("диагностика: значок отрезан", s[1].items[2].text, "автопочинка выключена")
        check("диагностика: ! — предупреждение", s[2].items[0].kind == .warn)
        let orphan = DiagSection.parse("  ✓ без раздела")
        eq("пункт без раздела попадает в «zapret»", orphan.first?.title, "zapret")
        eq("@fix без пункта не ломает разбор", DiagSection.parse("zapret\n  @fix start").first?.items.count, 0)
    }

    // What's New
    static func changelog() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zapret-changelog-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        try? """
        # Изменения

        ## 1.1.0

        - Первое
          с переносом
        - Второе

        ## 1.0.0

        - Старое
        """.write(to: file, atomically: true, encoding: .utf8)
        let s = Changelog.section(for: "1.1.0", file: file.path)
        check("что нового: свой раздел", s?.contains("Первое") == true && s?.contains("Второе") == true)
        check("что нового: без чужого", s?.contains("Старое") == false)
        eq("что нового: нет раздела", Changelog.section(for: "9.9.9", file: file.path), nil)
        eq("что нового: нет файла", Changelog.section(for: "1.1.0", file: "/nonexistent"), nil)
    }

    // the problem report goes to a public issue: nothing personal
    static func report() {
        let s = AppModel.scrub("адрес 192.168.1.10, IPv6 2a00:1450:4010:c05::64, дом \(NSHomeDirectory())/zapret-macos")
        check("отчёт: IPv4 скрыт", !s.contains("192.168.1.10"), s)
        check("отчёт: IPv6 скрыт", !s.contains("2a00:1450"), s)
        check("отчёт: домашняя папка скрыта", !s.contains(NSHomeDirectory()) && s.contains("~/zapret-macos"), s)
        eq("отчёт: версии не трогаются", AppModel.scrub("zapret 1.1.0, macOS 26.1"), "zapret 1.1.0, macOS 26.1")
        eq("отчёт: время не трогается", AppModel.scrub("2026-10-28 12:34:56 start"), "2026-10-28 12:34:56 start")
        let log = [
            "2026-10-28 12:00:00 start nfqws general", "2026-10-28 12:00:05 site secret.example: reason=dpi works=1",
            "2026-10-28 12:00:06 learn: secret.example → macos", "2026-10-28 12:00:07 deep secret.example: --x",
            "2026-10-28 12:00:08 check: macos",
        ]
        let kept = AppModel.withoutSites(log)
        eq("журнал в отчёте: без проверенных сайтов", kept.count, 2)
        check("журнал в отчёте: остальное на месте", kept.first?.hasSuffix("start nfqws general") == true)
        check("отчёт: короткий IPv6 скрыт", !AppModel.scrub("шлюз fe80::1").contains("fe80::1"))
    }
}
