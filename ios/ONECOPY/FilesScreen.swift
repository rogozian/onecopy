import SwiftUI
import UniformTypeIdentifiers
import UIKit
import QuickLook

@MainActor
final class FilesModel: ObservableObject {
    @Published var folders: [URL] = []
    @Published var groups: [FolderDuplicateGroup] = []
    @Published var report: FolderScanReport?
    @Published var scanning = false
    @Published var error: String?

    func addFolders(_ new: [URL]) {
        guard !scanning else { return }
        for url in new {
            if !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                folders.append(url)
            }
        }
        if !folders.isEmpty { scan() }
    }

    func removeFolder(_ url: URL) {
        guard !scanning else { return }
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        groups = []
        report = nil
    }

    func scan() {
        guard !scanning, !folders.isEmpty else { return }
        let selected = folders
        scanning = true
        groups = []
        report = nil
        error = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let accessed = selected.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer {
                for (url, ok) in accessed where ok { url.stopAccessingSecurityScopedResource() }
            }
            do {
                guard accessed.allSatisfy({ $0.1 }) else { throw FolderError.permission }
                let result = try FolderScanner.scan(selected)
                DispatchQueue.main.async {
                    self?.report = result
                    self?.groups = result.groups
                    self?.scanning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self?.error = error.localizedDescription
                    self?.scanning = false
                }
            }
        }
    }

    func scope(for file: URL) -> URL? {
        let standardized = file.standardizedFileURL.path
        return folders.first { root in
            let path = root.standardizedFileURL.path
            return standardized == path || standardized.hasPrefix(path + "/")
        }
    }
}

struct FilesScreen: View {
    @StateObject private var model = FilesModel()
    @State private var showingPicker = false
    @State private var preview: FilePreviewTarget?
    @State private var keeperPaths: [String: String] = [:]
    @State private var selectedPaths: Set<String> = []

    private var removablePaths: Set<String> {
        let allowed = model.groups.flatMap { group -> [String] in
            guard let original = group.files.first else { return [] }
            let keeper = keeperPaths[group.id] ?? original.path
            return group.files.filter { $0.path != keeper }.map(\.path)
        }
        return Set(allowed)
    }

    private var chosenPaths: Set<String> {
        selectedPaths.intersection(removablePaths)
    }

