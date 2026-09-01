import AppKit
import SwiftUI

@main
struct AppTransferApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

struct TransferItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let kind: String
    let size: Int64
    let bundleIdentifier: String?

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct TransferVolume: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let available: Int64
    let total: Int64

    var availableLabel: String {
        ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published var volumes: [TransferVolume] = []
    @Published var sourceLocation: URL?
    @Published var selectedItem: TransferItem?
    @Published var selectedVolume: TransferVolume?
    @Published var isBusy = false
    @Published var status = "Выберите приложение или папку для переноса"
    @Published var progress = 0.0
    @Published var showConfirmation = false
    @Published var showError = false
    @Published var errorMessage = ""

    private let fileManager = FileManager.default

    init() {
        volumes = scanVolumes()
        selectedVolume = volumes.first(where: { $0.url.path == "/Volumes/CUSU256DOC" }) ?? volumes.first
    }

    func refresh() {
        volumes = scanVolumes()
        selectedVolume = selectedVolume.flatMap { current in
            volumes.first(where: { $0.url == current.url })
        } ?? volumes.first(where: { $0.url.path == "/Volumes/CUSU256DOC" }) ?? volumes.first
        if let sourceLocation {
            items = scanItems(at: sourceLocation)
        }
    }

    func chooseItem() {
        let panel = NSOpenPanel()
        panel.title = "Выберите приложение или папку"
        panel.message = "Можно выбрать .app или любую папку с данными"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.select(url: url)
            }
        }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Выберите источник переноса"
        panel.message = "Выберите диск, папку или приложение, откуда переносить данные"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.setSource(url)
            }
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку на другом диске"
        panel.message = "Лучше выбирать внешний диск или отдельную папку на нём"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.selectedVolume = TransferVolume(
                    url: url,
                    name: url.lastPathComponent,
                    available: self?.availableSpace(at: url) ?? 0,
                    total: 0
                )
            }
        }
    }

    func requestTransfer() {
        guard selectedItem != nil, selectedVolume != nil else { return }
        showConfirmation = true
    }

    func transfer() {
        guard let item = selectedItem, let volume = selectedVolume else { return }
        showConfirmation = false
        isBusy = true
        progress = 0
        status = "Подготавливаю перенос..."

        let source = item.url
        let destinationRoot = volume.url.appendingPathComponent("App Transfer")

        let model = self
        Task.detached(priority: .userInitiated) {
            do {
                let destination = try TransferService.transfer(
                    source: source,
                    destinationRoot: destinationRoot
                ) { message, value in
                    Task { @MainActor in
                        model.status = message
                        model.progress = value
                    }
                }
                await MainActor.run {
                    model.status = "Готово: \(destination.lastPathComponent) перенесено"
                    model.progress = 1
                    model.isBusy = false
                    model.refresh()
                    model.select(url: source)
                }
            } catch {
                await MainActor.run {
                    model.errorMessage = error.localizedDescription
                    model.showError = true
                    model.status = "Перенос не выполнен"
                    model.isBusy = false
                }
            }
        }
    }

    private func select(url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey])
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            let isApp = url.pathExtension == "app"
            let identifier = Bundle(url: url)?.bundleIdentifier
            selectedItem = TransferItem(
                url: url,
                name: url.lastPathComponent,
                kind: isApp ? "Приложение" : (values.isDirectory == true ? "Папка" : "Файл"),
                size: max(size, directorySize(url)),
                bundleIdentifier: identifier
            )
            sourceLocation = values.isDirectory == true ? url : url.deletingLastPathComponent()
            if values.isDirectory == true && url.pathExtension != "app" {
                items = scanItems(at: url)
            }
            status = "Готово к переносу"
        } catch {
            errorMessage = "Не удалось прочитать выбранный объект: \(error.localizedDescription)"
            showError = true
        }
    }

    private func setSource(_ url: URL) {
        sourceLocation = url
        if url.pathExtension == "app" {
            select(url: url)
        } else {
            selectedItem = nil
            items = scanItems(at: url)
            status = "Источник выбран. Теперь выберите объект для переноса"
        }
    }

    private func scanItems(at location: URL) -> [TransferItem] {
        var result: [TransferItem] = []
        guard let entries = try? fileManager.contentsOfDirectory(
            at: location,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for url in entries {
            let isApp = url.pathExtension == "app"
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey])
            let isDirectory = values?.isDirectory == true
            guard isApp || isDirectory else { continue }
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            result.append(TransferItem(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                kind: isApp ? "Приложение" : "Папка",
                size: max(size, directorySize(url)),
                bundleIdentifier: Bundle(url: url)?.bundleIdentifier
            ))
        }
        return Array(Set(result)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanVolumes() -> [TransferVolume] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            guard url.path != "/Volumes/Macintosh HD",
                  let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
                  let available = values.volumeAvailableCapacity else { return nil }
            return TransferVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                available: Int64(available),
                total: Int64(values.volumeTotalCapacity ?? 0)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func availableSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

enum TransferError: LocalizedError {
    case sourceMissing
    case unsupportedSource
    case destinationExists
    case insufficientSpace
    case verificationFailed
    case linkFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "Исходный объект больше не существует."
        case .unsupportedSource: return "Нельзя переносить системные объекты, сам App Transfer или уже перенесённую ссылку."
        case .destinationExists: return "В папке назначения уже есть объект с таким именем."
        case .insufficientSpace: return "На выбранном диске недостаточно свободного места."
        case .verificationFailed: return "Проверка копии не прошла. Исходные данные не изменены."
        case .linkFailed(let message): return "Файлы скопированы, но ссылку создать не удалось: \(message)"
        }
    }
}

