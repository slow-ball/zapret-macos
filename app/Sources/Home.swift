import SwiftUI

/// The first page: the state of zapret, the services it is for, what to do next
struct HomePage: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page
    @State private var telegramSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            hero
            if model.updateAvailable, let v = model.remoteVersion { updateBanner(v) }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Сервисы", action: ("Проверить ещё раз", { Task { await model.checkHealth(force: true) } }))
                HStack(spacing: 14) {
                    ServiceCard(
                        name: "YouTube", symbol: "play.rectangle.fill", tint: Theme.youtube,
                        state: model.youtube, detail: youtubeDetail,
                        button: ("Открыть", { open("https://www.youtube.com/") }))
                    ServiceCard(
                        name: "Discord", symbol: "bubble.left.and.bubble.right.fill", tint: Theme.discord,
                        state: model.discord, detail: discordDetail, button: ("Открыть", openDiscord))
                    telegramCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "DNS для нейросетей")
                DNSCard()
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Если что-то не так")
                HStack(spacing: 14) {
                    ActionCard(
                        symbol: "wand.and.stars", title: "Подобрать стратегию",
                        text: "Начнёт с тех, что работали раньше"
                    ) {
                        page = .strategies
                        Task { await model.runCheck() }
                    }
                    ActionCard(
                        symbol: "questionmark.app.dashed", title: "Сайт не открывается",
                        text: "Подберём способ для него"
                    ) { page = .sites }
                    ActionCard(
                        symbol: "stethoscope", title: "Проверка",
                        text: "VPN, DNS, браузеры — с кнопками «Исправить»"
                    ) { page = .diagnostics }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $telegramSheet) { TelegramSheet() }
    }

    // MARK: hero

    private var hero: some View {
        HStack(spacing: 30) {
            Orb(on: model.status.running, busy: model.busy, size: 132) { Task { await model.toggle() } }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.status.running ? "Работает" : "Выключен")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .contentTransition(.interpolate)
                if model.status.running, let s = model.current {
                    StrategyChip(strategy: s) { page = .strategies }
                } else {
                    Text("Нажмите на кнопку, чтобы включить").font(.system(size: 15)).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Tag(symbol: "globe", text: model.status.scope == "smart" ? "Умный режим" : model.status.scope == "lists" ? "По спискам" : "Все сайты")
                    if model.status.autofix { Tag(symbol: "arrow.triangle.2.circlepath", text: "Автопочинка") }
                    if model.status.game != "off" { Tag(symbol: "gamecontroller.fill", text: "Игры") }
                }
                .padding(.top, 4)
                if model.status.vpn {
                    Label("Включён VPN — трафик идёт через него", systemImage: "network.badge.shield.half.filled")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warn).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .animation(Theme.spring, value: model.status.running)
    }

    private func updateBanner(_ v: String) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: "sparkles", gradient: Theme.aurora)
            VStack(alignment: .leading, spacing: 2) {
                Text("Доступна версия \(v)").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Свежие стратегии и исправления").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Обновить") { Task { await model.update() } }.buttonStyle(PillButtonStyle())
        }
        .padding(14)
        .glassCard()
    }

    // MARK: services

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// the Discord app if it is installed, the website otherwise
    private func openDiscord() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.hnc.Discord") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            open("https://discord.com/app")
        }
    }

    private var youtubeDetail: String {
        switch model.youtube {
        case .ok(let s): s ?? L("работает")
        case .fail: L("не открывается")
        case .checking: L("проверяю…")
        case .unknown: " "
        }
    }

    private var discordDetail: String {
        switch (model.discord, model.voice) {
        case (.checking, _), (_, .checking): L("проверяю…")
        case (.ok, .ok): L("сайт и голос работают")
        case (.ok, .fail): L("сайт работает, голос нет")
        case (.fail, _): L("не открывается")
        default: " "
        }
    }

    private var telegramCard: some View {
        let s = model.status
        let stuck = s.telegramRunning && !s.telegramReachable
        let state: Health.State = !s.telegram ? .unknown : s.telegramRunning && !stuck ? .ok(nil) : .fail
        let connected = s.telegramRunning && s.telegramConnected && !stuck
        var button: (LocalizedStringKey, () -> Void)?
        if stuck {
            button = ("Исправить", { Task { await model.restartTelegram() } })
        } else if !connected {
            button = (s.telegramRunning ? "Подключить" : "Включить", { Task { await model.connectTelegramFully() } })
        }
        return ServiceCard(
            name: "Telegram", symbol: "paperplane.fill", tint: Theme.telegram, state: state,
            detail: !s.telegram
                ? L("прокси выключен")
                : !s.telegramRunning
                    ? L("прокси не запущен")
                    : stuck ? L("Telegram не отвечает") : L("прокси работает"),
            button: button, done: connected ? "Подключено" : nil,
            busy: model.telegramBusy, tap: { telegramSheet = true })
    }
}

