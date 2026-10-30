import SwiftUI

/// First start: zapret is not installed yet
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            LogoMark(size: 96)
                .padding(.top, 30)
            VStack(spacing: 8) {
                Text("zapret").font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("YouTube, Discord и Telegram без тормозов")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature(
                    "wand.and.stars", L("Сам подбирает рабочий способ"),
                    L("Стратегии Windows-версии, свои для macOS и адаптивная — она сама находит приём для каждого сайта"))
                feature("arrow.triangle.2.circlepath", L("Сам чинится и обновляется"), L("Если провайдер что-то поменял, стратегия сменится сама"))
                feature("paperplane.fill", L("Telegram одной кнопкой"), L("Встроенный прокси для Telegram Desktop"))
            }
            .padding(22)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: 480)
            VStack(spacing: 10) {
                if model.installing {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Устанавливаю… около минуты").font(.system(size: 14, weight: .medium))
                    }
                    .frame(height: 44)
                } else {
                    Button {
                        Task { await model.installZapret() }
                    } label: {
                        Text("Установить").font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(width: 220, height: 44)
                            .background(Theme.aurora, in: Capsule())
                            .foregroundStyle(.white)
                            .shadow(color: Theme.glow.opacity(0.4), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)
                }
                Text("Понадобится пароль от мака: zapret меняет правила файрвола macOS.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let e = model.installError {
                    Text(e).font(.system(size: 12)).foregroundStyle(Theme.bad).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.aurora)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
