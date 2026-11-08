import SwiftUI
import Photos
import UIKit

@MainActor
final class PhotosModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    @Published var scanning = false
    @Published var deleting = false
    @Published var progressText = ""
    @Published var report: PhotoScanReport?
    @Published var error: String?
    @Published var limited = false

    func requestAndScan() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                self.limited = status == .limited
                guard status == .authorized || status == .limited else {
                    self.error = "Для проверки откройте доступ к медиатеке в настройках iPhone."
                    return
                }
                self.scan()
            }
        }
    }

    func scan() {
        guard !scanning, !deleting else { return }
        groups = []; report = nil; scanning = true; progressText = "Читаю данные медиатеки…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = PhotoScanner.scan { current, count in
                DispatchQueue.main.async {
                    self?.progressText = "Проверено \(current) из \(count) кандидатов"
                }
            }
            DispatchQueue.main.async {
                self?.groups = result.groups
                self?.report = result
                self?.scanning = false
                self?.progressText = ""
            }
        }
    }

    func delete(keeping keeper: PHAsset, selected: [PHAsset]) {
        guard !deleting, !scanning, !selected.isEmpty else { return }
        deleting = true
        progressText = "Повторно сверяю оригинальные байты…"
        let keeperID = keeper.localIdentifier
        let ids = selected.map(\.localIdentifier)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let verified = try PhotoScanner.verifyBeforeDeletion(keeperID: keeperID, removeIDs: ids)
                DispatchQueue.main.async {
                    self?.progressText = "Ожидаю подтверждение iOS…"
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.deleteAssets(verified as NSArray)
                    }, completionHandler: { success, issue in
                        DispatchQueue.main.async {
                            self?.deleting = false
                            self?.progressText = ""
                            if success {
                                self?.groups = []
                                self?.report = nil
                                self?.error = "Готово. Откройте «Недавно удалённые» в Фото для проверки или восстановления. Для обновления результатов запустите поиск снова."
                            } else {
                                self?.error = issue?.localizedDescription ?? "Удаление не подтверждено системой."
                            }
                        }
                    })
                }
            } catch {
                DispatchQueue.main.async {
                    self?.deleting = false
                    self?.progressText = ""
                    self?.error = error.localizedDescription
                }
            }
        }
    }
}

struct PhotosScreen: View {
    @StateObject private var model = PhotosModel()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Только точные копии", systemImage: "checkmark.shield.fill")
                            .font(.headline)
                        Text("Ищем фотографии и видео с побайтово совпадающими исходными медиаданными. Ничего не удаляем автоматически.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if model.limited {
                            Label("Проверяется только выбранная часть медиатеки", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Button {
                            model.requestAndScan()
                        } label: {
                            Label("Сканировать Фото", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.scanning || model.deleting)
                        if model.scanning || model.deleting {
                            ProgressView()
                            Text(model.progressText).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                if let r = model.report {
                    Section("Результаты") {
                        LabeledContent("Групп совпадений", value: String(r.groups.count))
                        LabeledContent("Просмотрено объектов", value: String(r.totalAssets))
                        LabeledContent("Кандидатов на проверку", value: String(r.candidates))
                        if r.skippedUnavailable > 0 {
                            Text("Не проверены без скачивания из iCloud: \(r.skippedUnavailable)")
                                .foregroundStyle(.secondary)
                        }
                        if r.groups.isEmpty {
                            Text("Среди проверенных объектов точные копии не обнаружены.")
                        }
                    }
                }
                if !model.groups.isEmpty {
                    Section("Совпадающие оригиналы") {
                        ForEach(model.groups) { group in
                            PhotoGroupCard(group: group, busy: model.deleting || model.scanning) { keeper, selected in
                                model.delete(keeping: keeper, selected: selected)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ONECOPY · Фото")
            .alert("ONECOPY", isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )) {
                Button("ОК", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

private struct PhotoGroupCard: View {
    let group: PhotoGroup
    let busy: Bool
    let delete: (PHAsset, [PHAsset]) -> Void
    @State private var keeperID: String = ""
    @State private var removeIDs: Set<String> = []
    @State private var showConfirmation = false

    private var keeper: PHAsset? {
        group.items.first { $0.localIdentifier == keeperID }
    }
    private var selected: [PHAsset] {
        group.items.filter { removeIDs.contains($0.localIdentifier) && $0.localIdentifier != keeperID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(group.mediaType == .video ? "Видео" : "Фото", systemImage: group.mediaType == .video ? "film" : "photo")
                    .font(.headline)
                Spacer()
                Text("\(group.items.count) копий")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(group.items, id: \.localIdentifier) { asset in
                HStack(spacing: 10) {
                    AssetThumbnail(asset: asset)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Медиафайл")
                            .lineLimit(2).font(.subheadline)
                        Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Дата неизвестна")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button {
                                keeperID = asset.localIdentifier
                                removeIDs.remove(asset.localIdentifier)
                            } label: {
                                Label("Оставить", systemImage: keeperID == asset.localIdentifier ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            if asset.isFavorite {
                                Label("Избранное · защищено", systemImage: "star.fill")
                                    .foregroundStyle(.orange).font(.caption2)
                            } else if keeperID != asset.localIdentifier {
                                Button {
                                    if removeIDs.contains(asset.localIdentifier) {
                                        removeIDs.remove(asset.localIdentifier)
                                    } else {
                                        removeIDs.insert(asset.localIdentifier)
                                    }
                                } label: {
                                    Label("Убрать", systemImage: removeIDs.contains(asset.localIdentifier) ? "checkmark.square.fill" : "square")
                                }
                                .tint(.red).buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            Button(role: .destructive) {
                showConfirmation = true
            } label: {
                Label("Удалить выбранные (\(selected.count))", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy || keeper == nil || selected.isEmpty)
            .confirmationDialog("Проверить и удалить выбранные?", isPresented: $showConfirmation, titleVisibility: .visible) {
                Button("Проверить и отправить \(selected.count) в «Недавно удалённые»", role: .destructive) {
                    guard let keeper else { return }
                    delete(keeper, selected)
                }
            } message: {
                Text("Удаление из Фото синхронизируется через iCloud, если он включён. Понадобится системное подтверждение. Мы повторно сравним все байты. Не удаляйте снимки, если важны их альбомы, подписи, история или другие связи.")
            }
            Text("Совпадает только исходный медиафайл. Альбомы, подписи и связи могут различаться.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { if keeperID.isEmpty { keeperID = group.items[0].localIdentifier } }
    }
}

private struct AssetThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
        }
        .frame(width: 70, height: 70)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: 150, height: 150), contentMode: .aspectFill,
                options: options) { result, _ in
                    if let result { DispatchQueue.main.async { image = result } }
                }
        }
    }
}
