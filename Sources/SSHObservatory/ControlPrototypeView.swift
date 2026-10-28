import SwiftUI
import Foundation

/// Owner console; feature availability comes from the authenticated сервер package.
struct ControlPrototypeView: View {
    @State private var section: ControlPrototypeSection = .requests
    @StateObject private var control:ControlAPIModel
    @StateObject private var console:ControlConsoleModel
    @StateObject private var metadata:ControlMetadataModel
    @State private var showingConnection = false
    init(){let c=ControlAPIModel();_control=StateObject(wrappedValue:c);_console=StateObject(wrappedValue:ControlConsoleModel(legacy:c));_metadata=StateObject(wrappedValue:ControlMetadataModel(legacy:c))}

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.title).font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(section.subtitle).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Label(control.busy && !control.connected ? "Подключение к API сервер…":console.ready ? "API подключён · управление сервер":control.connected ? "API подключён · владельческие ключи" : "API сервер не подключён", systemImage: "network")
                        Spacer()
                        if control.connected || control.busy {
                            Button(control.connected ? "Отключить API":"Отменить подключение") {
                                metadata.disconnect();console.disconnect();control.disconnect()
                            }
                        } else if control.profile != nil {
                            Button("Подключить API") { Task { await control.connectSavedProfile() } }
                        }
                        Button("Настроить API") { showingConnection = true }.disabled(control.busy || console.busy || metadata.busy)
                    }
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    if let notice=control.notice { Text(notice).foregroundStyle(.orange) }
                    if let notice=console.notice { Text(notice).foregroundStyle(.orange) }
                    if console.journalBlocked{Text("Журнал расширенного управления недоступен. Новые изменения заблокированы до сверки операции.").foregroundStyle(.orange)}
                    ControlOverviewPanel(model:metadata)
                    content
                    MetadataOperationPanel(model:metadata)
                    ConsoleOperationPanel(model:console)
                    Text("Доступность действий подтверждает сервер. Постановка в очередь, изменение доступа, оплата и доставка проверяются отдельно.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 870, minHeight: 620)
        .task { await control.connectSavedProfileIfNeeded() }
        .sheet(isPresented:$showingConnection) { ControlAPIConnectionSheet(model:control) }
        .onChange(of:control.connectionSessionID){_,_ in console.disconnect();metadata.disconnect();if control.connected{Task{await console.connect()};Task{await metadata.connect()}}}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in metadata.disconnect();console.disconnect();control.disconnect() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("УПРАВЛЕНИЕ VPN").font(.caption).tracking(1)
                .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 12)
            ForEach(ControlPrototypeSection.allCases) { item in
                Button { section = item } label: {
                    Label(item.title, systemImage: item.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9).padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                .background(section == item ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer(minLength: 22)
            Label("Контур сервер", systemImage: "server.rack").font(.callout)
            Text(console.ready ? "API · управление":control.connected ? "API · владельческие ключи" : "API не подключён").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .requests: ControlConsoleWorkspace(model:console,area:.requests,metadata:metadata).id(section.rawValue)
        case .clients: ControlConsoleWorkspace(model:console,area:.clients,metadata:metadata).id(section.rawValue)
        case .ownerKeys: ControlOwnerKeysWorkspace(model:control,console:console,metadata:metadata)
        case .referrals: ControlConsoleWorkspace(model:console,area:.referrals,metadata:metadata).id(section.rawValue)
        case .attention: ControlConsoleWorkspace(model:console,area:.attention,metadata:metadata).id(section.rawValue)
        }
    }
}