enum TransferService {
    static func transfer(
        source: URL,
        destinationRoot: URL,
        progress: @escaping (String, Double) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw TransferError.sourceMissing
        }
        guard source.pathExtension != "app" || !source.path.hasPrefix("/System") else {
            throw TransferError.unsupportedSource
        }
        guard source.path != "/" && !source.path.hasPrefix("/System/Library") else {
            throw TransferError.unsupportedSource
        }
        var isSymlink = false
        if let attributes = try? fm.attributesOfItem(atPath: source.path),
           let type = attributes[.type] as? FileAttributeType {
            isSymlink = type == .typeSymbolicLink
        }
        guard !isSymlink else { throw TransferError.unsupportedSource }

        try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
        guard !fm.fileExists(atPath: destination.path) else { throw TransferError.destinationExists }

        let sourceSize = directorySize(source, fileManager: fm)
        let free = try destinationRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(free) > sourceSize + 512 * 1024 * 1024 else { throw TransferError.insufficientSpace }

        progress("Копирую \(source.lastPathComponent)...", 0.15)
        try fm.copyItem(at: source, to: destination)
        progress("Проверяю копию...", 0.8)

        let destinationSize = directorySize(destination, fileManager: fm)
        guard destinationSize >= sourceSize else {
            try? fm.removeItem(at: destination)
            throw TransferError.verificationFailed
        }

        progress("Создаю ссылку на старом месте...", 0.9)
        do {
            try fm.removeItem(at: source)
            try fm.createSymbolicLink(at: source, withDestinationURL: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw TransferError.linkFailed(error.localizedDescription)
        }
        progress("Перенос завершён", 1)
        return destination
    }

    private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                itemPanel
                Divider()
                destinationPanel
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Подтвердить перенос", isPresented: $model.showConfirmation) {
            Button("Перенести", role: .destructive) { model.transfer() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Данные будут скопированы на выбранный диск, проверены, а старый путь заменён ссылкой. Не отключайте диск во время операции.")
        }
        .alert("Не удалось перенести", isPresented: $model.showError) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Transfer")
                    .font(.title2.weight(.semibold))
                Text("Перенос приложений и данных между дисками")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            Spacer()
            Button { model.refresh() } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
        }
        .padding(22)
    }

    private var itemPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Источник")
                    .font(.headline)
                Spacer()
                Button { model.chooseSource() } label: {
                    Label("Источник", systemImage: "arrow.down.doc")
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(model.sourceLocation?.path ?? "Источник ещё не выбран")
                    .font(.caption)
                    .foregroundStyle(model.sourceLocation == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if model.items.isEmpty {
                emptyState(
                    model.sourceLocation == nil ? "Сначала выберите диск или папку" : "В источнике нет подходящих папок",
                    icon: model.sourceLocation == nil ? "arrow.down.doc" : "shippingbox"
                )
            } else {
                List(model.items, selection: $model.selectedItem) { item in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable()
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).lineLimit(1)
                            Text("\(item.kind) • \(item.sizeLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .tag(item)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var destinationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Куда переносим")
                    .font(.headline)
                Spacer()
                Button { model.chooseDestination() } label: {
                    Label("Выбрать папку", systemImage: "externaldrive.badge.plus")
                }
            }
            if model.volumes.isEmpty {
                emptyState("Подключите внешний диск", icon: "externaldrive")
            } else {
                List(model.volumes, selection: $model.selectedVolume) { volume in
                    HStack(spacing: 12) {
                        Image(systemName: volume.url.path.hasPrefix("/Volumes") ? "externaldrive.fill" : "internaldrive.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(volume.name).lineLimit(1)
                            Text("Свободно: \(volume.availableLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .tag(volume)
                }
                .listStyle(.inset)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("Исходный путь сохраняется", systemImage: "link")
                    .font(.subheadline.weight(.medium))
                Text("После проверки на старом месте останется символическая ссылка. Диск должен быть подключён для запуска приложения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if model.isBusy {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }
            HStack {
                Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.requestTransfer()
                } label: {
                    Label("Перенести выбранное", systemImage: "arrow.right.circle.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selectedItem == nil || model.selectedVolume == nil || model.isBusy)
                .controlSize(.large)
            }
        }
        .padding(18)
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
