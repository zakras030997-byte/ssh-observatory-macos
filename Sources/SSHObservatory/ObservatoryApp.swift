import AppKit
import SwiftUI
import Charts
import TelemetryCore

@main struct ObservatoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = TelemetryModel()
    var body: some Scene {
        Window("SSH Observatory", id: "observatory") {
            TabView {
                Dashboard(model: model)
                    .tabItem { Label("Телеметрия", systemImage: "waveform.path.ecg") }
                ControlPrototypeView()
                    .tabItem { Label("Управление", systemImage: "slider.horizontal.3") }
            }
                .background(WindowObserver(onClose: { model.stopAll() }))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stopAll() }
        }
        .defaultSize(width: 1040, height: 820)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct WindowObserver: NSViewRepresentable {
    let onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onClose) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in onClose() }
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Coordinator {
        var token: NSObjectProtocol?
        let onClose: () -> Void
        init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

private enum Palette {
    static let cpu = Color(red: 0.22, green: 0.72, blue: 0.64)
    static let memory = Color(red: 0.42, green: 0.63, blue: 0.88)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
}

struct Dashboard: View {
    @ObservedObject var model: TelemetryModel
    @State private var showingAdd = false
    @State private var selected: NodeModel?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(spacing: 12) {
                    Button { model.connectAll(includePaused: true) } label: {
                        Label("Подключить все", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.nodes.isEmpty || model.loading)
                    Button { model.stopAll(rememberPause: true) } label: {
                        Label("Остановить все", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.nodes.isEmpty || model.loading)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Image(systemName: model.demo ? "square.stack.3d.up" : "lock.shield")
                    Text(model.demo ? "Демонстрация · все значения условные · подключений к серверам нет" : "Сбор только при открытом приложении · VPN-трафик отдельно не проверен")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if model.loading {
                    ProgressView("Загрузка серверов и истории…").frame(minHeight: 360)
                } else if model.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("Добавьте первую ноду", systemImage: "server.rack")
                    } description: {
                        Text("Укажите существующий SSH-профиль. Подключение начнётся только по вашей кнопке.")
                    } actions: {
                        Button("Добавить сервер") { showingAdd = true }.buttonStyle(.borderedProminent)
                    }.frame(minHeight: 360)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18)], spacing: 18) {
                        ForEach(model.nodes) { node in
                            NodeCard(node: node, demo: model.demo) { selected = node }
                        }
                    }
                }
                HStack {
                    Label("Основные показатели · 3 с", systemImage: "waveform.path")
                    Spacer()
                    Text("История остаётся на этом Mac")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .frame(minWidth: 870, minHeight: 620)
        .sheet(isPresented: $showingAdd) { AddNodeSheet(model: model) }
        .sheet(item: $selected) { node in NodeDetail(node: node, demo: model.demo) }
        .toolbar {
            ToolbarItem {
                Button { showingAdd = true } label: { Label("Добавить сервер", systemImage: "plus") }
            }
        }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SSH  /  OBSERVATORY").font(.caption).tracking(2).foregroundStyle(.secondary)
                Text("Пульс сети").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Ресурсы и службы. Всё важное — в одном окне.").foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(model.nodes.count)").font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                Text(model.demo ? "ноды · демо" : "нод в списке").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NodeCard: View {
    @ObservedObject var node: NodeModel
    let demo: Bool
    var openDetail: () -> Void
    private var sample: TelemetrySample? { node.latest?.sample }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.profile.name).font(.title3.weight(.semibold))
                    Text(node.profile.region.isEmpty ? node.profile.sshAlias : node.profile.region)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 3)) { _ in
                    Label(demo ? "Пример" : node.state.title, systemImage: node.fresh ? "circle.fill" : "circle.dotted")
                        .font(.caption)
                        .foregroundStyle(demo ? Color.secondary : (node.fresh ? Palette.cpu : Color.orange))
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.caption).foregroundStyle(.secondary)
                Text(percent(sample?.cpuPercent)).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                Spacer()
                Text("\(sample?.cores ?? 0) vCPU · 5 минут").font(.caption).foregroundStyle(.secondary)
            }
            MiniChart(points: node.window.points, metric: .cpu, color: Palette.cpu)
                .frame(height: 48)
                .opacity(node.fresh || demo ? 1 : 0.35)
            HStack(alignment: .top, spacing: 22) {
                ResourceGauge(title: "Память", usage: sample?.memory, color: Palette.memory)
                ResourceGauge(title: "Диск", usage: sample?.disk, color: Palette.cpu)
            }.opacity(node.fresh || demo ? 1 : 0.45)
            HStack(spacing: 20) {
                Label(rate(sample?.network?.receivedBytesPerSecond), systemImage: "arrow.down")
                Label(rate(sample?.network?.sentBytesPerSecond), systemImage: "arrow.up")
                Spacer(minLength: 0)
                Text(serviceLabel).lineLimit(1)
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Divider()
            HStack {
                TimelineView(.periodic(from: .now, by: 3)) { context in
                    Text(demo ? "Условные данные" : age(context.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Подробнее", action: openDetail).buttonStyle(.plain).font(.caption.weight(.medium))
                    .foregroundStyle(Palette.memory)
            }
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Сервер \(node.profile.name)")
    }
    private var serviceLabel: String {
        guard node.fresh || demo else { return "VPN: неизвестно" }
        guard let units = sample?.units, !units.isEmpty else { return "Службы не выбраны" }
        if units.contains(where: { $0.state == "unknown" }) { return "Службы: частично" }
        return units.allSatisfy { $0.state == "active" } ? "Службы запущены" : "Есть остановленные"
    }
    private func age(_ date: Date) -> String {
        guard let latest = node.latest else { return "Показаний ещё нет" }
        let seconds = max(0, Int(date.timeIntervalSince(latest.receivedAt)))
        return seconds < 60 ? "Получено \(seconds) с назад" : "Получено \(seconds / 60) мин назад"
    }
}

enum PlotMetric { case cpu, memory }
struct MiniChart: View {
    let points: [ReceivedSample]
    let metric: PlotMetric
    let color: Color
    var body: some View {
        Chart(points) { point in
            if let value = metric == .cpu ? point.sample.cpuPercent : point.sample.memory?.percent {
                AreaMark(x: .value("Время", point.receivedAt), yStart: .value("Ноль", 0), yEnd: .value("Проценты", value), series: .value("Сеанс", point.segment.uuidString))
                    .foregroundStyle(color.opacity(0.09))
                LineMark(x: .value("Время", point.receivedAt), y: .value("Проценты", value), series: .value("Сеанс", point.segment.uuidString))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.6))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: timeDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.primary.opacity(0.08)) }
        }
        .chartPlotStyle { $0.clipped() }
        .accessibilityLabel(metric == .cpu ? "График CPU" : "График памяти")
        .accessibilityValue("Последние пять минут наблюдения, шкала от нуля до ста процентов")
    }
    private var timeDomain: ClosedRange<Date> {
        let end = points.last?.receivedAt ?? Date()
        return end.addingTimeInterval(-300)...end
    }
}

