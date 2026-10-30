import SwiftUI

/// The panel under the menu bar icon: the most used things, one click away
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.installed {
                hero
                if model.status.vpn { vpnNote }
                HStack(spacing: 6) {
                    HealthPill(title: "YouTube", symbol: "play.rectangle.fill", state: model.youtube)
                    HealthPill(title: "Discord", symbol: "bubble.left.and.bubble.right.fill", state: model.discord)
                    HealthPill(title: "Голос Discord", symbol: "waveform", state: model.voice)
                }
                strategyMenu
                telegramRow
                dnsRow
                actions
            } else {
                InstallCard()
            }
        }
        .padding(16)
        .frame(width: 344)
        .background(RoundedPanel(radius: Theme.panelRadius))
        .overlay(alignment: .bottom) {
            if let t = model.toast { Toast(text: t).padding(.bottom, 8) }
        }
        .animation(Theme.spring, value: model.toast)
        .onAppear {
            model.startPolling()
            Task { await model.checkHealth() }
            Task { await model.refreshDNS() }
        }
        .onDisappear { model.stopPolling() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LogoMark(size: 18)
            Text("zapret").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.primary)
            if model.updateAvailable {
                Text("обновление").font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.aurora, in: Capsule()).foregroundStyle(.white)
            }
            Spacer()
            Button {
                open(.home)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless).help("Открыть zapret")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless).help("Закрыть приложение (zapret продолжит работать)")
        }
        .foregroundStyle(.secondary)
    }

    private var hero: some View {
        HStack(spacing: 16) {
            PowerButton(on: model.status.running, busy: model.busy, size: 72) {
                Task { await model.toggle() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.status.running ? "Работает" : "Остановлен")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.interpolate)
                if let s = model.current {
                    HStack(spacing: 6) {
                        Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        KindBadge(kind: s.kind)
                    }
                }
                Text(scopeText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .animation(Theme.spring, value: model.status.running)
    }

    private var scopeText: String {
        let scope = ["all": L("Все сайты"), "smart": L("Умный режим"), "lists": L("По спискам")][model.status.scope] ?? ""
        return model.status.game == "off" ? scope : scope + L(" · игры")
    }

    private var vpnNote: some View {
        Label("Включён VPN — трафик идёт через него", systemImage: "network.badge.shield.half.filled")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.warn)
    }

    private var strategyMenu: some View {
        Menu {
            item(Strategy.adaptive)
            Divider()
            Section("Windows-версия") {
                ForEach(model.strategies.filter { $0.isWindows }) { s in item(s) }
            }
            Section("macOS — свои и найденные") {
                ForEach(model.strategies.filter { !$0.isWindows && !$0.isAdaptive }) { s in item(s) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.aurora)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Стратегия").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.current?.title ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Spacer()
                if let s = model.current { KindBadge(kind: s.kind) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func item(_ s: Strategy) -> some View {
        Button {
            Task { await model.start(s) }
        } label: {
            if s.name == model.status.strategy { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
        }
    }

    /// the Telegram proxy in one click
    private var telegramRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.67, blue: 0.94), Color(red: 0.13, green: 0.53, blue: 0.86)],
                        startPoint: .top, endPoint: .bottom))
                Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).offset(x: -0.5, y: 0.5)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Telegram").font(.system(size: 13, weight: .semibold))
                Text(telegramState).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            if model.telegramBusy {
                ProgressView().controlSize(.small)
            } else if model.status.telegramRunning && !model.status.telegramReachable {
                Button("Исправить") { Task { await model.restartTelegram() } }
                    .buttonStyle(PillButtonStyle(tint: Theme.warn, size: .small))
                    .fixedSize()
                    .help("Свежий список посредников и перезапуск прокси")
            } else if model.status.telegramRunning && model.status.telegramConnected {
                DoneBadge(text: "Подключено", size: 12)
            } else {
                Button(model.status.telegramRunning ? "Подключить" : "Включить") {
                    Task { await model.connectTelegramFully() }
                }
                .buttonStyle(PillButtonStyle(tint: Theme.telegram, size: .small))
                .fixedSize()
                .help("Включает прокси, если он выключен, и добавляет его в Telegram Desktop")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
    }

    /// the DNS for neural networks: the one that works, and a menu to pick another
    private var dnsRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.purple.opacity(0.8), .purple], startPoint: .top, endPoint: .bottom))
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Нейросети").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(dnsState).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            if model.dnsPending != nil {
                Button("Настройки") { model.openProfiles() }
                    .buttonStyle(PillButtonStyle(tint: .gray, size: .small)).fixedSize()
                    .help("Подтвердите профиль в Системных настройках: двойной щелчок по нему → «Установить».")
            } else {
                Menu {
                    dnsItem("", L("Выкл"))
                    dnsItem("webshift", "WebShift DNS")
                    dnsItem("dnsai", "DNS-AI")
                } label: {
                    PillMenuLabel(text: dnsShort(model.dns))
                }
                .plainMenu()
                .disabled(model.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
    }

    private func dnsItem(_ id: String, _ title: String) -> some View {
        Button {
            Task { await model.setDNS(id) }
        } label: {
            if id == model.dns { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func dnsName(_ id: String) -> String {
        switch id {
        case "webshift": "WebShift DNS"
        case "dnsai": "DNS-AI"
        default: L("Выкл")
        }
    }

    /// the pill is narrow: the names without "DNS"
    private func dnsShort(_ id: String) -> String {
        switch id {
        case "webshift": "WebShift"
        case "dnsai": "DNS-AI"
        default: L("Выкл")
        }
    }

    private var dnsState: String {
        if let p = model.dnsPending { return L("ждёт подтверждения: \(dnsName(p))") }
        return model.dns.isEmpty ? L("DNS для них выключен") : L("через \(dnsName(model.dns))")
    }

    private var telegramState: String {
        if model.status.telegramRunning && !model.status.telegramReachable { return L("Telegram не отвечает") }
        if model.status.telegramRunning { return L("прокси работает") }
        return model.status.telegram ? L("прокси не запущен") : L("прокси выключен")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                open(.strategies)
                Task { await model.runCheck() }
            } label: {
                Label("Подобрать", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(tint: Theme.glow, size: .large))
            Button {
                open(.diagnostics)
            } label: {
                Label("Диагностика", systemImage: "stethoscope").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(tint: .gray, size: .large))
        }
    }

    private func open(_ page: Page) {
        UserDefaults.standard.set(page.rawValue, forKey: "page")
        NotificationCenter.default.post(name: .openPage, object: page.rawValue)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct InstallCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    LogoMark(size: 22)
                    Text("zapret ещё не установлен").font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                Text("Понадобится пароль от мака, установка займёт около минуты.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if model.installing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small); Text("Устанавливаю…").font(.system(size: 12))
                    }
                } else {
                    Button("Установить") { Task { await model.installZapret() } }
                        .buttonStyle(.borderedProminent).tint(Theme.glow)
                }
                if let e = model.installError {
                    Text(e).font(.system(size: 11)).foregroundStyle(Theme.bad)
                }
            }
        }
    }
}

extension Notification.Name {
    static let openPage = Notification.Name("zapret.openPage")
    static let recheck = Notification.Name("zapret.recheck")
}
