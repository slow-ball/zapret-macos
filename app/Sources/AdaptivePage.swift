import SwiftUI

/// The adaptive strategy at work: the sites you use, the speed the engine measures on each and the trick it
/// keeps, and what made it move lately
struct AdaptivePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.status.strategy == Strategy.adaptive.name
        let live = model.ladderLive
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(
                title: "Адаптация",
                subtitle:
                    "Сама находит приём для каждого сайта: замечает, когда провайдер мешает или замедляет, пробует другие приёмы на части соединений и оставляет лучший."
            )
            if !on { AdaptiveCard(describe: false) }
            HStack(spacing: 12) {
                tile("\(live.sites.count)", "сайтов под присмотром", "eye.fill")
                tile("\(live.sites.filter { $0.rung > 1 }.count)", "со своим приёмом", "point.3.connected.trianglepath.dotted")
                tile("\(live.events.count)", "переключений за последнее время", "arrow.triangle.swap")
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Ваши сайты").font(.system(size: 20, weight: .bold, design: .rounded))
                Card(padding: live.sites.isEmpty ? 16 : 6) {
                    if live.sites.isEmpty {
                        Text(on ? "Сайты появятся здесь, как только вы ими воспользуетесь." : "Включите адаптивную, чтобы она начала следить за сайтами.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(live.sites) { s in
                                siteRow(s)
                                if s != live.sites.last { Divider().padding(.leading, 12) }
                            }
                        }
                    }
                }
            }
            if !live.events.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Последние переключения").font(.system(size: 20, weight: .bold, design: .rounded))
                    Card(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(live.events) { e in
                                HStack(spacing: 10) {
                                    Image(systemName: e.reason == "faster" ? "gauge.with.dots.needle.67percent" : "exclamationmark.shield")
                                        .foregroundStyle(e.reason == "faster" ? Theme.ok : Theme.warn)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(LadderLive.title(e.site)).font(.system(size: 13, weight: .medium))
                                        Text("\(e.reasonText) → приём \(e.rung)").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(e.time.split(separator: " ").last.map(String.init) ?? e.time)
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                if e != live.events.last { Divider().padding(.leading, 12) }
                            }
                        }
                    }
                }
            }
            Text("Скорость движок мерит по вашему же трафику, без тестовых запросов. Список сайтов хранится только на этом маке.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task {
            // fresh while the page is open
            while !Task.isCancelled {
                await model.refreshLadderLive()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func tile(_ value: String, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.aurora)
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded))
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
    }

    private func siteRow(_ s: LadderLive.Site) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(LadderLive.title(s.site)).font(.system(size: 13, weight: .medium))
                Text("соединений: \(s.connections)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if s.kbps > 0 {
                Text(speedText(s.kbps)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(s.trick.isEmpty ? L("приём \(s.rung)") : L("приём \(s.rung): \(s.trick)"))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.glow.opacity(s.rung > 1 ? 0.15 : 0.06), in: Capsule())
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}
