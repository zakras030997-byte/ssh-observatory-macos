import SwiftUI

struct MetadataKeyTitle: View {
    @ObservedObject var model:ControlMetadataModel
    let keyID:String, fallback:String
    var body:some View { Text(verbatim:model.snapshots[keyID]?.effectiveName ?? fallback).font(.headline) }
}

struct ControlOverviewPanel: View {
    @ObservedObject var model:ControlMetadataModel
    var body:some View {
        GroupBox("Клиенты · общий снимок сервер") {
            VStack(alignment:.leading,spacing:10) {
                if let v=model.overview {
                    HStack(spacing:28) {
                        counter("Зарегистрированы",v.registeredClients)
                        counter("С активным доступом",v.activeClients)
                        counter("Активные ключи",v.activeKeys)
                        counter("Занятые слоты",v.slotsUsed)
                        Spacer()
                    }
                    Text("Снимок: \(v.snapshotAt)").font(.caption).foregroundStyle(.secondary)
                } else { Text("Данные ещё не получены.").foregroundStyle(.secondary) }
                HStack {
                    Text("Владельческие ключи не входят в эти числа. Активный доступ не означает подключение онлайн.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Обновить сводку"){Task{await model.refreshOverview()}}.disabled(!model.overviewEnabled || model.busy)
                }
                if let notice=model.overviewNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.padding(8)
        }
    }
    private func counter(_ label:String,_ n:Int64)->some View { VStack(alignment:.leading,spacing:4){ Text(n.formatted()).font(.title2.monospacedDigit()); Text(label).font(.caption).foregroundStyle(.secondary) } }
}

struct MetadataEditor: View {
    @ObservedObject var model:ControlMetadataModel
    let target:MetadataTarget
    @State private var name=""
    @State private var note=""
    @State private var loadedRevision:String?
    @State private var validation:String?
    private var snapshot:KeyMetadataSnapshot? { model.snapshots[target.id].flatMap{$0.matches(target) ? $0:nil} }
    var body:some View {
        GroupBox("Имя и заметка") {
            VStack(alignment:.leading,spacing:10) {
                if !model.ready { Text("Пакет имён и заметок ещё не подключён.").foregroundStyle(.secondary) }
                else {
                    HStack {
                        if let s=snapshot { Text("Исходное имя: \(s.originalName)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Перечитать с сервером"){Task{await model.load(target);reset()}}.disabled(model.busy)
                    }
                    if let s=snapshot {
                        TextField("Имя устройства",text:$name).textFieldStyle(.roundedBorder).disabled(!model.canStart)
                        Text("Имя: до 80 символов Unicode; составные эмодзи занимают несколько позиций.").font(.caption).foregroundStyle(.secondary)
                        Text("Заметка · необязательно").font(.caption)
                        TextEditor(text:$note).font(.body).frame(height:100).border(.quaternary).disabled(!model.canStart)
                        Text("До 1000 символов Unicode. Пустая заметка удалит её содержимое.").font(.caption).foregroundStyle(.secondary)
                        if let validation { Text(validation).foregroundStyle(.orange) }
                        Button("Проверить изменение на сервере") {
                            do { let draft=try ControlMetadataDraft(name:name,note:note).normalized();validation=nil;Task{await model.prepare(target:target,snapshot:s,draft:draft)} }
                            catch { validation=(error as? LocalizedError)?.errorDescription ?? "Проверьте текст." }
                        }.buttonStyle(.borderedProminent).disabled(!model.canStart || loadedRevision != s.viewRevision)
                        Text("Меняет только подпись и заметку. Срок, трафик и права доступа сохраняются.").font(.caption).foregroundStyle(.secondary)
                    } else { Text(model.busy ? "Загрузка…":"Метаданные выбранного ключа не подтверждены.").foregroundStyle(.secondary) }
                }
                if let notice=model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.padding(8)
        }
        .task(id:target.id+String(target.clientID ?? 0)) { await model.load(target);reset() }
        .onChange(of:snapshot?.viewRevision){_,_ in reset()}
    }
    private func reset() { if let s=snapshot { name=s.effectiveName;note=s.note;loadedRevision=s.viewRevision;validation=nil } }
}

struct MetadataOperationPanel: View {
    @ObservedObject var model:ControlMetadataModel
    var body:some View {
        if let p=model.pending {
            GroupBox("Изменение имени и заметки") {
                VStack(alignment:.leading,spacing:10) {
                    Text("Ключ: \(p.target.id)").font(.caption).textSelection(.enabled)
                    Text(model.needsStatus ? "Результат нужно сверить с сервером":state(p.state)).font(.headline)
                    if let preview=model.receipt?.preview {
                        HStack(alignment:.top,spacing:20) {
                            text("Было",name:preview.before.effectiveName,note:preview.before.note)
                            text("Будет",name:preview.after.name,note:preview.after.note)
                        }
                    }
                    if let result=model.receipt?.result { Text("Сохранена версия \(result.revision). Это результат данной операции.").font(.caption) }
                    HStack {
                        Button("Проверить результат"){Task{await model.refreshOperation()}}.disabled(!model.ready || model.busy)
                        if model.receipt?.state == .prepared {
                            Button("Обновить предпросмотр"){Task{await model.refreshPreview()}}.disabled(!model.canRefreshPreview)
                            Button("Подтвердить изменение"){Task{await model.confirm()}}.buttonStyle(.borderedProminent).disabled(!model.canConfirm)
                            Button("Отменить"){Task{await model.cancel()}}.disabled(!model.canConfirm)
                        }
                        if model.canAbandon { Button("Снять неподтверждённый черновик"){model.abandonUnconfirmed()} }
                    }
                    if model.unresolved { Text("До подтверждённого результата остальные изменения заблокированы. Повторная команда автоматически не отправляется.").font(.caption).foregroundStyle(.secondary) }
                    if let notice=model.notice { Text(notice).foregroundStyle(.orange) }
                }.padding(8)
            }
        } else if model.journalBlocked { Text(model.notice ?? "Журнал имён и заметок недоступен. Изменения заблокированы.").foregroundStyle(.orange) }
    }
    private func text(_ title:String,name:String,note:String)->some View { VStack(alignment:.leading,spacing:5){Text(title).font(.caption).foregroundStyle(.secondary);Text(verbatim:name).font(.headline);ScrollView{Text(verbatim:note.isEmpty ? "Без заметки":note).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:140)}.frame(maxWidth:.infinity,alignment:.leading) }
    private func state(_ s:ControlOperationState)->String { switch s {case .prepared:return "Предпросмотр готов";case .queued:return "В очереди";case .running:return "Выполняется";case .succeeded:return "Сохранено";case .failed:return "Изменение не выполнено";case .unknown:return "Результат пока неизвестен";case .expired:return "Предпросмотр истёк";case .canceled:return "Отменено"} }
}
