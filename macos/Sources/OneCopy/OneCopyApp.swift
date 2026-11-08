#if os(macOS)
import SwiftUI
import AppKit
import Foundation
import OneCopyCore

struct TrashRecord: Codable, Identifiable {
    let id: UUID
    let originalPath: String
    let trashedPath: String
    let date: Date
    /// If a different file later occupies the same Trash path, do not restore it.
    let trashedIdentity: String?
}

@MainActor
final class OneCopyModel: ObservableObject {
    @Published var selectedFolders: [URL] = []
    @Published var groups: [DuplicateGroup] = []
    @Published var selectedGroups: Set<String> = []
    @Published var keeperPaths: [String: String] = [:]
    @Published var isScanning = false
    @Published var isMoving = false
    @Published var status = "Выберите папку для проверки"
    @Published var details = ""
    @Published var scannedCount = 0
    @Published var skippedCount = 0
    @Published var history: [TrashRecord] = []
    @Published var showConfirmation = false
    private var scanTask: Task<Void, Never>?

    init() { loadHistory() }

    var selectedCopyCount: Int {
        groups.filter { $0.canClean && selectedGroups.contains($0.id) }.reduce(0) { $0 + $1.files.count - 1 }
    }
    var selectedBytes: Int64 {
        groups.filter { $0.canClean && selectedGroups.contains($0.id) }.reduce(0) { $0 + $1.reclaimableBytes }
    }
    // Logical sizes, NOT a prediction of physical blocks reclaimed on APFS.
    var possibleBytes: Int64 { groups.filter(\.canClean).reduce(0) { $0 + $1.reclaimableBytes } }
    var busy: Bool { isScanning || isMoving }

