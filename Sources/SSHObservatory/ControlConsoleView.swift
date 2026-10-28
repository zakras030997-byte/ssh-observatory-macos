import SwiftUI

enum ConsoleArea:String {case requests,clients,referrals,attention
    var kind:ConsoleKind {switch self{case .requests:return .request;case .clients:return .client;case .referrals:return .referral;case .attention:return .attention}}
    var feature:String {switch self{case .requests:return "requests_read";case .clients:return "clients_read";case .referrals:return "referrals_read";case .attention:return "attention_read"}}
    var path:String {"/v2/"+rawValue}
    var statuses:[String] {
        switch self {
        case .requests:return ["pending","payment","processing","completed","all"]
        case .clients:return ["all","active","expired","payment","pending","blocked"]
        case .referrals:return ["all","awaiting_gift","awaiting_delivery","qualified","earned","pending","review","rejected","active","scheduled","completed"]
        case .attention:return ["all","attention","accepted","resolved"]
        }
    }
}

struct ControlConsoleWorkspace:View {
    @ObservedObject var model:ControlConsoleModel
    let area:ConsoleArea
    var metadata:ControlMetadataModel?=nil
    @State private var query=""
    @State private var status=""
    @State private var problemKind="all"
    @State private var selectedClient:ConsoleRecord?
    @State private var pane="profile"
    @State private var number=0
    @State private var localNotice:String?

    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            if !model.ready {
                ContentUnavailableView("Расширенное управление ещё не подключено",systemImage:"network",description:Text("Первый пакет «Мои ключи» работает отдельно. Остальные функции появятся после установки серверного пакета."))
                Button("Проверить расширенный API"){Task{await model.connect();await metadata?.connect()}}.disabled(!model.legacy.connected || model.busy || metadata?.busy == true)
            }else if !model.supports(area.feature) {
                Text("Сервер пока не объявил готовность этого раздела.").foregroundStyle(.secondary)
            }else{
                if let client=selectedClient {clientHeader(client)}else{filters}
                if let text=localNotice{Text(text).foregroundStyle(.orange)}
                if let page=model.page,selectedClient==nil || !["profile","support"].contains(pane) {
                    HStack{Text("Всего в этой выборке: \(page.total)").foregroundStyle(.secondary);Spacer();Button("Назад"){number=max(0,number-1);Task{await load()}}.disabled(page.page==0 || model.busy);Text("Страница \(page.page+1)");Button("Далее"){number+=1;Task{await load()}}.disabled(!page.hasMore || model.busy)}
                    if page.items.isEmpty{Text("В этой выборке записей нет.").foregroundStyle(.secondary)}
                    ForEach(page.items){record in ConsoleRecordRow(record:record,metadata:metadata){Task{await open(record)}}.disabled(model.busy)}
                }else if model.detail==nil && !model.busy{
                    Text("Нажмите «Загрузить», чтобы получить данные сервер.").foregroundStyle(.secondary)
                }
                if let record=model.detail {
                    ConsoleDetailPanel(model:model,record:record,clientScope:selectedClient?.clientID,metadata:metadata)
                }
                if area == .referrals {
                    ConsoleReconcilePanel(model:model,clientID:nil)
                }
            }
        }
        .onAppear{status=area.statuses[0];model.clearSelection()}
    }
    private var filters:some View {
        HStack {
            if area == .requests || area == .clients{TextField("Имя или Telegram ID",text:$query).textFieldStyle(.roundedBorder).onChange(of:query){_,v in if v.count>80{query=String(v.prefix(80))}}}
            Picker("Состояние",selection:$status){ForEach(area.statuses,id:\.self){Text(ConsoleLabels.state($0)).tag($0)}}.frame(maxWidth:240)
            if area == .attention{Picker("Категория",selection:$problemKind){ForEach(["all","traffic","delivery","issuance","control","refund","referral","payment"],id:\.self){Text(ConsoleLabels.state($0)).tag($0)}}.frame(maxWidth:210)}
            Button(model.busy ? "Загрузка…":"Загрузить"){number=0;Task{await load()}}.disabled(model.busy)
        }
    }
    @ViewBuilder private func clientHeader(_ client:ConsoleRecord)->some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Text(client.title).font(.headline);Text("Telegram ID: \(client.id)").foregroundStyle(.secondary);Spacer();Button("К списку клиентов"){selectedClient=nil;pane="profile";number=0;model.clearSelection();Task{await load()}}.disabled(model.busy)}
            Picker("Карточка клиента",selection:$pane){
                Text("Профиль").tag("profile");Text("Устройства").tag("keys");Text("Архив").tag("archive");Text("Платежи и возвраты").tag("payments");Text("История").tag("history");Text("Рефералы").tag("referrals");Text("Обращения").tag("support")
            }.pickerStyle(.menu).onChange(of:pane){_,_ in number=0;Task{await load()}}
            if pane=="support"{Text("Отдельная лента обращений клиента в текущем API не предусмотрена. Проблемы выдачи и платежей доступны в разделе «Требуют внимания».").font(.callout).foregroundStyle(.secondary)}
            if pane=="referrals"{ConsoleReconcilePanel(model:model,clientID:client.clientID)}
        }
    }
    private func load()async {
        localNotice=nil
        var q=[URLQueryItem(name:"page",value:String(number)),URLQueryItem(name:"page_size",value:"20")]
        if let client=selectedClient {
            let path="/v2/clients/"+client.id
            switch pane {
            case "profile":await model.loadDetail(path:path,kind:.client)
            case "keys","archive":q.append(URLQueryItem(name:"archived",value:pane=="archive" ? "true":"false"));await model.loadPage(path:path+"/keys",kind:.key,query:q,feature:"keys_read")
            case "history":await model.loadPage(path:path+"/history",kind:.history,query:q,feature:"clients_read")
            case "payments":q.append(URLQueryItem(name:"status",value:"all"));await model.loadPage(path:path+"/payments",kind:.order,query:q,feature:"clients_read")
            case "referrals":q += [URLQueryItem(name:"client_id",value:client.id),URLQueryItem(name:"status",value:"all")];await model.loadPage(path:"/v2/referrals",kind:.referral,query:q,feature:"referrals_read")
            default:model.clearSelection()
            }
        }else{
            q.append(URLQueryItem(name:"status",value:status.isEmpty ? area.statuses[0]:status))
            if area == .requests || area == .clients{q.append(URLQueryItem(name:"query",value:query))}
            if area == .attention{q.append(URLQueryItem(name:"kind",value:problemKind))}
            await model.loadPage(path:area.path,kind:area.kind,query:q,feature:area.feature)
        }
    }
    private func open(_ record:ConsoleRecord)async {
        localNotice=nil
        switch record.kind {
        case .client:selectedClient=record;pane="profile";await model.loadDetail(path:"/v2/clients/"+record.id,kind:.client)
        case .request:await model.loadDetail(path:"/v2/requests/"+record.id,kind:.request)
        case .key:
            guard let id=selectedClient?.id else{localNotice="Сначала выберите клиента.";return}
            await model.loadDetail(path:"/v2/keys/"+record.id,kind:.key,query:[URLQueryItem(name:"client_id",value:id)])
        case .order,.history:
            guard let id=selectedClient?.id else{localNotice="Сначала выберите клиента.";return}
            await model.loadDetail(path:"/v2/clients/"+id+(record.kind == .order ? "/orders/":"/history/")+record.id,kind:record.kind)
        case .referral:
            let q=selectedClient.map{[URLQueryItem(name:"client_id",value:$0.id)]} ?? []
            await model.loadDetail(path:"/v2/referrals/"+record.id,kind:.referral,query:q)
        case .attention:await model.loadDetail(path:"/v2/attention/"+record.id,kind:.attention)
        }
    }
}