struct ResourceGauge: View {
    let title: String
    let usage: ByteUsage?
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(percent(usage?.percent)).monospacedDigit()
            }.font(.callout)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.06))
                    Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, (usage?.percent ?? 0) / 100)))
                }
            }.frame(height: 5)
            Text(usage.map { "\(gib($0.used)) / \(gib($0.total)) ГиБ" } ?? "Нет показаний")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

struct NodeDetail: View {
    @ObservedObject var node: NodeModel
    let demo: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(node.profile.name).font(.title2.weight(.semibold))
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(demo ? "Демонстрационные показания" : node.state.title).foregroundStyle(.secondary)
            if case .failed(let reason) = node.state { Text(reason).foregroundStyle(.orange) }
            GroupBox("CPU · %") { MiniChart(points: node.window.points, metric: .cpu, color: Palette.cpu).frame(height: 130).padding(8) }
            GroupBox("Память · %") { MiniChart(points: node.window.points, metric: .memory, color: Palette.memory).frame(height: 100).padding(8) }
            if let sample = node.latest?.sample {
                HStack {
                    Text("Swap: \(sample.swap.map { "\(gib($0.used)) / \(gib($0.total)) ГиБ" } ?? "неизвестно")")
                    Spacer()
                    Text("Load: \(sample.load?.map { String(format: "%.2f", $0) }.joined(separator: " / ") ?? "—")")
                }.font(.callout).foregroundStyle(.secondary)
                ForEach(sample.units) { unit in
                    HStack {
                        Text(unit.name).textSelection(.enabled)
                        Spacer()
                        Text(node.fresh || demo ? unit.state : "неизвестно")
                        Text("Рестарты: \(unit.restarts.map(String.init) ?? "—")")
                    }.font(.callout)
                }
                if !sample.errors.isEmpty {
                    Text("Недоступные источники: " + sample.errors.keys.sorted().joined(separator: ", ")).font(.callout).foregroundStyle(.orange)
                }
                Text("Время на сервере: \(sample.date.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Сетевой интерфейс: \(sample.network?.interface ?? "не определён / старая запись")").font(.caption).foregroundStyle(.secondary)
                if let disk = sample.disk {
                    Text("Диск: доступно \(gib(disk.available)) ГиБ; резерв \(disk.reservedBytes.map(gib) ?? "—") ГиБ").font(.caption).foregroundStyle(.secondary)
                }
            }
            Label("Реальный VPN-трафик не проверен", systemImage: "info.circle").foregroundStyle(.secondary)
            if node.historyFailed { Text("Не удалось сохранить часть локальной истории.").foregroundStyle(.orange) }
            if node.skippedSamples > 0 { Text("Объединено обновлений при занятом интерфейсе: \(node.skippedSamples)").font(.caption).foregroundStyle(.secondary) }
            if !demo {
                HStack {
                    Button("Подключить / повторить") { node.connect() }.buttonStyle(.borderedProminent)
                    Button("Переподключить") { node.connect(force: true) }
                    Button("Остановить") { node.pause() }
                }
            }
        }.padding(28).frame(width: 640)
    }
}