    func chooseFolders() {
        let picker = NSOpenPanel()
        picker.title = "Выберите папки для поиска точных копий"
        picker.prompt = "Добавить"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = true
        picker.resolvesAliases = true
        guard picker.runModal() == .OK else { return }
        for url in picker.urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !FolderProtection.prohibited(canonical) else {
                details = "Защищённая системная папка не добавлена: \(canonical.path)"
                continue
            }
            if !selectedFolders.contains(where: { $0.path == canonical.path }) {
                selectedFolders.append(canonical)
                invalidateScan()
            }
        }
    }

    func startScan() {
        guard !busy, !selectedFolders.isEmpty else { return }
        isScanning = true
        groups = []
        keeperPaths = [:]
        selectedGroups = []
        details = ""
        status = "Начинаем анализ…"
        let folders = selectedFolders
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try DuplicateScanner().scan(
                    folders: folders,
                    progress: { message in Task { @MainActor [weak self] in self?.publishProgress(message) } },
                    cancelled: { Task<Never, Never>.isCancelled }
                )
                await self?.completeScan(result)
            } catch {
                await self?.completeScanError(error.localizedDescription)
            }
        }
    }

    private func publishProgress(_ message: String) {
        if isScanning { status = message }
    }

    private func completeScan(_ result: ScanReport) {
        groups = result.groups
        keeperPaths = Dictionary(uniqueKeysWithValues: result.groups.compactMap { group in
            group.files.first.map { (group.id, $0.id) }
        })
        scannedCount = result.examinedFiles
        skippedCount = result.skippedFiles
        details = result.issues.prefix(50).joined(separator: "\n")
        isScanning = false
        status = result.groups.isEmpty ? "Точных копий в выбранных папках не найдено" :
            "Готово: \(result.groups.filter(\.canClean).count) групп допущено к ручной очистке; остальные защищены."
    }

    private func completeScanError(_ description: String) {
        isScanning = false
        status = description
    }

    func stopScan() { scanTask?.cancel(); status = "Останавливаем проверку…" }

    func invalidateScan() {
        groups = []
        selectedGroups = []
        keeperPaths = [:]
        status = "Список папок изменён — запустите поиск заново"
    }

    func setAllGroups(_ enabled: Bool) {
        selectedGroups = enabled ? Set(groups.filter(\.canClean).map(\.id)) : []
    }

    func moveSelectedToTrash() {
        guard !busy, selectedCopyCount > 0 else { return }
        let plans: [(FileRecord, [FileRecord])] = groups.compactMap { group in
            guard group.canClean, selectedGroups.contains(group.id),
                  let keepPath = keeperPaths[group.id],
                  let keeper = group.files.first(where: { $0.id == keepPath }) else { return nil }
            return (keeper, group.files.filter { $0.id != keepPath })
        }
        isMoving = true
        status = "Перепроверяем файлы перед перемещением…"
        Task { [weak self] in
            var ok = 0
            var errors: [String] = []
            for (keeper, copies) in plans {
                for copy in copies {
                    guard let self = self else { return }
                    self.status = "Проверяем: \(copy.name)"
                    do {
                        // Important: perform FINAL read verification and the trash move
                        // consecutively on a background worker. There is still a small
                        // TOCTOU interval, so this is not an atomic proof.
                        let trashURL = try await Task.detached(priority: .userInitiated) { () -> URL? in
                            guard try DuplicateScanner.safeToTrash(keeper: keeper, candidate: copy) else { return nil }
                            var destination: NSURL?
                            try FileManager.default.trashItem(at: copy.url, resultingItemURL: &destination)
                            return destination as URL?
                        }.value
                        guard let trashURL else {
                            errors.append("Пропущен \(copy.name): изменился файл или отсутствует подтверждение безопасного удаления")
                            continue
                        }
                        let movedIdentity = try? FileRecord.snapshot(trashURL)?.physicalIdentity
                        self.history.insert(TrashRecord(id: UUID(), originalPath: copy.url.path,
                                                        trashedPath: trashURL.path, date: Date(),
                                                        trashedIdentity: movedIdentity ?? nil), at: 0)
                        self.saveHistory()
                        ok += 1
                    } catch {
                        errors.append("\(copy.name): \(error.localizedDescription)")
                    }
                }
            }
            guard let self = self else { return }
            self.isMoving = false
            self.status = "В Корзину перемещено: \(ok). " + (errors.isEmpty ? "Ошибок нет." : "Есть пропущенные файлы.")
            self.details = errors.joined(separator: "\n")
            // Clear stale scan results; user must rescan before another destructive action.
            self.groups = []
            self.selectedGroups = []
            self.keeperPaths = [:]
        }
    }

    func restore(_ record: TrashRecord) {
        let from = URL(fileURLWithPath: record.trashedPath)
        let to = URL(fileURLWithPath: record.originalPath)
        guard !FolderProtection.prohibited(to) else {
            status = "Нельзя восстановить файл в защищённую область"
            return
        }
        let fm = FileManager.default
        guard let expectedIdentity = record.trashedIdentity,
              let current = try? FileRecord.snapshot(from),
              current.physicalIdentity == expectedIdentity else {
            status = "Восстановление заблокировано: экземпляр в Корзине не подтверждён. Проверьте его через Finder."
            return
        }
        guard !fm.fileExists(atPath: to.path) else {
            status = "Восстановление отменено: по исходному пути уже есть файл"
            return
        }
        let parent = to.deletingLastPathComponent()
        guard fm.fileExists(atPath: parent.path),
              parent.standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL,
              !FolderProtection.prohibited(parent) else {
            status = "Папка восстановления отсутствует или путь изменился; восстановите через Finder"
            return
        }
        do {
            try fm.moveItem(at: from, to: to)
            history.removeAll { $0.id == record.id }
            saveHistory()
            status = "Восстановлен: \(to.lastPathComponent)"
        } catch { status = "Не удалось восстановить: \(error.localizedDescription)" }
    }

    private var historyURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("OneCopy", isDirectory: true).appendingPathComponent("trash-history.json")
    }
    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([TrashRecord].self, from: data) else { return }
        history = decoded
    }
    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history)
            try data.write(to: historyURL, options: .atomic)
        } catch { details = "Не удалось сохранить историю: \(error.localizedDescription)" }
    }
}

