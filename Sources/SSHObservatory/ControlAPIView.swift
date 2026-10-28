import SwiftUI
import UniformTypeIdentifiers
import Security

struct ControlAPIConnectionSheet: View {
    @ObservedObject var model:ControlAPIModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint=""
    @State private var identityLabel="SSH Observatory Control"
    @State private var serverCA:Data?
    @State private var showingCA=false
    @State private var validation:String?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Подключение к API сервер").font(.title2)
            Text("Используйте адрес действующего API сервер и уже установленный клиентский сертификат. Подключение проверит доступные функции; операции требуют отдельного подтверждения.").foregroundStyle(.secondary)
            TextField("HTTPS-адрес API",text:$endpoint).textFieldStyle(.roundedBorder)
            TextField("Название клиентского сертификата в Связке ключей",text:$identityLabel).textFieldStyle(.roundedBorder)
            HStack {
                Button("Выбрать сертификат доверия сервера") { showingCA=true }
                Text(serverCA == nil ? "Не выбран":"Выбран").foregroundStyle(.secondary)
            }
            Text("Закрытый ключ остаётся в Связке ключей. Его содержимое и пароль приложение не запрашивает.").font(.caption).foregroundStyle(.secondary)
            if let text=validation ?? model.notice { Text(text).foregroundStyle(.orange) }
            HStack {
                Button("Закрыть") { dismiss() }
                Spacer()
                Button(model.busy ? "Проверка…":"Подключить API") {
                    guard let ca=serverCA else { validation="Выберите сертификат доверия сервера.";return }
                    let profile=ControlConnectionProfile(endpoint:endpoint.trimmingCharacters(in:.whitespacesAndNewlines),serverCA:ca,identityLabel:identityLabel)
                    Task { await model.connect(profile);if model.connected { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(model.busy || serverCA == nil)
            }
        }.padding(24).frame(width:600)
        .onAppear { if let p=model.profile { endpoint=p.endpoint;serverCA=p.serverCA;identityLabel=p.identityLabel } }
        // Certificate UTIs are not consistently classified as public.data on macOS.
        // Accept file selection here; the bounded DER/PEM parser below validates it.
        .fileImporter(isPresented:$showingCA,allowedContentTypes:[.item]) { result in
            do {
                let url=try result.get(),scoped=url.startAccessingSecurityScopedResource();defer{if scoped {url.stopAccessingSecurityScopedResource()}}
                let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
                var data=try handle.read(upToCount:65_537) ?? Data()
                guard data.count<=65_536 else { throw ControlAPIError.configuration }
                if let text=String(data:data,encoding:.utf8),text.contains("-----BEGIN CERTIFICATE-----") {
                    let base64=text.replacingOccurrences(of:"-----BEGIN CERTIFICATE-----",with:"").replacingOccurrences(of:"-----END CERTIFICATE-----",with:"").components(separatedBy:.whitespacesAndNewlines).joined()
                    guard let der=Data(base64Encoded:base64) else { throw ControlAPIError.configuration };data=der
                }
                guard SecCertificateCreateWithData(nil,data as CFData) != nil else { throw ControlAPIError.configuration }
                serverCA=data;validation=nil
            } catch { validation="Не удалось прочитать сертификат доверия. Выберите DER или PEM с одним сертификатом." }
        }
    }
}

struct ControlOwnerKeysWorkspace: View {
    @ObservedObject var model:ControlAPIModel
    var console:ControlConsoleModel?=nil
    var metadata:ControlMetadataModel?=nil
    @State private var archived=false
    @State private var creating=false
    @State private var extending:ControlOwnerKey?
    @State private var managing:ControlOwnerKey?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Picker("Ключи",selection:$archived) { Text("Действующие").tag(false);Text("Архив").tag(true) }.pickerStyle(.segmented).frame(maxWidth:280)
                Button("Обновить") { Task { await model.refreshKeys(archived:archived) } }.disabled(!model.connected || model.busy)
                Spacer()
                Button(creating ? "Закрыть форму":"Создать ключ") { creating.toggle() }.disabled(!model.canStart)
            }
            if !model.connected {
                ContentUnavailableView(model.busy ? "Подключение к API сервер…":"API сервер не подключён",systemImage:"network",description:Text(model.profile == nil ? "Укажите параметры подключения через «Настроить API». Реальные ключи не загружены.":"Профиль сохранён. Подключитесь к API, чтобы получить актуальные ключи."))
            } else if model.keys.isEmpty {
                ContentUnavailableView("В этой выборке нет ключей",systemImage:"key",description:Text("Ответ получен от API сервер. Новые ключи появятся после подтверждённой выдачи."))
            } else {
                ForEach(model.keys) { key in
                    GroupBox {
                        HStack(alignment:.top) {
                            VStack(alignment:.leading,spacing:6) {
                                if let metadata{MetadataKeyTitle(model:metadata,keyID:key.keyID,fallback:key.name)}else{Text(key.name).font(.headline)}
                                Text("Состояние: \(key.state)").foregroundStyle(.secondary)
                                Text(key.timeUnlimited ? "Срок бессрочный":"Окончание: \(key.expiresAt ?? "не подтверждено")").font(.caption)
                                Text(key.trafficUnlimited ? "Трафик безлимитный":"Лимит трафика: \(quota(key.limitBytes))").font(.caption)
                            }
                            Spacer()
                            if let console{Button("Управление ключом"){managing=key;Task{await console.loadDetail(path:"/v2/keys/"+key.keyID,kind:.key)}}.disabled(!console.supports("keys_read") || console.busy)}
                            Button("Продлить днями") { extending=key }.disabled(!model.canStart || archived || key.timeUnlimited)
                        }.padding(10)
                    }
                }
            }
            if creating && model.canStart { ControlOwnerIssueForm(model:model) }
            if let operation=model.pending { ControlOperationCard(model:model,operation:operation) }
            Text(console?.ready == true ? "Доступные действия определяет подключённый API сервер.":"Подключён первый API-пакет. Остальные действия появятся после установки расширенного пакета на сервере.").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of:archived) { _,value in Task { await model.refreshKeys(archived:value) } }
        .sheet(item:$extending) { key in ControlExtensionSheet(model:model,key:key) }
        .sheet(item:$managing){key in
            ScrollView{VStack(alignment:.leading,spacing:18){
                Text(key.name).font(.title2)
                if let console {
                    if let notice=console.notice{Text(notice).foregroundStyle(.orange)}
                    if let record=console.detail,record.kind == .key,record.id==key.keyID{ConsoleDetailPanel(model:console,record:record,clientScope:nil,metadata:metadata)}
                    else{Text(console.busy ? "Загрузка данных сервер…":"Данные выбранного ключа ещё не подтверждены.").foregroundStyle(.secondary)}
                    ConsoleOperationPanel(model:console)
                    if let metadata{MetadataOperationPanel(model:metadata)}
                }
                Button("Закрыть"){managing=nil}
            }.padding(24)}.frame(width:760,height:650)
        }
    }
    private func quota(_ value:Int64?) -> String { value.map { "\($0 / 1_000_000_000) ГБ" } ?? "не подтверждён" }
}

