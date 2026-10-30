import SwiftUI

/// Development aid: with ZAPRET_SNAPSHOT=<folder> the app draws every page and the menu panel
/// into PNG files there and quits. Capturing its own windows needs no screen recording permission.
enum Snapshot {
    static var folder: String? { ProcessInfo.processInfo.environment["ZAPRET_SNAPSHOT"] }

    @MainActor
    static func run(_ model: AppModel) {
        guard let folder else { return }
        Task { @MainActor in
            await model.refresh()
            if ProcessInfo.processInfo.environment["ZAPRET_DEMO"] == "1" { demo(model) }
            let dark = ProcessInfo.processInfo.environment["ZAPRET_SNAPSHOT_DARK"] == "1"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var shots: [(String, AnyView, NSSize)] = [("menu", AnyView(MenuPanel().fixedSize().background(.background)), NSSize(width: 344, height: 400))]
            shots.append(("welcome", AnyView(WelcomeView().padding(28).frame(width: 760).background(.background)), NSSize(width: 760, height: 760)))
            // the journal shows the real logs of this mac: not for the README
            for page in Page.allCases where page != .journal {
                shots.append((page.rawValue, AnyView(PageHost(page: page).fixedSize()), NSSize(width: 860, height: 900)))
            }
            // the menu bar icon, both states, enlarged
            for running in [true, false] {
                let icon = MenuBarIcon.image(running: running)
                let big = NSImage(size: NSSize(width: 144, height: 144), flipped: false) { r in
                    NSColor(white: dark ? 0.15 : 0.95, alpha: 1).setFill(); r.fill()
                    let tinted = icon.copy() as! NSImage
                    tinted.isTemplate = false
                    tinted.draw(in: r.insetBy(dx: 18, dy: 18))
                    return true
                }
                if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(folder)/menubar-\(running ? "on" : "off").png"))
                }
            }
            for (name, view, size) in shots {
                if name == "diagnostics" { await model.runDiagnostics() }
                let host = NSHostingView(rootView: view.environment(model))
                // on screen but transparent: split views build their columns only in a visible window
                let window = NSWindow(
                    contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered, defer: false)
                window.contentView = host
                window.alphaValue = 0.01
                window.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1.2))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(folder)/\(name)\(dark ? "-dark" : "").png"))
                }
                window.orderOut(nil)
            }
            NSApp.terminate(nil)
        }
    }
}

/// the state the README screenshots show: the adaptive strategy at work, no VPN
@MainActor
private func demo(_ model: AppModel) {
    model.demo = true
    var s = model.status
    s.installed = true; s.running = true; s.strategy = Strategy.adaptive.name; s.scope = "smart"
    s.game = "off"; s.autostart = true; s.autofix = true; s.autoupdate = true; s.vpn = false; s.found = 0
    s.telegram = true; s.telegramRunning = true; s.telegramConnected = true; s.telegramLink = "tg://proxy?server=127.0.0.1&port=1443&secret=dd00"
    s.flowsealTelegram = false; s.ladder = 3; s.previous = ""
    model.status = s
    // nothing of this Mac: its found sites and own lists stay out of the pictures
    model.found = []
    model.loadLists()
    model.youtube = .ok("6,8 МБ/с"); model.discord = .ok(nil); model.voice = .ok(nil)
    model.remoteVersion = s.version
    let now = Int(Date().timeIntervalSince1970)
    model.ladderLive = LadderLive(
        sites: [
            .init(site: "sn-4g5e6nsz.googlevideo.com", connections: 412, last: now, rung: 4, kbps: 6100, trick: "macos (ALT3)"),
            .init(site: "youtube.com", connections: 160, last: now, rung: 4, kbps: 2300, trick: "macos (ALT3)"),
            .init(site: "discord.com", connections: 95, last: now, rung: 2, kbps: 1800, trick: "macos (ALT)"),
            .init(site: "github.com", connections: 60, last: now, rung: 1, kbps: 3900, trick: "macos"),
        ],
        events: [
            .init(time: "30.10.2026 14:02:11", site: "sn-4g5e6nsz.googlevideo.com", rung: 4, reason: "faster"),
            .init(time: "30.10.2026 13:47:30", site: "discord.com", rung: 2, reason: "rst"),
        ])
}

/// The content of a page as MainView shows it: the split view itself can't be captured offscreen
private struct PageHost: View {
    let page: Page
    @State private var current: Page

    init(page: Page) {
        self.page = page
        _current = State(initialValue: page)
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Theme.glow.opacity(0.28), Theme.auroraColors[2].opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 340)
            Group {
                switch page {
                case .home: HomePage(page: $current)
                case .strategies: StrategiesPage()
                case .adaptive: AdaptivePage()
                case .sites: SitesPage()
                case .diagnostics: DiagnosticsPage()
                case .journal: EmptyView()
                case .settings: SettingsPage()
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 36)
        }
        .frame(width: 860)
        .background(.background)
    }
}