struct AddNodeSheet: View {
    @ObservedObject var model: TelemetryModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var region = ""
    @State private var alias = ""
    @State private var units = ""
    @State private var configPath = ""
    @State private var hostname = ""
    @State private var networkInterface = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Добавить сервер").font(.title2.weight(.semibold))
            Form {
                TextField("Название", text: $name)
                TextField("Регион / подпись", text: $region)
                TextField("SSH-профиль", text: $alias)
                TextField("Сетевой интерфейс (пусто — основной маршрут)", text: $networkInterface)
                TextField("Файл SSH-профиля (необязательно)", text: $configPath)
                TextField("Ожидаемое имя хоста (необязательно)", text: $hostname)
                TextField("Службы через запятую", text: $units)
            }.textFieldStyle(.roundedBorder)
            Text("Используется уже настроенный SSH-профиль с проверенным ключом сервера. Приватные ключи не копируются. Python 3 должен быть доступен на ноде; установка автоматически не выполняется.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Пример имён служб: xray.service, hysteria.service. Оставьте поле пустым, если пока нужны только ресурсы.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить") {
                    do {
                        let list = units.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        let config = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                        let interface = networkInterface.trimmingCharacters(in: .whitespacesAndNewlines)
                        try model.add(NodeProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), region: region, sshAlias: alias.trimmingCharacters(in: .whitespacesAndNewlines), units: list, sshConfigPath: config.isEmpty ? nil : config, expectedHostname: host.isEmpty ? nil : host, networkInterface: interface.isEmpty ? nil : interface))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 510)
    }
}

private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
private func gib(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1_073_741_824) }
private func rate(_ bytes: Double?) -> String {
    guard let bytes else { return "—" }
    if bytes >= 1_000_000 { return String(format: "%.1f МБ/с", bytes / 1_000_000) }
    return String(format: "%.0f КБ/с", bytes / 1000)
}