    private var reportText: String {
        var lines = [
            "ONECOPY · отчёт о совпадениях файлов",
            "Выбранные папки: \(model.folders.count)",
            "Всего групп: \(model.groups.count)",
            "Выбрано в список для ручной проверки: \(chosenPaths.count)",
            "",
            "ONECOPY не удаляет файлы из выбранных папок автоматически.",
            ""
        ]
        for (index, group) in model.groups.enumerated() {
            guard let original = group.files.first else { continue }
            let keeper = keeperPaths[group.id] ?? original.path
            lines.append("Группа \(index + 1) · \(group.files.count) одинаковых · " +
                         ByteCountFormatter.string(fromByteCount: group.bytesPerFile, countStyle: .file))
            for file in group.files {
                let mark = file.path == keeper ? "ОСТАВИТЬ" :
                    (chosenPaths.contains(file.path) ? "В СПИСКЕ" : "ПРОВЕРИТЬ")
                lines.append("\(mark) · \(file.path)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Папки и подпапки", systemImage: "folder.badge.magnifyingglass")
                            .font(.headline)
                        Text("Можно добавить несколько папок из «Файлов». ONECOPY проверит их рекурсивно и найдёт точные копии в том числе между разными папками.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { showingPicker = true } label: {
                            Label(model.folders.isEmpty ? "ВЫБРАТЬ ПАПКИ" : "ДОБАВИТЬ ПАПКИ",
                                  systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.scanning)
                        if !model.folders.isEmpty {
                            Button {
                                keeperPaths = [:]
                                selectedPaths = []
                                model.scan()
                            } label: {
                                Label("Сканировать все выбранные папки", systemImage: "viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(model.scanning)
                        }
                        if model.scanning {
                            ProgressView("Проверяю выбранные папки…")
                        }
                    }.padding(.vertical, 9)
                }

                if !model.folders.isEmpty {
                    Section("Разрешённые папки · \(model.folders.count)") {
                        ForEach(model.folders, id: \.absoluteString) { url in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.lastPathComponent).font(.subheadline)
                                    Text(url.path).font(.caption2)
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    keeperPaths = [:]
                                    selectedPaths = []
                                    model.removeFolder(url)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless).disabled(model.scanning)
                            }
                        }
                    }
                }

                if let report = model.report {
                    Section("Результаты") {
                        LabeledContent("Проверено файлов", value: String(report.enumerated))
                        LabeledContent("Групп точных совпадений", value: String(report.groups.count))
                        if report.skipped > 0 {
                            Text("Пропущено недоступных, облачных и нестандартных элементов: \(report.skipped)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !report.groups.isEmpty {
                            HStack {
                                Button("Выбрать все повторы") {
                                    selectedPaths = removablePaths
                                }
                                Spacer()
                                Button("Сбросить") {
                                    selectedPaths = []
                                }
                            }.font(.subheadline)
                            LabeledContent("Отмечено для ручной проверки", value: String(chosenPaths.count))
                            ShareLink(item: reportText) {
                                Label("Поделиться списком и расположением файлов", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("В выбранных папках точных копий не найдено.")
                        }
                    }

                    if !model.groups.isEmpty {
                        Section("Найденные файлы — нажмите, чтобы открыть") {
                            ForEach(model.groups) { group in
                                VStack(alignment: .leading, spacing: 11) {
                                    HStack {
                                        Text("\(group.files.count) одинаковых файлов").font(.headline)
                                        Spacer()
                                        Text(ByteCountFormatter.string(fromByteCount: group.bytesPerFile, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(group.files, id: \.absoluteString) { file in
                                        HStack(spacing: 10) {
                                            Button {
                                                if let root = model.scope(for: file) {
                                                    preview = FilePreviewTarget(file: file, scopeRoot: root)
                                                } else {
                                                    model.error = "Нет разрешения на открытие этого файла."
                                                }
                                            } label: {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Label(file.lastPathComponent, systemImage: "doc.text.magnifyingglass")
                                                        .font(.subheadline).lineLimit(2)
                                                    Text(file.deletingLastPathComponent().path)
                                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            Spacer(minLength: 3)
                                            let keeper = keeperPaths[group.id] ?? group.files[0].path
                                            if file.path == keeper {
                                                Label("Оставить", systemImage: "checkmark.circle.fill")
                                                    .font(.caption).foregroundStyle(.green)
                                            } else {
                                                Toggle("В список", isOn: Binding(
                                                    get: { selectedPaths.contains(file.path) },
                                                    set: { checked in
                                                        if checked { selectedPaths.insert(file.path) }
                                                        else { selectedPaths.remove(file.path) }
                                                    }
                                                ))
                                                .labelsHidden()
                                            }
                                        }
                                        if (keeperPaths[group.id] ?? group.files[0].path) != file.path {
                                            Button("Сохранить именно этот экземпляр") {
                                                keeperPaths[group.id] = file.path
                                                selectedPaths.remove(file.path)
                                            }
                                            .font(.caption).buttonStyle(.borderless)
                                        }
                                        Divider()
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }

                Section {
                    Label("ONECOPY не удаляет файлы в «Файлах» без гарантии восстановления. Откройте объект для предварительного просмотра, а список путей используйте для ручной проверки.", systemImage: "hand.raised.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ONECOPY · Файлы")
            .sheet(isPresented: $showingPicker) {
                FolderPicker { urls in
                    showingPicker = false
                    keeperPaths = [:]
                    selectedPaths = []
                    model.addFolders(urls)
                }
            }
            .sheet(item: $preview) { target in
                FileQuickLook(file: target.file, scopeRoot: target.scopeRoot)
            }
            .alert("ONECOPY", isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )) {
                Button("ОК", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

private struct FilePreviewTarget: Identifiable {
    let file: URL
    let scopeRoot: URL
    var id: String { file.absoluteString }
}

/// The security scope must remain active until Quick Look has finished.
private struct FileQuickLook: UIViewControllerRepresentable {
    let file: URL
    let scopeRoot: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(file: file, root: scopeRoot)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        context.coordinator.accessed = scopeRoot.startAccessingSecurityScopedResource()
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return preview
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) {
        if coordinator.accessed {
            coordinator.root.stopAccessingSecurityScopedResource()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: URL
        let root: URL
        var accessed = false

        init(file: URL, root: URL) {
            self.file = file
            self.root = root
        }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            file as NSURL
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