private enum ControlPrototypeSection: String, CaseIterable, Identifiable {
    case requests, clients, ownerKeys, referrals, attention
    var id: String { rawValue }
    var title: String {
        switch self {
        case .requests: return "Заявки"
        case .clients: return "Клиенты"
        case .ownerKeys: return "Мои ключи"
        case .referrals: return "Рефералы"
        case .attention: return "Требуют внимания"
        }
    }
    var subtitle: String {
        switch self {
        case .requests: return "От обращения клиента до счёта и выдачи доступа."
        case .clients: return "Профиль, устройства, платежи и история выбранного клиента."
        case .ownerKeys: return "Ручные владельческие ключи и общая подписка."
        case .referrals: return "Приглашения, решения и начисление бонусов."
        case .attention: return "Проблемы выдачи, доставки, учёта и операций."
        }
    }
    var icon: String {
        switch self {
        case .requests: return "tray"
        case .clients: return "person.crop.rectangle.stack"
        case .ownerKeys: return "key"
        case .referrals: return "person.2"
        case .attention: return "exclamationmark.bubble"
        }
    }
}

private struct PrototypeRequestsView: View {
    @State private var query = ""
    @State private var filter = "Ожидают решения"
    @State private var reason = ""
    private let filters = ["Ожидают решения", "Ожидают оплаты", "Выдаются", "Завершены"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PrototypeSearchFilter(query: $query, filter: $filter, options: filters)
            PrototypeEmptySource(title: "Заявки не загружены", icon: "tray", selection: filter, query: query)
            GroupBox("Карточка заявки") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Выберите заявку после подключения сервер. Здесь будут получатель, число устройств, срок, стоимость и состояние.")
                        .foregroundStyle(.secondary)
                    Text("Платная заявка: 1–5 новых устройств и 1–6 периодов по 30 дней.")
                        .font(.callout)
                    Text("Выставленный счёт, оплаченный заказ и готовый ключ — разные состояния.")
                        .font(.caption).foregroundStyle(.secondary)
                    PrototypeField(title: "Причина бесплатной выдачи или отклонения") {
                        TextField("Причина решения", text: $reason).textFieldStyle(.roundedBorder)
                    }
                    PrototypeDisabledActions(actions: ["Одобрить и отправить счёт Stars", "Выдать бесплатно", "Отклонить", "Заменить неоплаченный счёт подарком", "Отменить подготовленное решение"])
                    Text("Замена допустимого неоплаченного счёта подарком: один ключ на 30 дней с безлимитным трафиком. Перед изменением требуется сводка и подтверждение.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private enum PrototypeClientPane: String, CaseIterable, Identifiable {
    case profile = "Профиль", devices = "Устройства", archive = "Архив", payments = "Платежи и возвраты"
    case history = "История", referrals = "Рефералы", support = "Обращения"
    var id: String { rawValue }
}

private struct PrototypeClientsView: View {
    @State private var query = ""
    @State private var filter = "Все"
    @State private var pane: PrototypeClientPane = .profile
    private let filters = ["Все", "Активные", "Истёкшие", "Ожидают оплаты или выдачи", "Заблокированные"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PrototypeSearchFilter(query: $query, filter: $filter, options: filters)
            HStack(alignment: .top, spacing: 16) {
                GroupBox("Список клиентов") {
                    PrototypeEmptySource(title: "Клиенты не загружены", icon: "person.2", selection: filter, query: query)
                }.frame(width: 205)
                GroupBox("Карточка клиента") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Клиент не выбран").font(.headline)
                        Text("Источник сервер ещё не подключён.").foregroundStyle(.secondary)
                        Picker("Содержимое карточки", selection: $pane) {
                            ForEach(PrototypeClientPane.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu)
                        clientPane
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
    @ViewBuilder private var clientPane: some View {
        switch pane {
        case .profile:
            PrototypeSummaryRow(title: "Telegram ID / имя", value: "Не загружено")
            PrototypeSummaryRow(title: "Места для устройств", value: "Не загружено")
            Text("Число клиентов, действующих доступов, устройств и одновременно онлайн — разные показатели.")
                .font(.caption).foregroundStyle(.secondary)
            PrototypeDisabledActions(actions: ["Подготовить отдельный подарок на 30 дней"])
        case .devices, .archive:
            Text(pane == .archive ? "Архив отозванных устройств пока не загружен." : "Действующие устройства пока не загружены.")
                .foregroundStyle(.secondary)
            PrototypeKeyActions()
            Text("Название и заметка устройства — отдельное будущее дополнение приложения. В действующем боте их нет; ключ от подписи не меняется.")
                .font(.caption).foregroundStyle(.secondary)
        case .payments:
            Text("Платежи и заказы не загружены. Полный возврат Stars доступен только для допустимого платежа, с причиной и подтверждением.")
                .foregroundStyle(.secondary)
            PrototypeDisabledActions(actions: ["Открыть заказ", "Подготовить полный возврат", "Подтвердить возврат"])
            Text("Результат возврата: ожидающий, подтверждённый, отклонённый или неизвестный. До подтверждения Telegram права клиента не меняются; после затрагивается только соответствующий заказ.")
                .font(.caption).foregroundStyle(.secondary)
        case .history:
            Text("История действий, уведомления и подробности событий появятся в этой карточке.")
                .foregroundStyle(.secondary)
            PrototypeDisabledActions(actions: ["Открыть событие"])
        case .referrals:
            Text("Приглашения и реферальные бонусы выбранного клиента пока не загружены.")
                .foregroundStyle(.secondary)
            PrototypeDisabledActions(actions: ["Открыть приглашение", "Открыть бонусы"])
        case .support:
            Text("Обращения через «Помощь» и /paysupport, связанные заявки и результаты будут показаны здесь.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PrototypeOwnerKeysView: View {
    @State private var archive = false
    @State private var creating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Ключи", selection: $archive) {
                    Text("Действующие").tag(false)
                    Text("Архив").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                Spacer()
                Button(creating ? "Закрыть форму" : "Создать ключ") { creating.toggle() }
                    .buttonStyle(.borderedProminent)
            }
            if creating {
                PrototypeOwnerKeyWizard()
            } else {
                PrototypeEmptySource(title: archive ? "Архив ключей не загружен" : "Мои ключи не загружены", icon: "key", selection: archive ? "Архив" : "Действующие", query: "")
                PrototypeKeyActions()
            }
            GroupBox("Общая подписка") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Повторный запрос направит общую подписку в личный Telegram владельца. В прототипе отправка отключена.")
                        .foregroundStyle(.secondary)
                    PrototypeDisabledActions(actions: ["Повторно получить общую подписку"])
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private enum PrototypeTime: String, CaseIterable, Identifiable {
    case days = "Дни", periods = "Периоды по 30 дней", unlimited = "Бессрочно"
    var id: String { rawValue }
}
private enum PrototypeTraffic: String, CaseIterable, Identifiable {
    case standard = "500 ГБ", custom = "Свой объём", unlimited = "Безлимит"
    var id: String { rawValue }
}
private enum PrototypeWizardStep { case time, traffic, summary }

private struct PrototypeOwnerKeyWizard: View {
    @State private var step: PrototypeWizardStep = .time
    @State private var time: PrototypeTime = .days
    @State private var duration = "30"
    @State private var traffic: PrototypeTraffic = .standard
    @State private var trafficGB = "500"
    @State private var validation: String?
    var body: some View {
        GroupBox("Создание владельческого ключа") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    stepLabel("1 · Срок", selected: step == .time)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    stepLabel("2 · Трафик", selected: step == .traffic)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    stepLabel("Итог", selected: step == .summary)
                }
                Divider()
                wizardContent
                if let validation {
                    Label(validation, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("Срок и трафик независимы: бессрочный ключ не означает безлимитный трафик.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: time) { _,_ in validation = nil }
        .onChange(of: duration) { _,_ in validation = nil }
        .onChange(of: traffic) { _,_ in validation = nil }
        .onChange(of: trafficGB) { _,_ in validation = nil }
    }
    private func stepLabel(_ text: String, selected: Bool) -> some View {
        Text(text).font(.callout).foregroundStyle(selected ? Color.primary : Color.secondary)
            .fontWeight(selected ? .semibold : .regular)
    }
    @ViewBuilder private var wizardContent: some View {
        switch step {
        case .time:
            PrototypeField(title: "Срок действия") {
                Picker("Срок", selection: $time) {
                    ForEach(PrototypeTime.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
                if time != .unlimited {
                    TextField(time == .days ? "Количество дней: 1–3650" : "Количество периодов: 1–120", text: $duration)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                }
            }
            Button("Далее: трафик") { validateTime() }.buttonStyle(.borderedProminent)
        case .traffic:
            PrototypeField(title: "Трафик") {
                Picker("Трафик", selection: $traffic) {
                    ForEach(PrototypeTraffic.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden()
                if traffic == .custom {
                    HStack {
                        TextField("Объём: 1–100 000", text: $trafficGB).textFieldStyle(.roundedBorder)
                        Text("ГБ").foregroundStyle(.secondary)
                    }.frame(maxWidth: 300)
                }
                Text(time == .periods ? "Выбранная квота применяется к каждому периоду по 30 дней." : "Выбранная квота относится ко всему сроку ключа.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Назад: срок") { validation = nil; step = .time }.buttonStyle(.bordered)
                Button("Проверить параметры") { validateTraffic() }.buttonStyle(.borderedProminent)
            }
        case .summary:
            Text("Предпросмотр параметров").font(.headline)
            PrototypeSummaryRow(title: "Срок", value: timeSummary)
            PrototypeSummaryRow(title: time == .periods ? "Трафик на период" : "Трафик всего", value: trafficSummary)
            Text("Формат проверен локально. Актуальные права, состояние ядра и реальная выдача ещё не проверялись.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Назад: трафик") { validation = nil; step = .traffic }.buttonStyle(.bordered)
                Button("Создать и выдать") {}.buttonStyle(.borderedProminent).disabled(true)
            }
            Text("Подтверждение создания отключено до подключения сервер. Подписка не создавалась и не отправлялась.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var timeSummary: String {
        switch time {
        case .days: return "\(Int(duration) ?? 0) дн."
        case .periods: return "\(Int(duration) ?? 0) × 30 дней"
        case .unlimited: return "Бессрочно"
        }
    }
    private var trafficSummary: String {
        traffic == .custom ? "\(Int(trafficGB) ?? 0) ГБ" : traffic.rawValue
    }
    private func validateTime() {
        if time != .unlimited {
            let limit = time == .days ? 3650 : 120
            guard let number = Int(duration.trimmingCharacters(in: .whitespacesAndNewlines)), (1...limit).contains(number) else {
                validation = time == .days ? "Введите целое число дней от 1 до 3650." : "Введите целое число периодов от 1 до 120."
                return
            }
            duration = String(number)
        }
        validation = nil; step = .traffic
    }
    private func validateTraffic() {
        if traffic == .custom {
            guard let number = Int(trafficGB.trimmingCharacters(in: .whitespacesAndNewlines)), (1...100_000).contains(number) else {
                validation = "Введите целое число ГБ от 1 до 100 000."; return
            }
            trafficGB = String(number)
        }
        validation = nil; step = .summary
    }
}

private struct PrototypeReferralsView: View {
    @State private var query = ""
    @State private var scope = "Все клиенты"
    @State private var filter = "Все"
    @State private var reason = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Область", selection: $scope) {
                    Text("Все клиенты").tag("Все клиенты")
                    Text("Один клиент").tag("Один клиент")
                }.pickerStyle(.menu)
                Picker("Состояние", selection: $filter) {
                    ForEach(["Все", "Ожидают решения", "Одобрены", "Отклонены", "Ожидают бонуса"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }
            TextField(scope == "Один клиент" ? "Telegram ID или имя клиента" : "Поиск приглашения или клиента", text: $query)
                .textFieldStyle(.roundedBorder)
            PrototypeEmptySource(title: "Приглашения и бонусы не загружены", icon: "person.2", selection: "\(scope) · \(filter)", query: query)
            GroupBox("Карточка приглашения") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Выберите приглашение после подключения источника.").foregroundStyle(.secondary)
                    PrototypeField(title: "Причина решения") {
                        TextField("Причина одобрения или отклонения", text: $reason).textFieldStyle(.roundedBorder)
                    }
                    PrototypeDisabledActions(actions: ["Одобрить", "Отклонить", "Подтвердить решение", "Отменить решение", "Обработать ожидающие бонусы", "Обновить сведения"])
                    Text("Обработка допустимых бонусов требует отдельного подтверждения. Уже начисленные бонусы при отклонении приглашения не отзываются.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PrototypeAttentionView: View {
    @State private var query = ""
    @State private var category = "Все категории"
    @State private var status = "Требуют внимания"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Категория", selection: $category) {
                    ForEach(["Все категории", "Выдача", "Доставка подписок", "Учёт трафика", "Платежи", "Возвраты", "Реферальные бонусы", "Управляющие операции"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Picker("Состояние", selection: $status) {
                    ForEach(["Требуют внимания", "Решены", "Приняты", "Все состояния"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }
            TextField("Поиск проблемы", text: $query).textFieldStyle(.roundedBorder)
            PrototypeEmptySource(title: "Проблемы не загружены", icon: "exclamationmark.bubble", selection: "\(category) · \(status)", query: query)
            GroupBox("Карточка проблемы") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Выберите проблему после подключения сервер. Здесь будут состояние, связанная операция и подтверждённый результат.")
                        .foregroundStyle(.secondary)
                    Text("Неизвестный результат выделяется отдельно и не повторяется автоматически. Произвольный повтор очереди не предусмотрен.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Фоновые процессы продолжают обрабатывать события, выдачу, доставку, сроки, уведомления и бонусы; этот прототип их не запускает и не останавливает.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PrototypeKeyActions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PrototypeActionGroup(title: "Срок", actions: ["Добавить 30 дней", "Добавить 1–3650 дней", "Установить дату окончания", "Добавить 1–120 полных периодов", "Сделать бессрочным"])
            PrototypeActionGroup(title: "Трафик", actions: ["Добавить 500 ГБ", "Добавить 1–100 000 ГБ", "Включить безлимит", "Отключить безлимит"])
            PrototypeActionGroup(title: "Доступ", actions: ["Приостановить", "Возобновить", "Окончательно отозвать"])
            Text("Добавить дни — продлить срок без дополнительного трафика. Полный период при продлении — 30 дней и 500 ГБ. Бессрочный срок и безлимитный трафик независимы.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PrototypeActionGroup: View {
    let title: String
    let actions: [String]
    var body: some View {
        GroupBox(title) {
            PrototypeDisabledActions(actions: actions).padding(8)
        }
    }
}

private struct PrototypeDisabledActions: View {
    let actions: [String]
    private let columns = [GridItem(.adaptive(minimum: 160), alignment: .leading)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
            ForEach(actions, id: \.self) { action in
                Button(action) {}.buttonStyle(.bordered).disabled(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PrototypeField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

private struct PrototypeSearchFilter: View {
    @Binding var query: String
    @Binding var filter: String
    let options: [String]
    var body: some View {
        HStack {
            TextField("Telegram ID или имя пользователя", text: $query).textFieldStyle(.roundedBorder)
            Picker("Фильтр", selection: $filter) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).frame(maxWidth: 240)
        }
    }
}

private struct PrototypeEmptySource: View {
    let title: String
    let icon: String
    let selection: String
    let query: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            VStack(spacing: 5) {
                Text("Источник сервер ещё не подключён.")
                Text("Выбранный вид: \(selection)")
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Поиск: \(query)")
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 165)
    }
}

private struct PrototypeSummaryRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