/// A service zapret is for: its color, whether it works, one action
struct ServiceCard: View {
    let name: String
    let symbol: String
    let tint: Color
    let state: Health.State
    let detail: String
    var button: (LocalizedStringKey, () -> Void)?
    /// in place of the button when there is nothing left to do
    var done: LocalizedStringKey?
    var busy = false
    var tap: (() -> Void)?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                IconTile(symbol: symbol, gradient: LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom), size: 40)
                Spacer()
                StatusDot(state: state)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let button {
                if busy {
                    ProgressView().controlSize(.small).frame(height: 28)
                } else {
                    Button(button.0, action: button.1).buttonStyle(PillButtonStyle(tint: tint))
                }
            } else if let done {
                DoneBadge(text: done).frame(height: 28)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [tint.opacity(hover ? 0.20 : 0.13), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(tint.opacity(0.18)))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { tap?() }
        .onHover { hover = $0 && Snapshot.folder == nil }
        .scaleEffect(hover && tap != nil ? 1.015 : 1)
        .animation(Theme.spring, value: hover)
        .animation(Theme.spring, value: state)
    }
}

struct StatusDot: View {
    let state: Health.State

    var body: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 18))
        case .fail: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.bad).font(.system(size: 18))
        case .checking: ProgressView().controlSize(.small)
        case .unknown: Image(systemName: "circle.dashed").foregroundStyle(.tertiary).font(.system(size: 18))
        }
    }
}

/// A big tappable card that leads somewhere
struct ActionCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.aurora)
                Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(hover: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 && Snapshot.folder == nil }
        .scaleEffect(hover ? 1.015 : 1)
        .animation(Theme.spring, value: hover)
    }
}

/// The current strategy, tappable
struct StrategyChip: View {
    let strategy: Strategy
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(strategy.title).font(.system(size: 15, weight: .semibold))
                KindBadge(kind: strategy.kind)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Сменить стратегию")
    }
}

struct Tag: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label(text, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }
}

/// The power button inside a slowly turning aurora glow while zapret works
struct Orb: View {
    let on: Bool
    let busy: Bool
    var size: CGFloat = 132
    let action: () -> Void

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !on || Snapshot.folder != nil)) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 24) / 24 * 360
                Circle()
                    .fill(AngularGradient(colors: Theme.auroraColors + [Theme.auroraColors[0]], center: .center, angle: .degrees(angle)))
                    .blur(radius: size * 0.32)
                    .frame(width: size * 1.15, height: size * 1.15)
                    .opacity(on ? 0.7 : 0)
            }
            PowerButton(on: on, busy: busy, size: size, action: action)
        }
        .frame(width: size * 1.45, height: size * 1.45)
        .animation(.easeInOut(duration: 0.6), value: on)
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var action: (LocalizedStringKey, () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            if let action {
                Button(action.0, action: action.1).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// a quiet green "✓ done": set up, nothing to press
struct DoneBadge: View {
    let text: LocalizedStringKey
    var size: CGFloat = 13

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.ok)
            .transition(.scale.combined(with: .opacity))
    }
}

