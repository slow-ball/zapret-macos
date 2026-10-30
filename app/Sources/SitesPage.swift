import SwiftUI

struct SitesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Сайты", subtitle: "Какие сайты обрабатывает zapret и что делать, если какой-то не открывается.")
            HStack(spacing: 12) {
                ScopeCard(value: "all", symbol: "globe", title: "Все сайты", text: "Всё, кроме исключений")
                ScopeCard(
                    value: "smart", symbol: "sparkle.magnifyingglass", title: "Умный", text: "Заблокированные и те, что не открылись — остальное как есть")
                ScopeCard(value: "lists", symbol: "list.bullet", title: "По спискам", text: "YouTube, Discord и свои сайты")
            }
            .fixedSize(horizontal: false, vertical: true)
            SiteCheckCard()
            // only the smart mode finds sites
            if model.status.scope == "smart" || !model.found.isEmpty {
                HStack {
                    Text("Найденные сайты").font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    if model.learning {
                        ProgressView().controlSize(.small)
                        Button("Отменить") { model.learnJob?.cancel() }
                            .buttonStyle(PillButtonStyle(tint: .gray, size: .small))
                    } else {
                        Button {
                            Task { await model.learn() }
                        } label: {
                            Label("Подобрать стратегии", systemImage: "wand.and.stars")
                        }
                        .disabled(model.found.isEmpty)
                    }
                    Button("Очистить", role: .destructive) { Task { await model.clearFound() } }.disabled(model.found.isEmpty)
                }
                if model.found.isEmpty {
                    Card {
                        Text("Пока ничего: сайты появятся здесь, когда не откроются без обхода.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else {
                    Card(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(model.found) { f in
                                HStack {
                                    Image(systemName: "globe").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.site).font(.system(size: 13, weight: .medium))
                                        if let why = f.whyText {
                                            Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if !f.strategy.isEmpty {
                                        Text(f.strategy).font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(Theme.glow.opacity(0.15), in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                if f != model.found.last { Divider().padding(.leading, 12) }
                            }
                        }
                    }
                }
            }
            ListEditor(title: "Мои сайты", subtitle: "Обрабатываются в любом режиме, вместе с YouTube и Discord", exclusions: false)
            ListEditor(title: "Исключения", subtitle: "Эти сайты zapret никогда не трогает", exclusions: true)
            HStack {
                if model.listsChanged {
                    Button {
                        Task { await model.applyLists() }
                    } label: {
                        Label("Применить изменения", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.glow)
                }
                Spacer()
                Button("Открыть файлы в редакторе") { model.openLists() }.buttonStyle(.link)
            }
        }
        .task {
            await model.refreshFound()
            model.loadLists()
        }
    }

}

/// One of the three scopes, as a selectable card
struct ScopeCard: View {
    @Environment(AppModel.self) private var model
    let value: String
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        let selected = model.status.scope == value
        Button {
            Task { await model.setScope(value) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.aurora))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                }
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                Text(text).font(.system(size: 12)).opacity(selected ? 0.9 : 0.6).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.aurora)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.045))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.spring, value: selected)
    }
}