struct ContentView: View {
    @StateObject private var model = OneCopyModel()
    @State private var showHistory = false
    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ONECOPY").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("Только полностью идентичные файлы")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showHistory.toggle() } label: {
                    Label("История и восстановление", systemImage: "clock.arrow.circlepath")
                }
                .disabled(model.busy)
            }

            HStack(spacing: 10) {
                Button { model.chooseFolders() } label: {
                    Label("Добавить папки", systemImage: "folder.badge.plus")
                }.disabled(model.busy)
                if model.isScanning {
                    Button("Остановить") { model.stopScan() }
                } else {
                    Button { model.startScan() } label: {
                        Label("Найти одинаковые", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.selectedFolders.isEmpty)
                }
                Spacer()
                if model.isScanning || model.isMoving { ProgressView().controlSize(.small) }
            }

            if !model.selectedFolders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Проверяемые папки").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.selectedFolders, id: \.path) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(folder.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 6)
                            Button {
                                model.selectedFolders.removeAll { $0 == folder }
                                model.invalidateScan()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busy)
                            .accessibilityLabel("Убрать папку из проверки")
                        }
                    }
                }
                .padding(12).background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 12) {
                metric("Групп совпадений", "\(model.groups.count)", "square.stack.3d.up")
                metric("Логический размер безопасных копий", formatted(model.possibleBytes), "internaldrive")
                metric("Проверено файлов", "\(model.scannedCount)", "doc.on.doc")
            }
            HStack(spacing: 8) {
                Image(systemName: model.isMoving ? "shippingbox" : "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text(model.status).font(.subheadline)
                    .lineLimit(2)
                Spacer()
            }

            if showHistory {
                historyList
            } else if model.groups.isEmpty {
                Spacer(minLength: 10)
                VStack(spacing: 9) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 45, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text(model.isScanning ? "Ищем настоящие копии" : "Ваши файлы пока не тронуты")
                        .font(.headline)
                    Text("Добавьте, например, «Загрузки» и «Документы». Сканирование только читает файлы.\nНичего не отправляется в интернет и не удаляется без вашего выбора.")
                        .multilineTextAlignment(.center).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer(minLength: 10)
            } else {
                HStack {
                    Text("Побайтовые совпадения · разный риск удаления").font(.headline)
                    Spacer()
                    Button("Снять выбор") { model.setAllGroups(false) }.disabled(model.busy)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.groups) { group in
                            groupCard(group)
                        }
                    }.padding(.vertical, 3)
                }
            }

            if !model.details.isEmpty {
                DisclosureGroup("Замечания и пропущенные файлы") {
                    ScrollView { Text(model.details).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 90)
                }.font(.caption)
            }
            Divider()
            HStack {
                Label("Недоказанные или рискованные случаи заблокированы · Корзина не очищается", systemImage: "shield.lefthalf.filled")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.selectedCopyCount > 0 && !showHistory {
                    Button {
                        model.showConfirmation = true
                    } label: {
                        Text("В Корзину: \(model.selectedCopyCount) · \(formatted(model.selectedBytes))")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .confirmationDialog(
            "Переместить \(model.selectedCopyCount) файлов в Корзину?",
            isPresented: $model.showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Переместить в Корзину", role: .destructive) { model.moveSelectedToTrash() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Для каждой группы сохранится выбранный экземпляр. Перед перемещением будет повторная побайтовая проверка. Корзину программа не очищает.")
        }
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.selectedGroups.contains(group.id) },
                    set: { enabled in
                        if enabled { model.selectedGroups.insert(group.id) }
                        else { model.selectedGroups.remove(group.id) }
                    }
                )) {
                    Text(group.files.first?.name ?? "Без имени")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                .disabled(model.busy || !group.canClean)
                Spacer()
                Text("\(group.copyCount) экз. · \(formatted(group.reclaimableBytes)) логически")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: group.canClean ? "checkmark.shield" :
                      (group.assessment.status == .review ? "exclamationmark.triangle" : "lock.shield"))
                Text(group.canClean ? "Допущено к ручной очистке" :
                     (group.assessment.status == .review ? "Требуется ручная проверка — очистка заблокирована" : "Защищено — очистка заблокирована"))
            }
            .font(.caption).foregroundStyle(group.canClean ? .green : .orange)
            if !group.assessment.reasons.isEmpty {
                ForEach(group.assessment.reasons, id: \.self) { reason in
                    Text("• " + reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(group.canClean ? "Выберите файл для сохранения. Остальные попадут только в Корзину." :
                 "Файлы доступны для сравнения и просмотра в Finder, но удалять их через ONECOPY нельзя.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(group.files) { file in
                HStack(spacing: 10) {
                    Button {
                        model.keeperPaths[group.id] = file.id
                    } label: {
                        Image(systemName: model.keeperPaths[group.id] == file.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 18)).foregroundColor(model.keeperPaths[group.id] == file.id ? .indigo : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .accessibilityLabel("Оставить \(file.name)")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(file.name).font(.system(size: 12, weight: .medium))
                            if model.keeperPaths[group.id] == file.id {
                                Text("ОСТАВИТЬ").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                            }
                        }
                        Text(file.folder).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Показать в Finder")
                }
                .padding(.vertical, 3)
            }
        }
        .padding(13)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("История перемещений").font(.headline)
                Spacer()
                Button("К результатам") { showHistory = false }
            }
            Text("Восстановление возможно, пока файл остаётся в Корзине и исходное место свободно.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.history) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: item.originalPath).lastPathComponent).font(.subheadline)
                                Text(item.originalPath).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Восстановить") { model.restore(item) }
                                .disabled(model.busy || item.trashedIdentity == nil ||
                                          !FileManager.default.fileExists(atPath: item.trashedPath))
                        }
                        Divider()
                    }
                }
            }
        }
    }
}

@main
struct OneCopyApp: App {
    var body: some Scene {
        WindowGroup("ONECOPY") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
#else
// Allows the cross-platform scanning engine to be tested on Linux build agents.
@main
struct OneCopyOnlyRunsOnMacOS {
    static func main() { print("The ONECOPY interface requires macOS 13 or later.") }
}
#endif
