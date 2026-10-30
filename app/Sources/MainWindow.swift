import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, strategies, adaptive, sites, diagnostics, journal, settings
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Главная"
        case .strategies: "Стратегии"
        case .adaptive: "Адаптация"
        case .sites: "Сайты"
        case .diagnostics: "Проверка"
        case .journal: "Журнал"
        case .settings: "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .strategies: "wand.and.stars"
        case .adaptive: "point.3.connected.trianglepath.dotted"
        case .sites: "globe"
        case .diagnostics: "stethoscope"
        case .journal: "list.bullet.rectangle.portrait"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .home

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    LogoMark(size: 20)
                    Text("zapret").font(.system(size: 17, weight: .heavy, design: .rounded))
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 10)
                // our own rows instead of a List: its selection is a loud accent block
                VStack(spacing: 2) {
                    ForEach(Page.allCases) { p in
                        SidebarRow(page: p, selected: page == p) { page = p }
                    }
                }
                .padding(.horizontal, 10)
                Spacer(minLength: 0)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            ZStack(alignment: .top) {
                // the color of the state at the top, like an album cover behind a playlist
                LinearGradient(colors: glowColors, startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
                    .ignoresSafeArea(edges: .top)
                    .animation(.easeInOut(duration: 0.8), value: model.status.running)
                ScrollView {
                    Group {
                        if !model.installed {
                            WelcomeView()
                        } else {
                            switch page {
                            case .home: HomePage(page: $page)
                            case .strategies: StrategiesPage()
                            case .adaptive: AdaptivePage()
                            case .sites: SitesPage()
                            case .diagnostics: DiagnosticsPage()
                            case .journal: JournalPage()
                            case .settings: SettingsPage()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
            }
            .background(.background)
            .navigationTitle("")
            .toolbarBackground(.hidden, for: .windowToolbar)
            .overlay(alignment: .bottom) {
                if let t = model.toast { Toast(text: t).padding(.bottom, 20) }
            }
            .animation(Theme.spring, value: model.toast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPage)) { n in
            if let raw = n.object as? String, let p = Page(rawValue: raw) { page = p }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recheck)) { _ in
            Task {
                if page == .diagnostics { await model.runDiagnostics() } else { await model.checkHealth(force: true) }
            }
        }
        .onChange(of: page) { _, p in UserDefaults.standard.set(p.rawValue, forKey: "page") }
        .sheet(isPresented: Binding(get: { model.whatsNew != nil }, set: { if !$0 { model.whatsNew = nil } })) {
            WhatsNewSheet(text: model.whatsNew ?? "").environment(model)
        }
        .onAppear {
            // a window of its own: show in the Dock while it is open, like a normal app
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.startPolling()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
            model.stopPolling()
        }
    }

    private var glowColors: [Color] {
        model.status.running
            ? [Theme.glow.opacity(0.28), Theme.auroraColors[2].opacity(0.10), .clear]
            : [Color.gray.opacity(0.14), .clear]
    }

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status.running ? Theme.ok : Color.gray)
                .frame(width: 8, height: 8)
                .shadow(color: model.status.running ? Theme.ok : .clear, radius: 4)
            Text(model.status.running ? "Работает" : "Выключен")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            Text(model.status.version).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// A page in the sidebar: a soft plate and a colored icon when chosen, gray otherwise
private struct SidebarRow: View {
    let page: Page
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.aurora) : AnyShapeStyle(Color.secondary))
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.8))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Color.primary.opacity(selected ? 0.09 : hover ? 0.045 : 0),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.spring, value: selected)
    }
}