private struct ConsoleRecordRow:View {
    let record:ConsoleRecord
    var metadata:ControlMetadataModel?=nil
    let onOpen:()->Void
    var body:some View{
        GroupBox{HStack(alignment:.top){VStack(alignment:.leading,spacing:6){Group{if let metadata,record.kind == .key{MetadataKeyTitle(model:metadata,keyID:record.id,fallback:record.title)}else{Text(record.title).font(.headline)}};if let status=record.text("status") ?? record.text("state") ?? record.text("payment_status"){Text(ConsoleLabels.state(status)).foregroundStyle(.secondary)};if let n=record.clientID{Text("Telegram ID: \(n)").font(.caption).foregroundStyle(.secondary)}};Spacer();Button("Подробнее",action:onOpen)}.padding(6)}
    }
}

struct ConsoleDetailPanel:View {
    @ObservedObject var model:ControlConsoleModel
    let record:ConsoleRecord
    let clientScope:Int64?
    var metadata:ControlMetadataModel?=nil
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            GroupBox(record.title){ConsoleFieldsView(fields:record.fields).padding(8)}
            if let metadata,record.kind == .key,let target=try? MetadataTarget(id:record.id,clientID:clientScope){MetadataEditor(model:metadata,target:target).id(record.id+String(clientScope ?? 0))}
            if !record.actions.isEmpty{ConsoleActionForm(model:model,record:record,clientScope:clientScope).id(record.kind.rawValue+record.id+(record.revision ?? ""))}
        }
    }
}