private struct ControlOwnerIssueForm: View {
    @ObservedObject var model:ControlAPIModel
    @State private var step=1
    @State private var timeMode="days"
    @State private var trafficMode="standard"
    @State private var duration="30"
    @State private var traffic="500"
    @State private var validation:String?
    var body: some View {
        GroupBox("Создание владельческого ключа") {
            VStack(alignment:.leading,spacing:14) {
                Text(step==1 ? "1 · Срок":"2 · Трафик").font(.headline)
                if step==1 {
                    Picker("Срок",selection:$timeMode) { Text("Дни").tag("days");Text("Периоды по 30 дней").tag("periods");Text("Бессрочно").tag("unlimited") }
                    if timeMode != "unlimited" { TextField(timeMode=="days" ? "1–3650 дней":"1–120 периодов",text:$duration).textFieldStyle(.roundedBorder) }
                    Button("Далее: трафик") {
                        guard timeMode=="unlimited" || validNumber(duration,max:timeMode=="days" ? 3650:120) else {validation="Проверьте количество дней или периодов.";return}
                        validation=nil;step=2
                    }
                } else {
                    Picker("Трафик",selection:$trafficMode) { Text("500 ГБ").tag("standard");Text("Свой объём").tag("custom");Text("Безлимит").tag("unlimited") }
                    if trafficMode=="custom" { TextField("1–100 000 ГБ",text:$traffic).textFieldStyle(.roundedBorder) }
                    Text(timeMode=="periods" ? "Квота на каждый период по 30 дней.":"Квота на весь выбранный срок.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Назад: срок") {validation=nil;step=1}
                        Button("Получить предпросмотр сервер") {
                            let request=ControlPreviewRequest(operationID:ControlPreviewRequest.newID(),action:.issue,timeMode:timeMode,timeValue:timeMode=="unlimited" ? nil:Int(duration),trafficMode:trafficMode,trafficGB:trafficMode=="custom" ? Int(traffic):nil)
                            do {try request.validate();validation=nil;Task{await model.prepare(request)}}catch{validation="Проверьте срок и объём трафика."}
                        }.buttonStyle(.borderedProminent).disabled(!model.canStart)
                    }
                }
                if let validation {Text(validation).foregroundStyle(.orange)}
                Text("Предпросмотр не выдаёт доступ. Создание потребует отдельного подтверждения ответа сервера.").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
    private func validNumber(_ value:String,max:Int)->Bool {Int(value).map{(1...max).contains($0)} ?? false}
}

private struct ControlExtensionSheet: View {
    @ObservedObject var model:ControlAPIModel
    let key:ControlOwnerKey
    @State private var days="30"
    @State private var validation:String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Продлить срок").font(.title2);Text(key.name)
            TextField("Количество дней: 1–3650",text:$days).textFieldStyle(.roundedBorder)
            Text("Добавление дней не добавляет трафик. Сервер проверит текущее состояние ключа.").foregroundStyle(.secondary)
            if let validation {Text(validation).foregroundStyle(.orange)}
            HStack {
                Button("Закрыть"){dismiss()};Spacer()
                Button("Получить предпросмотр сервер") {
                    let request=ControlPreviewRequest(operationID:ControlPreviewRequest.newID(),action:.extend,keyID:key.keyID,days:Int(days))
                    do {try request.validate();validation=nil;Task{await model.prepare(request);if model.pending?.request.operationID==request.operationID{dismiss()}}}catch{validation="Введите целое число дней от 1 до 3650."}
                }.buttonStyle(.borderedProminent).disabled(!model.canStart)
            }
        }.padding(24).frame(width:520)
    }
}

