import SwiftUI

/// Visual language: deep aurora gradient for "on", soft materials, continuous corners, rounded type
enum Theme {
    static let aurora = LinearGradient(
        colors: [Color(red: 0.18, green: 0.83, blue: 0.75), Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.55, green: 0.36, blue: 0.96)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// the logo ribbon: aurora running into pink, as on the app icon
    static let ribbon = LinearGradient(
        colors: [
            Color(red: 0.18, green: 0.86, blue: 0.78), Color(red: 0.24, green: 0.52, blue: 1.0),
            Color(red: 0.58, green: 0.36, blue: 0.98), Color(red: 0.98, green: 0.36, blue: 0.62),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let idle = LinearGradient(
        colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.35)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let glow = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let ok = Color(red: 0.19, green: 0.82, blue: 0.53)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let warn = Color(red: 1.0, green: 0.7, blue: 0.2)
    static let radius: CGFloat = 18
    /// rows of the menu bar panel and the panel itself: its padding (16) around them keeps the corners concentric
    static let rowRadius: CGFloat = 14
    static let panelRadius: CGFloat = 30
    static let auroraColors = [
        Color(red: 0.18, green: 0.86, blue: 0.78), Color(red: 0.24, green: 0.52, blue: 1.0),
        Color(red: 0.58, green: 0.36, blue: 0.98), Color(red: 0.98, green: 0.36, blue: 0.62),
    ]
    // the services' own colors
    static let youtube = Color(red: 1.0, green: 0.2, blue: 0.2)
    static let discord = Color(red: 0.35, green: 0.40, blue: 0.95)
    static let telegram = Color(red: 0.16, green: 0.62, blue: 0.92)
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
    }
}

/// The big round switch: aurora gradient and glow while zapret works
struct PowerButton: View {
    let on: Bool
    let busy: Bool
    var size: CGFloat = 96
    /// on a gradient card: frosted white instead of a second gradient
    var onGradient = false
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if onGradient {
                    Circle()
                        .fill(.white.opacity(on ? 0.22 : 0.16))
                        .shadow(color: .black.opacity(0.12), radius: size * 0.12, y: 4)
                } else {
                    Circle()
                        .fill(on ? Theme.aurora : Theme.idle)
                        .shadow(color: on ? Theme.glow.opacity(0.55) : .clear, radius: size * 0.22)
                }
                Circle()
                    .strokeBorder(.white.opacity(on ? 0.35 : 0.15), lineWidth: 1)
                if busy {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: on)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(pressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onLongPressGesture(minimumDuration: 0, pressing: { p in withAnimation(Theme.spring) { pressed = p } }, perform: {})
        .animation(Theme.spring, value: on)
        .accessibilityLabel(on ? "Остановить zapret" : "Запустить zapret")
    }
}

/// A localized string where code needs a String: toasts, notifications, menus.
/// Russian is the source language; the translations are in app/en.lproj
func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

/// A health check: YouTube, Discord, voice
struct HealthPill: View {
    let title: LocalizedStringKey
    let symbol: String
    let state: Health.State

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(height: 22)
                .overlay(alignment: .bottomTrailing) { indicator.font(.system(size: 11, weight: .bold)).offset(x: 8, y: 5) }
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(detail).font(.system(size: 10, weight: .medium)).opacity(0.75).lineLimit(1)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .animation(Theme.spring, value: state)
    }

    private var detail: String {
        switch state {
        case .ok(let s): s ?? L("работает")
        case .fail: L("не работает")
        case .checking: L("проверка…")
        case .unknown: " "
        }
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .checking: Image(systemName: "ellipsis.circle.fill").symbolEffect(.pulse)
        case .ok: Image(systemName: "checkmark.circle.fill").transition(.scale.combined(with: .opacity))
        case .fail: Image(systemName: "xmark.circle.fill").transition(.scale.combined(with: .opacity))
        case .unknown: Image(systemName: "circle.dashed")
        }
    }

    private var tint: Color {
        switch state {
        case .ok: Theme.ok
        case .fail: Theme.bad
        default: .secondary
        }
    }
}

/// Windows — the Windows version's strategies, macOS — our own and the ones the deep search found
struct KindBadge: View {
    let kind: String

    var body: some View {
        Text(kind)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                kind == "Windows"
                    ? AnyShapeStyle(Theme.aurora) : kind == Strategy.adaptiveKind ? AnyShapeStyle(Theme.ribbon) : AnyShapeStyle(Color.indigo.gradient),
                in: Capsule()
            )
            .foregroundStyle(.white)
    }
}

struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    func sectionTitle() -> some View {
        font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
    }
}

/// A rounded square with a symbol, as in System Settings and on iOS
struct IconTile: View {
    let symbol: String
    let gradient: LinearGradient
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(gradient)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

/// A rounded capsule button: the main actions of cards
struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.glow
    /// the text color; by default white on a color, primary on gray
    var text: Color?
    /// the size: small in rows of the menu bar panel, large for the main actions
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 12 : 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 11 : 14)
            .padding(.vertical, size == .small ? 4 : size == .large ? 9 : 6)
            .background(tint.opacity(tint == .gray ? 0.18 : 1), in: Capsule())
            .foregroundStyle(text ?? (tint == .gray ? Color.primary : .white))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// The label of a menu that looks like a gray pill: the choice and ⌃⌄, no system blue
struct PillMenuLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.18), in: Capsule())
        .contentShape(Capsule())
    }
}

extension View {
    /// a menu with a custom label: no system button around it and no arrow of its own
    func plainMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    /// the surface of cards: soft fill, hairline border, continuous corners
    func glassCard(hover: Bool = false) -> some View {
        background(Color.primary.opacity(hover ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// The large title of a page, with a line under it
struct PageHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 34, weight: .heavy, design: .rounded))
            if let subtitle {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