private struct ConsoleActionForm:View {
    @ObservedObject var model:ControlConsoleModel
    let record:ConsoleRecord,clientScope:Int64?
    @State private var selected:ConsoleAction?
    @State private var input=""
    @State private var expiry=Date().addingTimeInterval(86400)
    @State private var validation:String?
    var body:some View {
        GroupBox("Действия"){
            VStack(alignment:.leading,spacing:12){
                ForEach(record.actions,id:\.action){item in
                    let status=model.availability(item.action,record:record)
                    HStack{Button(item.action.title){selected=item.action;input="";validation=nil}.disabled(!model.canStart || status?.enabled != true);if status?.enabled != true{Text(ConsoleLabels.gate(status?.reasonCode ?? item.reasonCode)).font(.caption).foregroundStyle(.secondary)}}
                }
                if let action=selected {
                    Divider();Text(action.title).font(.headline)
                    if action == .expiry{DatePicker("Окончание · местное время",selection:$expiry)}
                    else if let parameter=action.parameterName{TextField(ConsoleLabels.parameter(parameter),text:$input).textFieldStyle(.roundedBorder)}
                    if action == .refund{Text("Только полный возврат подтверждённого платежа. Получателя и сумму покажет сервер; вручную сумма не задаётся.").font(.caption)}
                    if action == .days{Text("Добавляет дни, не увеличивая трафик.").font(.caption)}
                    if action == .days{Button("30 дней"){input="30"}}
                    if action == .traffic{Button("500 ГБ"){input="500"}}
                    if action == .periods{Text("Каждый полный период: 30 дней и 500 ГБ. Точный итог рассчитает сервер.").font(.caption)}
                    if action == .revoke{Text("Отзыв лишит выбранный ключ доступа. Проверьте объект в серверной сводке.").font(.caption)}
                    if let validation{Text(validation).foregroundStyle(.orange)}
                    Button("Получить предпросмотр сервер"){
                        do{let target=try record.target(for:action,clientScope:clientScope);let value=action == .expiry ? ISO8601DateFormatter().string(from:expiry):input;_=try action.parameters(value);Task{await model.prepare(action:action,target:target,input:value,record:record)}}catch{validation="Проверьте параметры и выбранный объект."}
                    }.buttonStyle(.borderedProminent).disabled(!model.canStart || model.availability(action,record:record)?.enabled != true)
                    Button("Закрыть форму"){selected=nil;input=""}.disabled(model.busy)
                }
            }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

private struct ConsoleReconcilePanel:View {
    @ObservedObject var model:ControlConsoleModel
    let clientID:Int64?
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            Button(clientID==nil ? "Предпросмотр бонусов всех клиентов":"Предпросмотр бонусов этого клиента"){
                let t=ConsoleTarget(kind:.referralScope,id:clientID==nil ? "all":"client",clientID:clientID)
                Task{await model.prepare(action:.reconcile,target:t,input:"",record:nil)}
            }.disabled(!model.canStart || model.availability(.reconcile)?.enabled != true)
            if model.availability(.reconcile)?.enabled != true{Text(ConsoleLabels.gate(model.availability(.reconcile)?.reasonCode)).font(.caption).foregroundStyle(.secondary)}
        }
    }
}

struct ConsoleOperationPanel:View {
    @ObservedObject var model:ControlConsoleModel
    @State private var reviewed=false
    var body:some View {
        if let operation=model.pending {
            GroupBox("Последняя операция расширенного управления"){
                VStack(alignment:.leading,spacing:12){
                    Text(operation.request.action.title).font(.headline)
                    Text(operation.locallyAbandoned ? "Неподтверждённый черновик снят локально":operation.needsStatus ? "Нужно уточнить результат":ConsoleLabels.state(operation.receipt?.state.rawValue ?? "unknown"))
                    if let r=operation.receipt {
                        Text(r.summary)
                        if let before=r.preview?["before"]?.fields{GroupBox("До изменения"){ConsoleFieldsView(fields:before)}}
                        if let after=r.preview?["after"]?.fields{GroupBox("Последствия по данным сервер"){ConsoleFieldsView(fields:after)}}
                        if let cohort=r.preview?["cohort"]?.fields{ConsoleReferralPlanView(plan:cohort)}
                        if let effects=r.effects{GroupBox("Подтверждённые этапы"){ConsoleFieldsView(fields:effects)}}
                        if let expiry=r.expiresAt.flatMap(ControlOperationReceipt.parseDate){Text("Подтверждение до \(expiry.formatted(date:.abbreviated,time:.standard))").font(.caption).foregroundStyle(.secondary)}
                    }
                    Text("Номер: \(operation.request.operationID)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Очередь, бизнес-изменение, оплата и доставка — разные этапы. При потере ответа команда автоматически не повторяется.").font(.caption).foregroundStyle(.secondary)
                    Button("Обновить результат"){Task{await model.refreshOperation()}}.disabled(!model.ready || model.busy || operation.locallyAbandoned)
                    if model.canAbandonUnconfirmed{Button("Снять неподтверждённый черновик"){model.abandonUnconfirmed()}}
                    if operation.receipt?.state == .prepared {
                        // The wall clock must invalidate a visible confirmation even without an API response.
                        TimelineView(.periodic(from:.now,by:1)){context in confirmationControls(at:context.date)}
                    } else if operation.receipt?.state == .expired {
                        confirmationControls(at:Date())
                    }
                }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
            }
            .onChange(of:operation.request.operationID){_,_ in reviewed=false}
            .onChange(of:operation.receipt){_,_ in reviewed=false}
        }
    }
    @ViewBuilder private func confirmationControls(at now:Date)->some View {
        if model.canRenewPreview(at:now) {
            Text("Срок подтверждения истёк. Получите свежий предпросмотр и проверьте условия заново.").foregroundStyle(.secondary)
            Button("Обновить предпросмотр"){reviewed=false;Task{await model.renewPreview()}}
                .buttonStyle(.borderedProminent)
        } else if model.canConfirm(at:now) {
            if let seconds=model.confirmationSecondsRemaining(at:now) {
                Text("Подтвердите в течение \(seconds / 60):\(String(format:"%02d",seconds % 60))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Toggle("Проверил получателя, объект и последствия в сводке сервер",isOn:$reviewed)
            HStack {
                Button("Подтвердить действие"){Task{await model.confirm()}}.buttonStyle(.borderedProminent).disabled(!reviewed)
                Button("Отменить подготовленное"){Task{await model.cancel()}}
            }
        }
    }
}

struct ConsoleReferralPlanView:View {
    let plan:[String:ConsoleValue]
    var body:some View {
        GroupBox("Точный список реферальных изменений") {
            VStack(alignment:.leading,spacing:10) {
                Text("Выполнится только этот список: \(plan["candidate_count"]?.number ?? 0). Вне списка: \(plan["excluded_count"]?.number ?? 0).")
                Text("Новые подходящие бонусы не добавятся при подтверждении.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:10) {
                        ForEach(Array((plan["items"]?.values ?? []).enumerated()),id:\.offset) { index,value in
                            if let item=value.fields {
                                VStack(alignment:.leading,spacing:5) {
                                    Text("\(index+1). Клиент Telegram \(String(item["inviter_telegram_user_id"]?.number ?? 0))").font(.headline)
                                    Text(effect(item["effect"]?.text ?? ""))
                                    Text(term(item["term_seconds"]?.number ?? 0))
                                    Text(item["traffic_mode"]?.text=="unlimited" ? "Трафик в показанном периоде: безлимитный":"Новые права на трафик не добавляются")
                                    if let key=item["device_key_id"]?.text{Text("Ключ: \(key)").font(.caption.monospaced()).textSelection(.enabled)}
                                    if let date=item["starts_at"]?.text.flatMap(ControlOperationReceipt.parseDate){Text("Начало: \(date.formatted(date:.abbreviated,time:.standard))")}
                                    if let date=item["ends_at"]?.text.flatMap(ControlOperationReceipt.parseDate){Text("Окончание: \(date.formatted(date:.abbreviated,time:.standard))")}
                                    Text(item["creates_reward"]?.flag==true ? "Будет создан новый бонус":"Используется существующий бонус")
                                    DisclosureGroup("Идентификаторы проверки") {
                                        ConsoleFieldsView(fields:item.filter{!["effect","creates_reward","inviter_telegram_user_id","starts_at","ends_at"].contains($0.key)})
                                    }.font(.caption)
                                }.padding(8).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                            }
                        }
                    }
                }.frame(maxHeight:360)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func effect(_ value:String)->String {
        switch value {
        case "approve_only":return "Одобрить приглашение без начисления периода"
        case "approve_and_apply":return "Одобрить приглашение и начислить показанный период"
        case "qualify_and_apply":return "Подтвердить условия и начислить показанный период"
        case "apply":return "Начислить показанный период"
        default:return "Неизвестное действие — подтверждение недоступно"
        }
    }
    private func term(_ seconds:Int64)->String {
        if seconds==0{return "Дополнительный срок не начисляется"}
        if seconds%86400==0{return "Добавляется времени: \(seconds/86400) сут."}
        if seconds%3600==0{return "Добавляется времени: \(seconds/3600) ч."}
        return "Добавляется времени: \(seconds) сек."
    }
}

private struct ConsoleFieldsView:View {
    let fields:[String:ConsoleValue]
    private var keys:[String]{fields.keys.filter{!["revision","allowed_actions"].contains($0)}.sorted()}
    var body:some View {
        VStack(alignment:.leading,spacing:7){
            ForEach(keys,id:\.self){key in
                if let value=fields[key],value != .null {
                    HStack(alignment:.top){Text(ConsoleLabels.field(key)).foregroundStyle(.secondary).frame(width:190,alignment:.leading);Text(ConsoleLabels.value(value,key:key)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.font(.callout)
                }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

enum ConsoleLabels {
    static func parameter(_ s:String)->String{switch s{case "days":return "Дни · 1–3650";case "periods":return "Полные периоды · 1–120";case "traffic_gb":return "ГБ · 1–100000";default:return "Причина решения"}}
    static func gate(_ s:String?)->String {
        switch s{case "CORE_KEY_ATOMIC_FENCE":return "Безопасное изменение ключей ещё не включено на сервере.";case "CORE_REFERRAL_EXACT_COHORT":return "Обработка точного набора бонусов ещё не включена.";case "CLIENT_ISSUANCE_E2E_GATE":return "Клиентская выдача ещё проходит проверку.";default:return "Сервер пока не разрешает это действие для выбранного объекта."}
    }
    static func state(_ s:String)->String {
        let values=["all":"Все","active":"Активные","active_unlimited":"Активен","expired":"Истёкшие","payment":"Оплата","pending":"Ожидает решения","blocked":"Заблокированные","processing":"Выполняется","completed":"Завершено","attention":"Требует внимания","accepted":"Принято","resolved":"Решено","traffic":"Учёт трафика","delivery":"Доставка","issuance":"Выдача","control":"Управление","refund":"Возврат","referral":"Рефералы","succeeded":"Результат подтверждён","failed":"Ошибка","unknown":"Результат неизвестен","prepared":"Подготовлено · нужно подтверждение","queued":"В очереди сервера","running":"Выполняется","canceled":"Отменено","awaiting_gift":"Ожидает подарка","awaiting_delivery":"Ожидает доставки","qualified":"Условия выполнены","earned":"Бонус заработан","review":"На проверке","rejected":"Отклонено","scheduled":"Запланировано","refund_pending":"Возврат ожидается","refunded":"Возвращено","refund_failed":"Ошибка возврата","refund_unknown":"Возврат не подтверждён","none":"Не требуется","confirmed":"Подтверждено","unpaid":"Не оплачен","telegram_accepted":"Принято Telegram","delivered":"Доставлено"]
        return values[s] ?? s
    }
    static func value(_ v:ConsoleValue,key:String)->String {
        if let s=v.text {
            if ["state","status","payment_status","delivery_state","payment_state","access_state"].contains(key){return state(s)}
            if key=="delivery_to"{return ["none":"Не требуется","owner_private_telegram":"Ваш личный Telegram","existing_client_telegram":"Личный Telegram выбранного клиента"][s] ?? "Не подтверждён"}
            if key=="currency",s=="XTR"{return "Stars"}
            if key.hasSuffix("_at"),let d=ControlOperationReceipt.parseDate(s){return d.formatted(date:.abbreviated,time:.standard)}
        }
        if let n=v.number,key.hasSuffix("_bytes"){return ByteCountFormatter.string(fromByteCount:n,countStyle:.file)}
        if let f=v.fields{return f.keys.sorted().map{"\(field($0)): \(value(f[$0]!,key:$0))"}.joined(separator:"\n")}
        if let a=v.values{return a.map{value($0,key:key)}.joined(separator:"\n")}
        return v.display
    }
    static func field(_ s:String)->String {
        let extra=["attribution_state":"Состояние приглашения","base_quota_bytes":"Базовый трафик","count":"Количество","manual_suspended_at":"Приостановлено","policy_revision":"Версия политики","provision_state":"Состояние выдачи","quantity":"Количество","quota_bytes":"Трафик","reward_state":"Состояние бонуса","term_end":"Окончание срока","time_mode":"Режим срока","traffic_mode":"Режим трафика","used_bytes":"Использовано трафика","limit_bytes":"Лимит трафика","remaining_bytes":"Осталось трафика"]
        if let title=extra[s]{return title}
        let names=["request_id":"Заявка","telegram_user_id":"Telegram ID","username":"Имя Telegram","display_name":"Клиент","device_count":"Устройств","period_count":"Периодов","total_xtr":"Сумма Stars","status":"Состояние","request_kind":"Тип заявки","stage":"Этап","identity_conflict":"Конфликт получателя","replace_invoice_available":"Доступен подарок вместо счёта","gift_order_id":"Заказ подарка","key_id":"Ключ","name":"Название","protocol":"Протокол","state":"Состояние","expires_at":"Окончание срока","period_ends_at":"Окончание периода","used_bytes":"Использовано, байт","limit_bytes":"Лимит, байт","last_activity_at":"Последняя активность","time_unlimited":"Бессрочный срок","traffic_unlimited":"Безлимит трафика","traffic_available":"Учёт доступен","traffic_updated_at":"Обновление учёта","traffic_oldest_at":"Самый старый замер","traffic_loss_unknown":"Возможна потеря учёта","traffic_partial_stale":"Часть данных устарела","traffic_scope":"Область учёта","remaining_bytes":"Осталось, байт","access_kind":"Тип доступа","slots_used":"Занято мест","slots_limit":"Лимит мест","active_keys":"Активных ключей","suspended_keys":"Приостановлено","expired_keys":"Истёкших ключей","pending_keys":"Ожидающих ключей","order_id":"Заказ","amount_xtr":"Сумма Stars","currency":"Валюта","order_type":"Тип заказа","devices_count":"Устройств","periods_count":"Периодов","paid_at":"Дата оплаты","payment_status":"Состояние оплаты","refundable":"Полный возврат допустим","event_id":"Событие","created_at":"Время события","actor":"Кто выполнил","action":"Действие","target":"Объект","result":"Результат","reason":"Причина","before":"До","after":"После","problem_id":"Проблема","kind":"Категория","object_id":"Связанный объект","first_event_at":"Первое событие","last_event_at":"Последнее событие","attempts":"Попыток","chain":"Цепочка","next_step":"Следующий шаг","responsible":"Ответственный","reward_id":"Бонус","attribution_id":"Приглашение","reviewable":"Решение доступно","earned_at":"Бонус заработан","starts_at":"Начало","ends_at":"Окончание","device_slot_id":"Устройство","bound_at":"Приглашение принято","inviter_telegram_user_id":"Telegram ID пригласившего","inviter_username":"Пригласивший","inviter_display_name":"Пригласивший","invitee_telegram_user_id":"Telegram ID приглашённого","invitee_username":"Приглашённый","invitee_display_name":"Приглашённый","gift_created":"Подарок создан","gift_fulfilled":"Подарок выдан","delivery_confirmed":"Доставка подтверждена","summary":"Сводка сервер","parameters":"Параметры","days":"Дни","periods":"Полные периоды","traffic_gb":"Трафик, ГБ","delivery_to":"Получатель доставки","adds_quota":"Добавляет трафик","changes_term":"Меняет срок","business_confirmed":"Изменение подтверждено","delivery_state":"Доставка","payment_state":"Оплата / возврат","access_state":"Состояние доступа","processed":"Обработано бонусов","candidate_count":"Бонусов в сводке","candidate_ids":"Бонусы для обработки"]
        return names[s] ?? s
    }
}
