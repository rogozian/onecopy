import SwiftUI

@main
struct ONECOPYApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                PhotosScreen()
                    .tabItem { Label("Фото", systemImage: "photo.on.rectangle") }
                FilesScreen()
                    .tabItem { Label("Файлы", systemImage: "folder") }
                AboutScreen()
                    .tabItem { Label("О приложении", systemImage: "shield.lefthalf.filled") }
            }
            .tint(.indigo)
        }
    }
}

struct AboutScreen: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Безопасность") {
                    Label("Все проверки выполняются на устройстве", systemImage: "iphone.gen3")
                    Label("Никаких фоновых удалений", systemImage: "hand.raised")
                    Label("Сравнение байтов, а не названий", systemImage: "checkmark.shield")
                }
                Section("Особенности iPhone") {
                    Text("Фото: удаление возможно только после выбора конкретных элементов, повторной проверки и подтверждения iOS.")
                    Text("Если включены «Фото iCloud», удаление из медиатеки синхронизируется с другими устройствами Apple.")
                    Text("Файлы: в этой версии выполняется только безопасный поиск в выбранной папке; удаление через файловые провайдеры не выполняется.")
                    Text("Live Photos, избранное, скрытые и отредактированные объекты не включаются в поиск. Облачные оригиналы не загружаются.")
                }
                Section("Версия") { Text("ONECOPY для iOS · 0.2 · тестовая сборка") }
            }
            .navigationTitle("ONECOPY")
        }
    }
}
