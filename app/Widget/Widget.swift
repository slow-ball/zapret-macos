import SwiftUI
import WidgetKit

/// What the app writes into the widget's container (Library/Application Support/status.json)
struct WidgetStatus: Decodable {
    var running = false
    var strategy = ""
    var engine = ""
    var youtube: Bool?
    var discord: Bool?
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let status: WidgetStatus
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, status: WidgetStatus(running: true, strategy: "general (ALT13)", engine: "nfqws", youtube: true, discord: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : StatusEntry(date: .now, status: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // the app asks for a reload on every change; this is only a fallback
        completion(Timeline(entries: [StatusEntry(date: .now, status: load())], policy: .after(.now.addingTimeInterval(900))))
    }

    private func load() -> WidgetStatus {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/status.json")
        guard let data = try? Data(contentsOf: url) else { return WidgetStatus() }
        return (try? JSONDecoder().decode(WidgetStatus.self, from: data)) ?? WidgetStatus()
    }
}

private let aurora = LinearGradient(
    colors: [
        Color(red: 0.18, green: 0.86, blue: 0.78), Color(red: 0.24, green: 0.52, blue: 1.0),
        Color(red: 0.58, green: 0.36, blue: 0.98), Color(red: 0.98, green: 0.36, blue: 0.62),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing)
private let night = LinearGradient(
    colors: [Color(red: 0.10, green: 0.09, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.06)],
    startPoint: .top, endPoint: .bottom)

/// the three waves of the logo
struct WavesMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (i, phase) in [CGFloat(0), 0.5, 1.0].enumerated() {
            let y0 = rect.minY + rect.height * (0.2 + CGFloat(i) * 0.3)
            for step in 0...40 {
                let t = CGFloat(step) / 40
                let pt = CGPoint(x: rect.minX + t * rect.width, y: y0 - rect.height * 0.12 * sin(t * 2 * .pi * 1.25 + phase))
                if step == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        return path
    }
}

struct StatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        let s = entry.status
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WavesMark()
                        .stroke(s.running ? AnyShapeStyle(aurora) : AnyShapeStyle(Color.gray), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .frame(width: 22, height: 16)
                    Text("zapret").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
                Text(s.running ? "Работает" : "Остановлен")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(s.running ? AnyShapeStyle(aurora) : AnyShapeStyle(Color.white.opacity(0.7)))
                Text(s.strategy.hasPrefix("nfqws ") ? String(s.strategy.dropFirst(6)) : s.strategy)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            if family == .systemMedium {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Link(destination: URL(string: "zapret://toggle")!) {
                        Label(s.running ? "Выключить" : "Включить", systemImage: "power")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(s.running ? AnyShapeStyle(Color.white.opacity(0.12)) : AnyShapeStyle(aurora), in: Capsule())
                    }
                    Link(destination: URL(string: "zapret://check")!) {
                        Label("Подобрать", systemImage: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    HStack(spacing: 10) {
                        dot("YouTube", s.youtube)
                        dot("Discord", s.discord)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 136)
            }
        }
        .containerBackground(for: .widget) { night }
        .widgetURL(URL(string: "zapret://open"))
    }

    private func dot(_ title: String, _ ok: Bool?) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok == true ? Color.green : ok == false ? Color.red : Color.gray).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: Provider()) { StatusView(entry: $0) }
            .configurationDisplayName("zapret")
            .description("Состояние и быстрый выключатель")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ZapretWidgets: WidgetBundle {
    var body: some Widget { StatusWidget() }
}
