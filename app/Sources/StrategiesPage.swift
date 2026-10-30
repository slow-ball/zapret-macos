import SwiftUI

/// 6,8 in Russian, 6.8 in English
func megabytes(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }

/// 850 КБ/с, 6,8 МБ/с
func speedText(_ kbps: Int) -> String {
    kbps < 1000 ? L("\(kbps) КБ/с") : L("\(megabytes(Double(kbps) / 1024)) МБ/с")
}

struct StrategiesPage: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(
                title: "Стратегии",
                subtitle: "Способы, которыми zapret обходит замедление. Какой работает у вашего провайдера, проще всего узнать автоподбором.")
            autopick
            AdaptiveCard()
            if let run = model.check { CheckCard(run: run, cancel: model.checkJob.map { job in { job.cancel() } }) }
            DeepCard()
            HStack {
                Text("Все стратегии").font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            group("Windows", "Стратегии Windows-версии от Flowseal")
            group("macOS", "Свои: разбиение пакетов и фейки; и найденные глубоким подбором")
        }
    }

    private var autopick: some View {
        HStack(spacing: 18) {
            Image(systemName: "wand.and.stars").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Автоподбор").font(.system(size: 20, weight: .heavy, design: .rounded))
                Text("Начнёт с тех, что работали раньше, и остановится на первой, с которой YouTube быстрый и работает голос Discord. Обычно меньше минуты.")
                    .font(.system(size: 12)).opacity(0.85).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 8)
            // the quick one and the full one, both clearly buttons: the full check is what helps when the
            // quick one stopped at a strategy that works but not best
            VStack(spacing: 8) {
                Button {
                    Task { await model.runCheck() }
                } label: {
                    Label("Подобрать", systemImage: "sparkles").frame(minWidth: 160)
                }
                .buttonStyle(PillButtonStyle(tint: .white.opacity(0.95), text: Theme.glow))
                Button {
                    Task { await model.runCheck(all: true) }
                } label: {
                    Label("Проверить все \(model.strategies.isEmpty ? 38 : model.strategies.count)", systemImage: "list.bullet")
                        .frame(minWidth: 160)
                }
                .buttonStyle(PillButtonStyle(tint: .white.opacity(0.22), text: .white))
                .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                Text("выберет самую быструю").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .disabled(model.check?.finished == false)
        }
        .padding(20)
        .background(Theme.aurora, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.glow.opacity(0.3), radius: 18, y: 8)
    }

    private func group(_ kind: String, _ subtitle: LocalizedStringKey) -> some View {
        let items = model.strategies.filter { $0.kind == kind && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                KindBadge(kind: kind); Text(subtitle).sectionTitle()
            }
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(items) { s in
                        StrategyRow(strategy: s, result: model.check?.results.first { $0.name == s.name })
                        if s != items.last { Divider().padding(.leading, 12) }
                    }
                }
            }
        }
    }
}

/// The adaptive strategy, on its own: one ladder of our tricks, every site climbs it to the one that works
struct AdaptiveCard: View {
    @Environment(AppModel.self) private var model
    /// false on the page of the adaptive strategy, which tells it in its own words
    var describe = true

