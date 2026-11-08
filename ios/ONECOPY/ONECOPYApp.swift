import SwiftUI

@main
struct ONECOPYApp: App {
    @StateObject private var photos = PhotosModel()
    @StateObject private var files = FilesModel()
    @State private var selectedTab = 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ScannerHome(photos: photos, files: files, selectedTab: $selectedTab)
                    .tabItem { Label("Сканер", systemImage: "viewfinder") }.tag(0)
                PhotosScreen(model: photos)
                    .tabItem { Label("Фото", systemImage: "photo.on.rectangle") }.tag(1)
                FilesScreen(model: files)
                    .tabItem { Label("Файлы", systemImage: "folder") }.tag(2)
                AboutScreen()
                    .tabItem { Label("О приложении", systemImage: "shield.lefthalf.filled") }.tag(3)
            }
            .tint(.indigo)
        }
    }
}

/// Main workflow: one tap scans the Photos library the user authorized, plus
/// folders the user previously selected in the Files document picker.
/// iOS does not permit arbitrary traversal of the whole device filesystem.
struct ScannerHome: View {
    @ObservedObject var photos: PhotosModel
    @ObservedObject var files: FilesModel
    @Binding var selectedTab: Int

    private var busy: Bool { photos.scanning || photos.deleting || files.scanning }
    private var photoGroupCount: Int { photos.report?.groups.count ?? 0 }
    private var folderGroupCount: Int { files.report?.groups.count ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Локальный сканер", systemImage: "lock.shield.fill")
                            .font(.caption.weight(.bold)).foregroundStyle(.green)
                        Text("Освободи память.\nНе потеряй важное.")
                            .font(.largeTitle.bold())
                        Text("Ищем точные побайтовые копии. Никакого удаления без твоего выбора.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)

                    VStack(spacing: 18) {
                        Button {
                            photos.requestAndScan()
                            if !files.folders.isEmpty { files.scan() }
                        } label: {
                            VStack(spacing: 14) {
                                Image(systemName: busy ? "hourglass" : "viewfinder")
                                    .font(.system(size: 57, weight: .light))
                                Text(busy ? "ИДЁТ ПРОВЕРКА" : "СКАНИРОВАТЬ")
                                    .font(.title2.bold())
                                    .tracking(1.1)
                                Text(busy ? "Читаем разрешённые данные" : "Фото + добавленные папки")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.86))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 226)
                            .background(
                                LinearGradient(colors: [.indigo, Color(red: 0.28, green: 0.38, blue: 0.96)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 32))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .accessibilityHint("Сканирует всю разрешённую медиатеку и папки, добавленные в разделе «Файлы»")

                        if photos.scanning || files.scanning {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView()
                                if photos.scanning {
                                    Text("Фото: \(photos.progressText)").font(.footnote)
                                }
                                if files.scanning {
                                    Text("Файлы: проверяю выбранные папки…").font(.footnote)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if photos.limited {
                            Label("Дан ограниченный доступ к «Фото». Для полного поиска включи «Все фото» в настройках iPhone.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        if let error = photos.error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        if let error = files.error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }

                    VStack(spacing: 12) {
                        Button {
                            selectedTab = 1
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "photo.stack.fill").font(.title2)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Медиатека «Фото»").font(.headline)
                                    Text(photos.scanning ? "Выполняется сканирование…" :
                                            (photos.report == nil ? "Сканирование ещё не выполнено" :
                                            "\(photoGroupCount) групп точных копий"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(19)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 19))
                        }
                        .buttonStyle(.plain)

                        Button {
                            selectedTab = 2
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "folder.fill").font(.title2)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Папки и документы").font(.headline)
                                    Text(files.folders.isEmpty
                                         ? "Добавь папки для рекурсивной проверки"
                                         : "\(files.folders.count) папок · \(folderGroupCount) групп совпадений")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(19)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 19))
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Что доступно сканеру").font(.headline)
                        Text("«Фото»: вся разрешённая медиатека, кроме защищённых и сложных объектов, которые программа явно пропускает. «Файлы»: только папки, которые ты разрешил через системный выбор; вложенные папки включаются.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Результаты открываются на вкладках «Фото» и «Файлы». Выбор и массовое удаление доступны для проверенных копий в медиатеке; документы пока только для просмотра и ручной проверки.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.background, in: RoundedRectangle(cornerRadius: 19))
                }
                .padding(19)
            }
            .navigationTitle("ONECOPY")
        }
    }
}

struct AboutScreen: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Безопасность") {
                    Label("Сравнение и обработка только на iPhone", systemImage: "iphone.gen3")
                    Label("Не удаляем без подтверждения", systemImage: "hand.raised")
                    Label("Каждое совпадение проверяется по всем байтам", systemImage: "checkmark.shield")
                }
                Section("Ограничения iOS") {
                    Text("ONECOPY не может получить доступ ко всей файловой системе телефона. Для «Фото» нужен полный доступ, для документов — выбор папок.")
                    Text("Удаление из «Фото» синхронизируется через iCloud с другими устройствами, если он включён. Отличающиеся метаданные, альбомы и связи между фотографиями могут оказаться важны.")
                    Text("Live Photos, скрытые, сложные, отредактированные и недоступные в iCloud оригиналы не подвергаются удалению: их нужно обрабатывать отдельно.")
                    Text("Папки из «Файлов»: сканирование и просмотр найденных объектов, без автоматического удаления.")
                }
                Section("Версия") {
                    Text("ONECOPY iOS 0.3 · тестовая сборка, не предназначенная для удаления реальных данных без проверки на устройстве.")
                }
            }
            .navigationTitle("ONECOPY")
        }
    }
}