private struct ControlOperationCard: View {
    @ObservedObject var model:ControlAPIModel
    let operation:PendingControlOperation
    var body: some View {
        GroupBox("Последняя операция") {
            VStack(alignment:.leading,spacing:12) {
                Text(operation.request.action == .issue ? "Выдача владельческого ключа":"Продление срока").font(.headline)
                Text(operation.needsStatus ? "Нужно уточнить результат у сервера":(operation.receipt?.state.title ?? "Ожидается ответ API"))
                if operation.request.action == .issue {
                    Text(policySummary).font(.callout)
                } else if let days=operation.request.days {
                    Text("Добавить \(days) дней; объём трафика не увеличивается.").font(.callout)
                }
                if let receipt=operation.receipt { Text(receipt.summary).textSelection(.enabled) }
                if operation.receipt?.state == .prepared && operation.receipt?.confirmationToken == nil {
                    Text("Одноразовое подтверждение не сохранено после перезапуска. Дождитесь истечения подготовки и обновите результат; команда не повторялась.").font(.caption).foregroundStyle(.secondary)
                }
                if operation.receipt?.state == .unknown || operation.needsStatus {
                    Text("Команда автоматически не повторяется. Сначала обновите её результат.").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button("Обновить результат") { Task{await model.refreshOperation()} }.disabled(!model.connected || model.busy)
                    if operation.receipt?.state == .prepared {
                        TimelineView(.periodic(from:.now,by:1)) { _ in
                            HStack {
                                Button(operation.request.action == .issue ? "Подтвердить выдачу":"Подтвердить продление") { Task{await model.confirm()} }.buttonStyle(.borderedProminent).disabled(!model.canConfirm)
                                Button("Отменить подготовленное") { Task{await model.cancelPrepared()} }.disabled(!model.canConfirm)
                            }
                        }
                    }
                }
                Text("Принятие в очередь не означает, что ключ уже выдан или сообщение доставлено.").font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var policySummary:String {
        let r=operation.request
        let term=r.timeMode=="unlimited" ? "Бессрочно":r.timeMode=="periods" ? "\(r.timeValue ?? 0) периодов по 30 дней":"\(r.timeValue ?? 0) дней"
        let traffic=r.trafficMode=="unlimited" ? "безлимитный трафик":"\(r.trafficMode=="standard" ? 500:(r.trafficGB ?? 0)) ГБ"
        return "\(term) · \(traffic)"
    }
}