/// Everything about the Telegram proxy, opened from its card
struct TelegramSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = model.status
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                IconTile(
                    symbol: "paperplane.fill",
                    gradient: LinearGradient(
                        colors: [Theme.telegram.opacity(0.85), Theme.telegram],
                        startPoint: .top, endPoint: .bottom), size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Telegram").font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text("Прокси для Telegram Desktop").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.telegramBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("Прокси", isOn: Binding(get: { s.telegram }, set: { v in Task { await model.setTelegram(v) } }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.telegram)
                }
            }
            Text(
                "Telegram подключается к прокси на этом маке. Тот ведёт трафик через веб-серверы Telegram, а где провайдер их закрыл — через посредников сообщества на Cloudflare. Данные зашифрованы самим Telegram: посредники их не видят."
            )
            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if s.telegram {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        StatusDot(state: s.telegramRunning && s.telegramReachable ? .ok(nil) : .fail)
                        Text(
                            !s.telegramRunning
                                ? "Прокси не запущен"
                                : !s.telegramReachable
                                    ? "Прокси работает, но не достаёт до Telegram"
                                    : s.telegramConnected ? "Прокси работает, Telegram подключён" : "Прокси работает"
                        )
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Spacer()
                        if !s.telegramRunning || !s.telegramReachable {
                            Button("Перезапустить") { Task { await s.telegramRunning ? model.restartTelegram() : model.setTelegram(true) } }
                                .buttonStyle(PillButtonStyle(tint: Theme.warn))
                        }
                    }
                    HStack(spacing: 10) {
                        if !s.telegramConnected {
                            Button("Подключить Telegram") { model.connectTelegram() }.buttonStyle(PillButtonStyle(tint: Theme.telegram))
                        }
                        Button("Скопировать ссылку") { model.copyTelegramLink() }.buttonStyle(PillButtonStyle(tint: .gray))
                        Spacer()
                        Button {
                            Task { await model.testTelegram() }
                        } label: {
                            switch model.telegramCheck {
                            case .checking: ProgressView().controlSize(.small)
                            case .ok: Label("Telegram отвечает", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                            case .fail: Label("Не отвечает", systemImage: "xmark.circle.fill").foregroundStyle(Theme.bad)
                            case .unknown: Label("Проверить связь", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                    }
                    if s.flowsealTelegram {
                        Label("Запущено приложение TG WS Proxy — его лучше закрыть", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warn)
                    }
                }
                .padding(16)
                .glassCard()
            }
            HStack {
                Text("Свой прокси zapret, без Python. Работает от пользователя nobody.").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 560)
    }
}

/// The DNS for neural networks and services closed to Russia: off or one of two providers
struct DNSCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(
                    symbol: "sparkles", gradient: LinearGradient(colors: [Color.purple.opacity(0.8), .purple], startPoint: .top, endPoint: .bottom), size: 38)
                Text(
                    "Нейросети и сервисы, закрытые для России, откроются через сервер выбранного DNS, остальные сайты — как обычно. Это сторонние бесплатные сервисы: им видно, какие сайты вы открываете."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("DNS", selection: Binding(get: { model.dnsPending ?? model.dns }, set: { v in Task { await model.setDNS(v) } })) {
                Text("Выкл").tag("")
                Text(verbatim: "WebShift DNS").tag("webshift")
                Text(verbatim: "DNS-AI").tag("dnsai")
            }
            .labelsHidden().pickerStyle(.segmented)
            .disabled(model.busy)
            if model.dnsPending != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Подтвердите профиль в Системных настройках: двойной щелчок по нему → «Установить».")
                        .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Открыть Настройки") { model.openProfiles() }.buttonStyle(PillButtonStyle(tint: .purple))
                }
            } else if !model.dns.isEmpty {
                Label("Работает для всей системы", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ok)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
        .animation(Theme.spring, value: model.dnsPending)
        .animation(Theme.spring, value: model.dns)
        .task { await model.refreshDNS() }
    }
}