struct SiteCheckCard: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Сайт не открывается?", systemImage: "questionmark.app.dashed")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(
                    "Адрес попадёт в «Мои сайты», для него подберётся своя стратегия, если основная его не открывает, и zapret проверит его так, как открывает браузер."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("например, example.com", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { check() }
                    Button {
                        check()
                    } label: {
                        if model.siteChecking { ProgressView().controlSize(.small).frame(width: 70) } else { Text("Проверить").frame(width: 70) }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.glow)
                    .disabled(address.isEmpty || model.siteChecking)
                }
                if let r = model.siteResult { result(r) }
            }
        }
        .animation(Theme.spring, value: model.siteResult)
    }

    private func check() {
        guard !address.isEmpty else { return }
        Task { await model.checkSite(address) }
    }

    @ViewBuilder private func result(_ r: SiteResult) -> some View {
        if let e = r.error {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.system(size: 13))
        } else if r.works {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(r.site) открывается", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if r.direct {
                    Text("Он открывается и без обхода — если в браузере не работает, дело не в провайдере: попробуйте перезапустить браузер.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if !r.strategy.isEmpty {
                    Text("Для него включена своя стратегия: \(r.strategy)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        } else if let why = r.reason, why != "dpi", why != "open" {
            reason(r, why)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(r.site) всё ещё не открывается", systemImage: "xmark.circle.fill").foregroundStyle(Theme.bad)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(
                    r.direct
                        ? "Без обхода он открывается — возможно, сайту мешает сама стратегия: добавьте его в исключения."
                        : "Можно подобрать другую основную стратегию: автоподбор проверит все."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
                if r.direct {
                    Button("В исключения") { model.addToList(r.site, exclusions: true) }
                } else {
                    Button("Подобрать стратегию") { Task { await model.runCheck() } }
                }
            }
        }
    }

    /// not a block of the site's name: a strategy can't help, so the reason and what can
    @ViewBuilder private func reason(_ r: SiteResult, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch why {
            case "dns":
                Label("Провайдер подменяет адрес \(r.site)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Сайт на месте, но DNS провайдера отдаёт вместо него заглушку. Поможет независимый DNS.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Поставить DNS 1.1.1.1") { Task { await model.applyFix("dns") } }
            case "geo":
                Label("\(r.site) сам не пускает из России", systemImage: "globe.badge.chevron.backward").foregroundStyle(Color.purple)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(
                    (r.dns ?? "").isEmpty
                        ? "Это не провайдер, а сам сервис: подмена пакетов тут не поможет. Откроется через DNS для нейросетей."
                        : "Это не провайдер, а сам сервис. Включённый DNS его не открывает — попробуйте другой."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if r.dns != "webshift" {
                        Button {
                            Task { await model.setDNS("webshift") }
                        } label: {
                            Text(verbatim: "WebShift DNS")
                        }
                    }
                    if r.dns != "dnsai" {
                        Button {
                            Task { await model.setDNS("dnsai") }
                        } label: {
                            Text(verbatim: "DNS-AI")
                        }
                    }
                }
            case "ip":
                Label("Заблокирован сам адрес сервера \(r.site)", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.bad)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Провайдер не пускает к самому серверу, а не по имени сайта — подмена пакетов тут не поможет.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            default:
                Label("Сайта \(r.site) нет", systemImage: "questionmark.circle.fill").foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Такого адреса не существует: опечатка, или сайт закрылся.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// why a site doesn't open, in a word: what zapret is for, what the DNS is for, what nothing helps with
struct ReasonBadge: View {
    let reason: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .help(help)
    }

    private var title: LocalizedStringKey {
        switch reason {
        case "open": "открывается и так"
        case "dpi": "нужен zapret"
        case "dns": "подмена адреса"
        case "geo": "закрыт для России"
        case "ip": "заблокирован адрес"
        default: "нет такого сайта"
        }
    }

    private var tint: Color {
        switch reason {
        case "open": Theme.ok
        case "dpi": Theme.glow
        case "dns": Theme.warn
        case "geo": .purple
        case "ip": Theme.bad
        default: .gray
        }
    }

    private var help: LocalizedStringKey {
        switch reason {
        case "open": "Без обхода открывается — в списке он не обязателен"
        case "dpi": "Провайдер режет по имени сайта — это работа zapret"
        case "dns": "Провайдер подменяет адрес — поможет DNS 1.1.1.1"
        case "geo": "Сервис сам не пускает из России — поможет DNS для нейросетей"
        case "ip": "Заблокирован сам адрес сервера — zapret тут не поможет"
        default: "Адреса не существует"
        }
    }
}

struct ListEditor: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let exclusions: Bool
    @State private var input = ""

    var body: some View {
        let items = exclusions ? model.myExclusions : model.mySites
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if !exclusions, !items.isEmpty {
                    if model.sitesChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await model.checkMySites() }
                        } label: {
                            Label("Проверить мои сайты", systemImage: "checklist")
                        }
                        .buttonStyle(PillButtonStyle(tint: .gray))
                        .help("Почему каждый сайт открывается или нет — без обхода, за несколько секунд")
                    }
                }
            }
            Card(padding: 8) {
                VStack(spacing: 0) {
                    ForEach(items, id: \.self) { d in
                        HStack {
                            Image(systemName: exclusions ? "nosign" : "globe").foregroundStyle(.secondary)
                            Text(d).font(.system(size: 13))
                            Spacer()
                            if !exclusions, let why = model.siteReasons[d] { ReasonBadge(reason: why) }
                            Button {
                                model.removeFromList(d, exclusions: exclusions)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain).help("Убрать")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        Divider().padding(.leading, 8)
                    }
                    HStack {
                        TextField(exclusions ? "Добавить исключение" : "Добавить сайт", text: $input)
                            .textFieldStyle(.plain)
                            .onSubmit(add)
                        Button("Добавить", action: add).disabled(input.isEmpty)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
        }
    }

    private func add() {
        model.addToList(input, exclusions: exclusions)
        input = ""
    }
}
