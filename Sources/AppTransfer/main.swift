import AppKit
import SwiftUI

@main
struct AppTransferApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1060, minHeight: 560)
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

    var usageRatio: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(total - available) / Double(total), 0), 1)
    }
}

struct CleanupItem: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let bundleIdentifier: String?
    let url: URL
    let kind: String
    let size: Int64
    let isOrphaned: Bool

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct InstalledApp: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let size: Int64
    let isProtected: Bool

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [TransferItem] = []
    @Published var volumes: [TransferVolume] = []
    @Published var diskVolumes: [TransferVolume] = []
    @Published var sourceLocation: URL?
    @Published var selectedItem: TransferItem?
    @Published var selectedVolume: TransferVolume?
    @Published var isBusy = false
    @Published var status = "Выберите приложение или папку для переноса"
    @Published var progress = 0.0
    @Published var showConfirmation = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var cleanupItems: [CleanupItem] = []
    @Published var selectedCleanupItems = Set<CleanupItem.ID>()
    @Published var isCleaning = false
    @Published var showCleanupConfirmation = false
    @Published var cleanupStatus = "Нажмите «Сканировать», чтобы найти кэши и временные файлы"
    @Published var installedApps: [InstalledApp] = []
    @Published var selectedApps = Set<InstalledApp.ID>()
    @Published var isDeletingApps = false
    @Published var showDeleteAppsConfirmation = false
    @Published var deleteAppsStatus = "Выберите приложение для удаления"

    private let fileManager = FileManager.default
    let developerEmail = "ruant02@mail.ru"
    let developerWebsite = "https://kwork.ru/user/ruant02"
    let supportDetails = "5469490014195149"

    init() {
        volumes = scanVolumes()
        diskVolumes = scanDiskVolumes()
        selectedVolume = volumes.first(where: { $0.url.path == "/Volumes/CUSU256DOC" }) ?? volumes.first
        cleanupItems = scanCleanupItems()
        installedApps = scanInstalledApps()
    }

    func refresh() {
        volumes = scanVolumes()
        diskVolumes = scanDiskVolumes()
        selectedVolume = selectedVolume.flatMap { current in
            volumes.first(where: { $0.url == current.url })
        } ?? volumes.first(where: { $0.url.path == "/Volumes/CUSU256DOC" }) ?? volumes.first
        if let sourceLocation {
            items = scanItems(at: sourceLocation)
        }
        cleanupItems = scanCleanupItems()
        selectedCleanupItems = selectedCleanupItems.filter { id in
            cleanupItems.contains { $0.id == id }
        }
        installedApps = scanInstalledApps()
        selectedApps = selectedApps.filter { id in
            installedApps.contains { $0.id == id }
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

    func scanCleanup() {
        guard !isBusy, !isCleaning else { return }
        cleanupItems = scanCleanupItems()
        selectedCleanupItems = []
        let total = cleanupItems.reduce(Int64(0)) { $0 + $1.size }
        cleanupStatus = cleanupItems.isEmpty
            ? "Безопасных к удалению файлов не найдено"
            : "Найдено: \(cleanupItems.count) элементов, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    func requestCleanup() {
        guard !selectedCleanupItems.isEmpty else { return }
        showCleanupConfirmation = true
    }

    func cleanup() {
        let selected = cleanupItems.filter { selectedCleanupItems.contains($0.id) }
        guard !selected.isEmpty else { return }
        showCleanupConfirmation = false
        isCleaning = true
        cleanupStatus = "Удаляю выбранные данные..."

        let model = self
        Task.detached(priority: .userInitiated) {
            var removedCount = 0
            var removedSize: Int64 = 0
            var errors: [String] = []

            for item in selected {
                do {
                    try CleanupService.remove(item)
                    removedCount += 1
                    removedSize += item.size
                } catch {
                    errors.append("\(item.appName): \(error.localizedDescription)")
                }
            }

            let finalRemovedCount = removedCount
            let finalRemovedSize = removedSize
            let finalErrors = errors
            await MainActor.run {
                model.isCleaning = false
                model.cleanupItems = model.scanCleanupItems()
                model.selectedCleanupItems = []
                if finalErrors.isEmpty {
                    model.cleanupStatus = "Удалено: \(finalRemovedCount) элементов, \(ByteCountFormatter.string(fromByteCount: finalRemovedSize, countStyle: .file))"
                } else {
                    model.cleanupStatus = "Удалено: \(finalRemovedCount), ошибок: \(finalErrors.count)"
                    model.errorMessage = finalErrors.joined(separator: "\n")
                    model.showError = true
                }
            }
        }
    }

    func scanApps() {
        guard !isBusy, !isCleaning, !isDeletingApps else { return }
        installedApps = scanInstalledApps()
        selectedApps = []
        deleteAppsStatus = installedApps.isEmpty
            ? "Установленные приложения не найдены"
            : "Найдено приложений: \(installedApps.count)"
    }

    func requestDeleteApps() {
        let selected = installedApps.filter { selectedApps.contains($0.id) && !$0.isProtected }
        guard !selected.isEmpty else { return }
        showDeleteAppsConfirmation = true
    }

    func deleteApps() {
        let selected = installedApps.filter { selectedApps.contains($0.id) && !$0.isProtected }
        guard !selected.isEmpty else { return }
        showDeleteAppsConfirmation = false
        isDeletingApps = true
        deleteAppsStatus = "Удаляю выбранные приложения и остатки..."

        let model = self
        Task.detached(priority: .userInitiated) {
            var deletedCount = 0
            var deletedApps: [InstalledApp] = []
            var errors: [String] = []

            for app in selected {
                do {
                    try FileManager.default.removeItem(at: app.url)
                    deletedCount += 1
                    deletedApps.append(app)
                } catch {
                    errors.append("\(app.name): \(error.localizedDescription)")
                }
            }

            let finalDeletedCount = deletedCount
            let finalDeletedApps = deletedApps
            let finalErrors = errors
            await MainActor.run {
                model.isDeletingApps = false
                model.installedApps = model.scanInstalledApps()
                model.selectedApps = []

                var removedLeftovers = 0
                var leftoverErrors: [String] = []
                let cleanupItems = model.scanCleanupItems()
                for app in finalDeletedApps {
                    let leftovers = cleanupItems.filter { CleanupService.matches($0, app: app) }
                    for leftover in leftovers {
                        do {
                            try CleanupService.remove(leftover)
                            removedLeftovers += 1
                        } catch {
                            leftoverErrors.append("\(leftover.appName): \(error.localizedDescription)")
                        }
                    }
                }
                model.cleanupItems = model.scanCleanupItems()

                let allErrors = finalErrors + leftoverErrors
                if allErrors.isEmpty {
                    model.deleteAppsStatus = "Удалено приложений: \(finalDeletedCount), остатков: \(removedLeftovers)"
                } else {
                    model.deleteAppsStatus = "Удалено приложений: \(finalDeletedCount), остатков: \(removedLeftovers), ошибок: \(allErrors.count)"
                    model.errorMessage = allErrors.joined(separator: "\n")
                    model.showError = true
                }
            }
        }
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
        scanDiskVolumes().filter { $0.url.path != "/" }
    }

    private func scanDiskVolumes() -> [TransferVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsLocalKey
        ]
        let locations = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: []
        )?.filter { url in
            url.path == "/" || (
                url.deletingLastPathComponent().path == "/Volumes" &&
                url.path != "/Volumes/Macintosh HD"
            )
        } ?? [URL(fileURLWithPath: "/")]
        var seen = Set<String>()

        return locations.compactMap { url in
            guard !seen.contains(url.path),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal != false,
                  let available = values.volumeAvailableCapacity else { return nil }
            seen.insert(url.path)
            return TransferVolume(
                url: url,
                name: values.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent),
                available: Int64(available),
                total: Int64(values.volumeTotalCapacity ?? 0)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanCleanupItems() -> [CleanupItem] {
        let installedApps = installedApplications()
        let installedIdentifiers = Set(installedApps.compactMap(\.bundleIdentifier))
        let homeLibrary = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var result: [CleanupItem] = []
        var seenPaths = Set<String>()

        func add(_ url: URL, appName: String, bundleIdentifier: String?, kind: String, isOrphaned: Bool) {
            guard fileManager.fileExists(atPath: url.path),
                  !seenPaths.contains(url.path),
                  !isSymbolicLink(url) else { return }
            let size = directorySize(url)
            guard size > 0 else { return }
            seenPaths.insert(url.path)
            result.append(CleanupItem(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                url: url,
                kind: kind,
                size: size,
                isOrphaned: isOrphaned
            ))
        }

        let cachesDirectory = homeLibrary.appendingPathComponent("Caches")
        for url in directoryEntries(at: cachesDirectory) where url.hasDirectoryPath {
            let identifier = url.lastPathComponent
            let app = installedApps.first { $0.bundleIdentifier == identifier }
            add(
                url,
                appName: app?.name ?? readableAppName(identifier),
                bundleIdentifier: app?.bundleIdentifier ?? identifier,
                kind: app == nil ? "Кэш удалённого приложения" : "Кэш приложения",
                isOrphaned: !installedIdentifiers.contains(identifier)
            )
        }

        let containersDirectory = homeLibrary.appendingPathComponent("Containers")
        for container in directoryEntries(at: containersDirectory) where container.hasDirectoryPath {
            let identifier = container.lastPathComponent
            let cache = container.appendingPathComponent("Data/Library/Caches")
            let app = installedApps.first { $0.bundleIdentifier == identifier }
            add(
                cache,
                appName: app?.name ?? readableAppName(identifier),
                bundleIdentifier: app?.bundleIdentifier ?? identifier,
                kind: app == nil ? "Кэш удалённого приложения" : "Кэш sandbox-приложения",
                isOrphaned: !installedIdentifiers.contains(identifier)
            )
        }

        let savedStatesDirectory = homeLibrary.appendingPathComponent("Saved Application State")
        for url in directoryEntries(at: savedStatesDirectory) where url.pathExtension == "savedState" {
            let identifier = url.deletingPathExtension().lastPathComponent
            let app = installedApps.first { $0.bundleIdentifier == identifier }
            add(
                url,
                appName: app?.name ?? readableAppName(identifier),
                bundleIdentifier: app?.bundleIdentifier ?? identifier,
                kind: app == nil ? "Состояние удалённого приложения" : "Сохранённое состояние",
                isOrphaned: !installedIdentifiers.contains(identifier)
            )
        }

        let logsDirectory = homeLibrary.appendingPathComponent("Logs")
        for url in directoryEntries(at: logsDirectory) where url.hasDirectoryPath {
            let app = installedApps.first { $0.name.localizedCaseInsensitiveCompare(url.lastPathComponent) == .orderedSame }
            add(
                url,
                appName: app?.name ?? url.lastPathComponent,
                bundleIdentifier: app?.bundleIdentifier,
                kind: "Логи приложения",
                isOrphaned: app == nil
            )
        }

        return result.sorted {
            if $0.isOrphaned != $1.isOrphaned { return $0.isOrphaned }
            if $0.appName != $1.appName {
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
            return $0.kind.localizedCaseInsensitiveCompare($1.kind) == .orderedAscending
        }
    }

    private func scanInstalledApps() -> [InstalledApp] {
        installedApplications().compactMap { app in
            guard let values = try? app.url.resourceValues(forKeys: [.isDirectoryKey]) else { return nil }
            guard values.isDirectory == true else { return nil }
            return InstalledApp(
                url: app.url,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                size: directorySize(app.url),
                isProtected: app.url.path.hasPrefix("/System/Applications")
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func installedApplications() -> [(url: URL, name: String, bundleIdentifier: String?)] {
        let locations = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications")
        ]
        var result: [(url: URL, name: String, bundleIdentifier: String?)] = []
        var seen = Set<String>()
        for location in locations {
            for url in directoryEntries(at: location) where url.pathExtension == "app" {
                guard !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                result.append((
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: Bundle(url: url)?.bundleIdentifier
                ))
            }
        }
        return result
    }

    private func directoryEntries(at url: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }

    private func readableAppName(_ identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
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

enum CleanupService {
    static func matches(_ item: CleanupItem, app: InstalledApp) -> Bool {
        if let itemIdentifier = item.bundleIdentifier,
           let appIdentifier = app.bundleIdentifier,
           itemIdentifier == appIdentifier {
            return true
        }
        return item.appName.localizedCaseInsensitiveCompare(app.name) == .orderedSame
    }

    static func remove(_ item: CleanupItem) throws {
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").standardizedFileURL.path
        let path = item.url.standardizedFileURL.path
        let allowedRoots = [
            "\(homeLibrary)/Caches/",
            "\(homeLibrary)/Containers/",
            "\(homeLibrary)/Saved Application State/",
            "\(homeLibrary)/Logs/"
        ]
        guard allowedRoots.contains(where: { path.hasPrefix($0) }) else {
            throw NSError(domain: "AppTransferCleanup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Путь не относится к разрешённым данным приложения."
            ])
        }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return }
        try FileManager.default.removeItem(at: item.url)
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
    @State private var selectedSection = AppSection.transfer

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker(selection: $selectedSection) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Навигация")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if selectedSection == .transfer {
                HStack(spacing: 0) {
                    itemPanel
                    Divider()
                    destinationPanel
                }
            } else if selectedSection == .cleanup {
                cleanupPanel
            } else if selectedSection == .deleteApps {
                deleteAppsPanel
            } else {
                aboutPanel
            }
            Divider()
            if selectedSection == .transfer {
                footer
            } else if selectedSection == .cleanup {
                cleanupFooter
            } else if selectedSection == .deleteApps {
                deleteAppsFooter
            } else {
                EmptyView()
            }
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
        .alert("Удалить выбранные данные?", isPresented: $model.showCleanupConfirmation) {
            Button("Удалить", role: .destructive) { model.cleanup() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут удалены только выбранные кэши, логи и сохранённые состояния. Документы, настройки и данные приложений не затрагиваются.")
        }
        .alert("Удалить приложения безвозвратно?", isPresented: $model.showDeleteAppsConfirmation) {
            Button("Удалить безвозвратно", role: .destructive) { model.deleteApps() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Приложения нельзя будет восстановить из Корзины. Связанные кэши, логи и сохранённые состояния будут удалены автоматически.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
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
            diskSpaceSummary
                .layoutPriority(1)
        }
        .padding(22)
    }

    private var diskSpaceSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(Color.accentColor)
                Text("Диски")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            if model.diskVolumes.isEmpty {
                Text("Нет подключённых дисков")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.diskVolumes.prefix(3)) { volume in
                    HStack(spacing: 6) {
                        Text(volume.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 78, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.18))
                                Capsule()
                                    .fill(volume.usageRatio > 0.9 ? Color.orange : Color.accentColor)
                                    .frame(width: proxy.size.width * volume.usageRatio)
                            }
                        }
                        .frame(height: 6)
                        Text(volume.availableLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            }
        }
        .frame(width: 285, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .help("Свободное место на подключённых дисках")
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

    private var cleanupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Кэши и временные файлы")
                        .font(.headline)
                    Text("Выберите данные, которые можно удалить")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.scanCleanup() } label: {
                    Label("Сканировать", systemImage: "magnifyingglass")
                }
                .disabled(model.isBusy || model.isCleaning)
            }

            if model.cleanupItems.isEmpty {
                emptyState("Нажмите «Сканировать», чтобы проверить данные", icon: "sparkle.magnifyingglass")
            } else {
                List(model.cleanupItems, selection: $model.selectedCleanupItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isOrphaned ? "trash" : "shippingbox")
                            .font(.title3)
                            .foregroundStyle(item.isOrphaned ? Color.orange : Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.appName).lineLimit(1)
                                if item.isOrphaned {
                                    Text("Остаток")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text("\(item.kind) • \(item.sizeLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.url.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .tag(item.id)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var cleanupFooter: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: model.isCleaning ? "arrow.triangle.2.circlepath" : "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.cleanupStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.requestCleanup()
                } label: {
                    Label("Удалить выбранное", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedCleanupItems.isEmpty || model.isBusy || model.isCleaning)
                .controlSize(.large)
            }
        }
        .padding(18)
    }

    private var deleteAppsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Удаление приложений")
                        .font(.headline)
                    Text("Приложения и найденные остатки будут удалены безвозвратно")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.scanApps() } label: {
                    Label("Сканировать", systemImage: "magnifyingglass")
                }
                .disabled(model.isBusy || model.isCleaning || model.isDeletingApps)
            }

            if model.installedApps.isEmpty {
                emptyState("Нажмите «Сканировать», чтобы найти приложения", icon: "square.stack.3d.up")
            } else {
                List(model.installedApps, selection: $model.selectedApps) { app in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).lineLimit(1)
                            Text("\(app.sizeLabel) • \(app.url.deletingLastPathComponent().path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if app.isProtected {
                            Text("Системное")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(app.id)
                    .opacity(app.isProtected ? 0.6 : 1)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var deleteAppsFooter: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: model.isDeletingApps ? "arrow.triangle.2.circlepath" : "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.deleteAppsStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.requestDeleteApps()
                } label: {
                    Label("Удалить выбранное", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedApps.isEmpty || model.isBusy || model.isCleaning || model.isDeletingApps)
                .controlSize(.large)
            }
        }
        .padding(18)
    }

    private var aboutPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("App Transfer")
                            .font(.title.weight(.semibold))
                        Text("Перенос, очистка и удаление приложений на macOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("О приложении")
                    .font(.title3.weight(.semibold))
                Text("App Transfer помогает управлять приложениями и их данными: переносить приложения на другой диск с сохранением исходного пути, очищать кэши и временные файлы, а также полностью удалять приложения вместе с найденными остатками.")
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Разработчик")
                        .font(.headline)
                    aboutRow(title: "Имя", value: "Rusakoff")
                    aboutRow(title: "Почта", value: model.developerEmail)
                    HStack {
                        Text("Сайт")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link("Kwork", destination: URL(string: model.developerWebsite)!)
                    }
                }
                .padding(16)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Помочь разработчику")
                        .font(.headline)
                    Text("Поддержать разработку можно переводом по реквизитам:")
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(model.supportDetails)
                            .font(.body.monospacedDigit())
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.supportDetails, forType: .string)
                        } label: {
                            Label("Копировать", systemImage: "doc.on.doc")
                        }
                    }
                }
                .padding(16)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
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

enum AppSection: String, CaseIterable, Identifiable {
    case transfer
    case cleanup
    case deleteApps
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transfer: return "Перенос"
        case .cleanup: return "Очистка"
        case .deleteApps: return "Удаление приложений"
        case .about: return "О приложении"
        }
    }

    var icon: String {
        switch self {
        case .transfer: return "arrow.right.circle"
        case .cleanup: return "trash"
        case .deleteApps: return "app.dashed"
        case .about: return "info.circle"
        }
    }
}
