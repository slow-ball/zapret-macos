import SwiftUI

// the app's logic tests (tests/AppTests.swift) have a main of their own
#if !TESTING
    @main
#endif
struct ZapretApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    init() {
        if CommandLine.arguments.contains("--check-integrity") { Integrity.commandLine() }
        if Snapshot.folder != nil {
            let m = model
            DispatchQueue.main.async { Snapshot.run(m) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(model)
        } label: {
            MenuBarLabel(running: model.status.running)
        }
        .menuBarExtraStyle(.window)

        Window("zapret", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 540)
        }
        .defaultSize(width: 1000, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") {
                    AppModel.shared.openMainWindow?()
                    NotificationCenter.default.post(name: .openPage, object: Page.settings.rawValue)
                    Task { await AppModel.shared.checkForUpdates() }
                }
            }
            // ⌘1…⌘6 — the pages, ⌘R — check again, in the View menu
            CommandGroup(before: .sidebar) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, p in
                    Button(p.title) { NotificationCenter.default.post(name: .openPage, object: p.rawValue) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Проверить заново") { NotificationCenter.default.post(name: .recheck, object: nil) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
            }
        }
    }
}

/// the menu bar icon. It always exists, so it hands the model a way to open the main window
/// (for zapret://open from the widget)
private struct MenuBarLabel: View {
    let running: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(running: running))
            .onAppear {
                let open = openWindow
                AppModel.shared.openMainWindow = {
                    open(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
