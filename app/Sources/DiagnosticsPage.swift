import SwiftUI

struct DiagnosticsPage: View {
    @Environment(AppModel.self) private var model
    @State private var reportSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Проверка", subtitle: "zapret проверит себя, сеть и браузеры. Если что-то не так — рядом будет кнопка, чтобы исправить.")
            summary
            IntegrityCard()
            if let e = model.diagError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            }
            ForEach(model.diagnostics.filter { !$0.items.isEmpty }) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title).sectionTitle()
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(section.items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    icon(item.kind)
                                    Text(item.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if let fix = item.fix {
                                        Button(AppModel.fixTitle(fix)) { Task { await model.applyFix(fix) } }
                                            .controlSize(.small)
                                            .buttonStyle(.borderedProminent)
                                            .tint(item.kind == .info ? Color.gray : Theme.glow)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { if model.diagnostics.isEmpty { await model.runDiagnostics() } }
        .sheet(isPresented: $reportSheet) { ReportSheet() }
    }

    private var summary: some View {
        let problems = model.diagnostics.flatMap(\.items).filter { $0.kind == .bad || $0.kind == .warn }.count
        let ok = problems == 0 && !model.diagnostics.isEmpty
        let idle = model.diagRunning || model.diagnostics.isEmpty
        return HStack(spacing: 18) {
            Image(systemName: idle ? "stethoscope" : ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .symbolEffect(.pulse, isActive: model.diagRunning)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.diagRunning ? "Проверяю…" : model.diagnostics.isEmpty ? "Проверка" : ok ? "Всё в порядке" : "Есть что исправить: \(problems)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                Text(idle ? "Около 15 секунд" : ok ? "zapret, сеть и сервисы в порядке" : "Кнопки «Исправить» — рядом с проблемами")
                    .font(.system(size: 12)).opacity(0.85)
            }
            .foregroundStyle(.white)
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button(model.diagnostics.isEmpty ? "Проверить" : "Проверить снова") { Task { await model.runDiagnostics() } }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.95), text: ok ? Theme.ok : Theme.glow))
                    .disabled(model.diagRunning)
                Button("Сообщить о проблеме") { reportSheet = true }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(20)
        .background(
            ok
                ? AnyShapeStyle(
                    LinearGradient(
                        colors: [Theme.ok.opacity(0.9), Color(red: 0.1, green: 0.65, blue: 0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(Theme.aurora),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .animation(Theme.spring, value: ok)
    }

    @ViewBuilder private func icon(_ kind: DiagItem.Kind) -> some View {
        switch kind {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.bad)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
        case .info: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// The report before it goes anywhere: the user sees and may edit every line
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(
                    symbol: "ladybug.fill", gradient: LinearGradient(colors: [Color.orange.opacity(0.85), .orange], startPoint: .top, endPoint: .bottom),
                    size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Сообщить о проблеме").font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text("Откроется форма на GitHub с этим отчётом — останется указать провайдера и что не работает.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Label(
                "Адреса IP, имя пользователя и компьютера, пути заменены. Свои списки сайтов и проверенные сайты в отчёт не попадают. Текст можно поправить.",
                systemImage: "lock.shield.fill"
            )
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ok).fixedSize(horizontal: false, vertical: true)
            ZStack {
                TextEditor(text: $report)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .glassCard()
                if loading { ProgressView("Собираю отчёт…").controlSize(.small) }
            }
            .frame(height: 300)
            HStack {
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    model.show(L("Отчёт скопирован"))
                }
                .buttonStyle(PillButtonStyle(tint: .gray))
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Открыть на GitHub") {
                    model.openIssue(report)
                    dismiss()
                }
                .buttonStyle(PillButtonStyle())
                .disabled(loading)
            }
        }
        .padding(26)
        .frame(width: 620)
        .task {
            report = await model.buildReport()
            loading = false
        }
    }
}
