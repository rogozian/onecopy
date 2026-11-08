import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class FilesModel: ObservableObject {
    @Published var folder: String?
    @Published var groups: [FolderDuplicateGroup] = []
    @Published var report: FolderScanReport?
    @Published var scanning = false
    @Published var error: String?

    func scan(_ url: URL) {
        guard !scanning else { return }
        scanning = true; folder = url.lastPathComponent
        groups = []; report = nil; error = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard accessed else { throw FolderError.permission }
                let result = try FolderScanner.scan(url)
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
}

struct FilesScreen: View {
    @StateObject private var model = FilesModel()
    @State private var showingPicker = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Проверка локальной папки", systemImage: "folder.badge.magnifyingglass")
                            .font(.headline)
                        Text("Выберите папку в «Файлах». Программа проверит содержимое и покажет точные совпадения. В этой версии удаление файлов отключено.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { showingPicker = true } label: {
                            Label("Выбрать папку", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.scanning)
                        if let folder = model.folder { Text("Папка: \(folder)").font(.caption) }
                        if model.scanning {
                            ProgressView("Проверяю содержимое…")
                        }
                    }
                    .padding(.vertical, 8)
                }
                if let report = model.report {
                    Section("Результаты") {
                        LabeledContent("Проверено файлов", value: String(report.enumerated))
                        LabeledContent("Групп", value: String(report.groups.count))
                        if report.skipped > 0 {
                            Text("Пропущено (облако, недоступные или нестандартные файлы): \(report.skipped)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Найденные копии") {
                        ForEach(model.groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("\(group.files.count) одинаковых файлов").font(.headline)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: group.bytesPerFile, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(group.files, id: \.absoluteString) { url in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent).font(.subheadline)
                                        Text(url.deletingLastPathComponent().lastPathComponent)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Label("Только просмотр — найдите экземпляры в «Файлах», если решите убрать их вручную.",
                                      systemImage: "hand.raised.fill")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .navigationTitle("ONECOPY · Файлы")
            .sheet(isPresented: $showingPicker) {
                FolderPicker { url in
                    showingPicker = false
                    model.scan(url)
                }
            }
            .alert("Проверка папки", isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )) {
                Button("ОК", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
