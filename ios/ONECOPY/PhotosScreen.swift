import SwiftUI
import Photos
import UIKit
import AVKit

struct PhotoRemovalPlan {
    let keeperID: String
    let removeIDs: [String]
}

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
                    self.error = "Для поиска по всей медиатеке разрешите ONECOPY полный доступ к «Фото» в настройках iPhone."
                    return
                }
                self.scan()
            }
        }
    }

    func scan() {
        guard !scanning, !deleting else { return }
        groups = []; report = nil; scanning = true; progressText = "Индексирую медиатеку…"
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

    /// Validate each duplicate group independently, then ask iOS to delete
    /// all verified candidates in one confirmed transaction. Never auto-delete.
    func deleteBatch(_ plans: [PhotoRemovalPlan]) {
        guard !scanning, !deleting, !plans.isEmpty else { return }
        let allKeepers = Set(plans.map(\.keeperID))
        let allRemoveIDs = plans.flatMap(\.removeIDs)
        guard !allRemoveIDs.isEmpty,
              Set(allRemoveIDs).count == allRemoveIDs.count,
              allKeepers.isDisjoint(with: allRemoveIDs) else {
            error = "Некорректный набор для удаления. Ничего не удалено."
            return
        }
        deleting = true
        progressText = "Повторно проверяю оригинальные байты…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let verified = try plans.flatMap {
                    try PhotoScanner.verifyBeforeDeletion(keeperID: $0.keeperID, removeIDs: $0.removeIDs)
                }
                DispatchQueue.main.async {
                    self?.progressText = "Ожидаю системное подтверждение iOS…"
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.deleteAssets(verified as NSArray)
                    }, completionHandler: { success, issue in
                        DispatchQueue.main.async {
                            self?.deleting = false
                            self?.progressText = ""
                            if success {
                                self?.groups = []
                                self?.report = nil
                                self?.error = "Выбранные объекты отправлены в «Недавно удалённые». Проверьте их перед окончательной очисткой. Для обновления результатов запустите сканирование снова."
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
    @ObservedObject var model: PhotosModel
    @State private var keepers: [String: String] = [:]
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchConfirmation = false

    private var safeSelectedCount: Int {
        model.groups.reduce(0) { count, group in
            let keeper = keepers[group.id] ?? group.items.first?.localIdentifier ?? ""
            return count + group.items.filter {
                selectedIDs.contains($0.localIdentifier) &&
                $0.localIdentifier != keeper && !$0.isFavorite
            }.count
        }
    }

    private var removalPlans: [PhotoRemovalPlan] {
        model.groups.compactMap { group in
            guard let first = group.items.first else { return nil }
            let keeper = keepers[group.id] ?? first.localIdentifier
            let remove = group.items.filter {
                $0.localIdentifier != keeper && selectedIDs.contains($0.localIdentifier) && !$0.isFavorite
            }.map(\.localIdentifier)
            return remove.isEmpty ? nil : PhotoRemovalPlan(keeperID: keeper, removeIDs: remove)
        }
    }

    private func selectSafeCopies() {
        var ids: Set<String> = []
        for group in model.groups {
            let keeper = keepers[group.id] ?? group.items[0].localIdentifier
            for asset in group.items where asset.localIdentifier != keeper && !asset.isFavorite {
                ids.insert(asset.localIdentifier)
            }
        }
        selectedIDs = ids
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Label("Поиск по всей медиатеке", systemImage: "photo.on.rectangle.angled")
                                .font(.headline)
                            Spacer()
                            Label("Локально", systemImage: "lock.shield")
                                .font(.caption).foregroundStyle(.green)
                        }
                        Text("ONECOPY просматривает доступную медиатеку, сравнивает оригиналы и показывает только побайтово совпадающие экземпляры.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            keepers = [:]
                            selectedIDs = []
                            model.requestAndScan()
                        } label: {
                            Label(model.scanning ? "СКАНИРОВАНИЕ…" : "СКАНИРОВАТЬ ФОТО И ВИДЕО",
                                  systemImage: "viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(model.scanning || model.deleting)
                        if model.limited {
                            Label("iOS разрешила доступ только к выбранным фотографиям. Для полного поиска переключите доступ ONECOPY на «Все фото» в настройках.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.footnote)
                        }
                        if model.scanning || model.deleting {
                            ProgressView()
                            Text(model.progressText).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                }

                if let r = model.report {
                    Section("Результат сканирования") {
                        LabeledContent("Объектов медиатеки", value: String(r.totalAssets))
                        LabeledContent("Точных групп", value: String(r.groups.count))
                        LabeledContent("Кандидатов", value: String(r.candidates))
                        if r.skippedComplex > 0 {
                            LabeledContent("Защищённые или сложные форматы — пропущено", value: String(r.skippedComplex))
                        }
                        if r.skippedUnavailable > 0 {
                            LabeledContent("Недоступны без iCloud — пропущено", value: String(r.skippedUnavailable))
                        }
                        if r.groups.isEmpty {
                            Text("Среди проверенных оригиналов совпадений нет.")
                        } else {
                            HStack {
                                Button("Выбрать все безопасные копии") { selectSafeCopies() }
                                    .disabled(model.deleting)
                                Spacer()
                                Button("Сбросить") { selectedIDs = [] }
                                    .disabled(model.deleting || selectedIDs.isEmpty)
                            }.font(.subheadline)
                            LabeledContent("Выбрано для проверки на удаление", value: String(safeSelectedCount))
                            Button(role: .destructive) {
                                showBatchConfirmation = true
                            } label: {
                                Label("Проверить и удалить выбранные (\(safeSelectedCount))", systemImage: "trash")
                                    .frame(maxWidth: .infinity, minHeight: 45)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.deleting || model.scanning || safeSelectedCount == 0)
                        }
                    }
                }

                if !model.groups.isEmpty {
                    Section("Найденные точные копии") {
                        ForEach(model.groups) { group in
                            PhotoGroupCard(group: group,
                                           busy: model.deleting || model.scanning,
                                           keepers: $keepers,
                                           selectedIDs: $selectedIDs)
                        }
                    }
                }
            }
            .navigationTitle("ONECOPY · Фото")
            .confirmationDialog("Удалить \(safeSelectedCount) выбранных копий?", isPresented: $showBatchConfirmation,
                                titleVisibility: .visible) {
                Button("Повторно проверить и отправить в «Недавно удалённые»", role: .destructive) {
                    model.deleteBatch(removalPlans)
                }
            } message: {
                Text("Удаление из «Фото» может синхронизироваться с iCloud и другими устройствами. Альбомы, подписи и связи могут отличаться даже у идентичных файлов. ONECOPY ещё раз сравнит оригиналы, а iOS попросит подтверждение.")
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

private struct PhotoGroupCard: View {
    let group: PhotoGroup
    let busy: Bool
    @Binding var keepers: [String: String]
    @Binding var selectedIDs: Set<String>
    @State private var preview: PhotoPreviewTarget?

    private var keeperID: String { keepers[group.id] ?? group.items[0].localIdentifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(group.mediaType == .video ? "Видео" : "Фото", systemImage: group.mediaType == .video ? "film" : "photo")
                    .font(.headline)
                Spacer()
                Text("\(group.items.count) одинаковых").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(group.items, id: \.localIdentifier) { asset in
                HStack(spacing: 10) {
                    Button {
                        preview = PhotoPreviewTarget(asset: asset)
                    } label: {
                        AssetThumbnail(asset: asset)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Открыть \(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "медиафайл")")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Медиафайл")
                            .lineLimit(2).font(.subheadline)
                        Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Дата неизвестна")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                keepers[group.id] = asset.localIdentifier
                                selectedIDs.remove(asset.localIdentifier)
                            } label: {
                                Label("Оставить", systemImage: keeperID == asset.localIdentifier ? "checkmark.circle.fill" : "circle")
                            }.buttonStyle(.borderless).font(.caption)
                            if asset.isFavorite {
                                Label("Избранное — защищено", systemImage: "star.fill")
                                    .foregroundStyle(.orange).font(.caption2)
                            } else if keeperID != asset.localIdentifier {
                                Button {
                                    if selectedIDs.contains(asset.localIdentifier) {
                                        selectedIDs.remove(asset.localIdentifier)
                                    } else {
                                        selectedIDs.insert(asset.localIdentifier)
                                    }
                                } label: {
                                    Label("К удалению", systemImage: selectedIDs.contains(asset.localIdentifier) ? "checkmark.square.fill" : "square")
                                }.tint(.red).buttonStyle(.borderless).font(.caption)
                                    .disabled(busy)
                            }
                        }
                    }
                }.padding(.vertical, 5)
            }
            Text("Нажми на миниатюру для просмотра. Сохраняемый экземпляр не будет удалён.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(item: $preview) { target in
            PhotoPreviewScreen(asset: target.asset)
        }
    }
}

private struct PhotoPreviewTarget: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

private struct PhotoPreviewScreen: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else if unavailable {
                    ContentUnavailableView("Оригинал недоступен локально",
                                           systemImage: "icloud.slash",
                                           description: Text("ONECOPY не загружает материалы из iCloud автоматически."))
                } else {
                    ProgressView("Открываю выбранный файл…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
            .navigationTitle(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Просмотр")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .onAppear {
            if asset.mediaType == .video {
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = false
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                    DispatchQueue.main.async {
                        if let item { player = AVPlayer(playerItem: item) }
                        else { unavailable = true }
                    }
                }
            } else {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat
                PHImageManager.default().requestImage(for: asset,
                    targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit,
                    options: options) { result, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    DispatchQueue.main.async {
                        if let result { image = result }
                        else { unavailable = true }
                    }
                }
            }
        }
        .onDisappear {
            player?.pause()
        }
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
        .frame(width: 72, height: 72)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill,
                options: options) { result, _ in
                    if let result { DispatchQueue.main.async { image = result } }
                }
        }
    }
}