    var body: some View {
        let on = model.status.strategy == Strategy.adaptive.name
        HStack(spacing: 14) {
            IconTile(
                symbol: "point.3.connected.trianglepath.dotted",
                gradient: LinearGradient(colors: Theme.auroraColors, startPoint: .topLeading, endPoint: .bottomTrailing), size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Адаптивная").font(.system(size: 17, weight: .bold, design: .rounded))
                    KindBadge(kind: Strategy.adaptiveKind)
                }
                if describe {
                    Text("Своя для каждого сайта: движок переключает сайт, если провайдер его оборвал или замедлил, и запоминает лучший приём.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if on, model.status.ladder > 0 {
                    Text("Свой приём уже у сайтов: \(model.status.ladder)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ok)
                }
            }
            Spacer(minLength: 8)
            if on {
                DoneBadge(text: "Включена")
            } else {
                Button("Включить") { Task { await model.start(Strategy.adaptive) } }
                    .buttonStyle(PillButtonStyle(tint: Theme.glow))
                    .disabled(model.busy)
            }
        }
        .padding(16)
        .glassCard()
    }
}

/// When no strategy helps: hundreds of options of the engine for one site
struct DeepCard: View {
    @Environment(AppModel.self) private var model
    @State private var site = "www.youtube.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(
                    symbol: "scope", gradient: LinearGradient(colors: [Color.indigo.opacity(0.8), .indigo], startPoint: .top, endPoint: .bottom), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ничего не помогло?").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(
                        "Глубокий подбор переберёт сотни вариантов для одного сайта, и найденный будет работать для него. 5–15 минут, остальной интернет работает как обычно."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let run = model.deep, !run.finished {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(run.total > 0 ? "Проверено вариантов: \(run.tested) из \(run.total)" : "Проверено вариантов: \(run.tested)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    if run.total > 0 {
                        ProgressView(value: Double(run.tested), total: Double(run.total)).frame(maxWidth: 160)
                    }
                    Spacer()
                    if model.deepJob != nil {
                        Button("Отменить") { model.cancelDeep() }
                            .buttonStyle(PillButtonStyle(tint: .gray, size: .small))
                    }
                }
                if !run.option.isEmpty {
                    Text(run.option).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                HStack {
                    TextField("сайт", text: $site).textFieldStyle(.roundedBorder)
                    Button("Глубокий подбор") { Task { await model.runDeep(site) } }
                        .buttonStyle(PillButtonStyle(tint: .indigo))
                        .disabled(site.isEmpty || model.check?.finished == false)
                }
                if let run = model.deep { result(run) }
            }
        }
        .padding(16)
        .glassCard()
        .animation(Theme.spring, value: model.deep)
    }

    @ViewBuilder private func result(_ run: DeepRun) -> some View {
        if run.cancelled {
            Label("Глубокий подбор отменён", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.system(size: 13))
        } else if let e = run.error {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.system(size: 13))
        } else if let s = run.strategy {
            Label("Найдено: «\(s)» теперь работает для \(run.site)", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        } else if run.reason == "open" {
            Label("\(run.site) открывается и без обхода — дело не в провайдере", systemImage: "info.circle.fill")
                .foregroundStyle(.secondary).font(.system(size: 13))
        } else {
            Label(
                "Ничего не нашлось: провайдер режет этот сайт так, что подмена пакетов не помогает. Можно сообщить о проблеме в «Проверке».",
                systemImage: "xmark.circle.fill"
            ).foregroundStyle(Theme.bad).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StrategyRow: View {
    @Environment(AppModel.self) private var model
    let strategy: Strategy
    let result: CheckResult?
    @State private var hover = false

    var body: some View {
        let current = strategy.name == model.status.strategy
        Button {
            Task { await model.start(strategy) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(current ? AnyShapeStyle(Theme.aurora) : AnyShapeStyle(.tertiary))
                    .font(.system(size: 16))
                Text(strategy.title).font(.system(size: 13, weight: current ? .semibold : .regular))
                Spacer()
                if let r = result {
                    if r.ok {
                        Image(systemName: r.voice ? "waveform" : "waveform.slash")
                            .foregroundStyle(r.voice ? Theme.ok : Color.secondary).help(r.voice ? "Голос в Discord работает" : "Голос в Discord не работает")
                        Text(speedText(r.kbps)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Text("не работает").font(.system(size: 12)).foregroundStyle(Theme.bad)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                hover && Snapshot.folder == nil ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct CheckCard: View {
    let run: CheckRun
    /// while it runs: stops it, the strategy from before comes back
    var cancel: (() -> Void)?
    @State private var cancelling = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if run.finished {
                        if run.cancelled {
                            Label("Подбор отменён — работает прежняя стратегия", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        } else if let best = run.best {
                            Label("Включена \(Strategy(name: best).title)", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Theme.ok)
                        } else {
                            Label(run.error ?? L("Не получилось"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.bad)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Проверено \(run.results.count) из \(run.total)")
                    }
                    Spacer()
                    if let b = run.baseline { Text("без zapret: \(b)").font(.system(size: 12)).foregroundStyle(.secondary) }
                    if !run.finished, let cancel {
                        Button(cancelling ? "Отменяю…" : "Отменить") {
                            cancelling = true
                            cancel()
                        }
                        .buttonStyle(PillButtonStyle(tint: .gray, size: .small))
                        .disabled(cancelling)
                    }
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                ProgressView(value: run.finished ? 1 : run.progress).tint(Theme.glow)
                    .animation(Theme.spring, value: run.progress)
                let working = run.results.filter(\.ok).sorted { ($0.voice ? 1 : 0, $0.kbps) > ($1.voice ? 1 : 0, $1.kbps) }
                if !working.isEmpty {
                    let top = working.prefix(5)
                    let max = Double(top.map(\.kbps).max() ?? 1)
                    ForEach(top) { r in
                        HStack(spacing: 8) {
                            Text(Strategy(name: r.name).title).font(.system(size: 12)).frame(width: 190, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Theme.aurora).frame(width: max > 0 ? g.size.width * Double(r.kbps) / max : 0)
                            }
                            .frame(height: 6)
                            Text(speedText(r.kbps)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(
                                width: 74, alignment: .trailing)
                            Image(systemName: r.voice ? "waveform" : "waveform.slash").foregroundStyle(r.voice ? Theme.ok : Color.secondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(Theme.spring, value: run.results.count)
        }
        // a new search: the button is fresh again
        .onChange(of: run.finished) { _, finished in if !finished { cancelling = false } }
    }
}
