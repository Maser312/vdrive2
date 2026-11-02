import SwiftUI
import CoreMotion
import UIKit
import PhotosUI
import Photos
import MetalFxKit
import LocalAuthentication
import AuthenticationServices
import AVKit
import UniformTypeIdentifiers
import ImageIO
import CoreTransferable
import QuickLook
import CryptoKit
import Security


/// Диагностический журнал VDrive. Содержимое файлов, OAuth-токены и ключи сюда не записываются.
private final class VDriveDiagnosticLog {
    static let shared = VDriveDiagnosticLog()
    private let queue = DispatchQueue(label: "app.vdrive.diagnostics", qos: .utility)
    private let enabledKey = "vdrive.diagnostics.enabled"
    private let filename = "VDrive-Diagnostics.log"
    private init() {}
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
        write("LOG", value ? "Журнал включён" : "Журнал выключен")
    }
    private var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }
    func write(_ category: String, _ message: String) {
        guard isEnabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(category)] \(message)\n"
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: self.logURL.path) {
                    let handle = try FileHandle(forWritingTo: self.logURL)
                    try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
                } else { try data.write(to: self.logURL, options: .completeFileProtection) }
            } catch { }
        }
    }
    func export() throws -> URL {
        queue.sync {}
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try Data("Журнал пока пуст. Включите запись и повторите проблемное действие.".utf8).write(to: logURL, options: .atomic)
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("VDrive-Diagnostics-\(Int(Date().timeIntervalSince1970)).log")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: logURL, to: destination)
        return destination
    }
}

private struct PickerFileTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let ext = received.file.pathExtension
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("VDrive-picker-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: temporary)
            return PickerFileTransfer(url: temporary)
        }
    }
}

private struct VaultFile: Identifiable, Hashable {
    let id: String
    let url: URL
    var isLocal: Bool { FileManager.default.fileExists(atPath: url.path) }
    var uploaded: Bool { GoogleDriveStore.shared.fileIDs[id] != nil }
    var displayName: String {
        let raw = (id as NSString).deletingPathExtension
        let parts = raw.components(separatedBy: "__")
        if parts.count > 3, parts[1].hasPrefix("A"), parts[2].hasPrefix("C") {
            return parts.dropFirst(3).joined(separator: "__")
        }
        return parts.count > 1 ? parts.dropFirst().joined(separator: "__") : raw
    }

    var addedDate: Date {
        let parts = id.components(separatedBy: "__")
        if parts.count > 3, parts[1].hasPrefix("A"),
           let timestamp = Double(parts[1].dropFirst()) {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    var captureDate: Date? {
        let parts = id.components(separatedBy: "__")
        guard parts.count > 3, parts[2].hasPrefix("C"),
              let timestamp = Double(parts[2].dropFirst()), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

private struct FileProperties: Identifiable {
    let id = UUID()
    let title: String
    let details: String
}

private enum MediaExportAction: String {
    case share, photos, files
}

private enum VaultSortOrder: String, CaseIterable, Identifiable {
    case addedNewest
    case captureNewest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .addedNewest: return "По дате добавления"
        case .captureNewest: return "По дате съёмки / создания"
        }
    }
}

private final class FlipPrivacyMotion: ObservableObject {
    @Published var faceDown = false
    private let manager = CMMotionManager()
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.15
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let z = motion.gravity.z
            if z > 0.78 { if !self.faceDown { self.faceDown = true } }
            else if z < -0.65 { if self.faceDown { self.faceDown = false } }
        }
    }
    func stop() { manager.stopDeviceMotionUpdates() }
}

private actor ThumbnailCryptoQueue {
    static let shared = ThumbnailCryptoQueue()

    // Actor isolation serializes thumbnail decryption so opening a large vault
    // doesn't start a burst of concurrent crypto work.
    func decrypt(_ encrypted: Data, key: SymmetricKey) throws -> Data {
        try VDriveCrypto.open(encrypted, key: key)
    }
}

private struct VaultThumbnail: View {
    let file: VaultFile
    @State private var image: UIImage?
    @State private var loadFailed = false

    private var isVideo: Bool {
        let ext = (file.displayName as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "avi", "mkv"].contains(ext)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else if isVideo {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: loadFailed ? "photo" : "lock.fill")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        // Load each visible lazy-grid cell once. Privacy blur is a visual
        // overlay only; toggling it must not restart thumbnail decryption.
        .task(id: file.id) {
            await loadThumbnail()
        }
    }

    @MainActor private func loadThumbnail() async {
        guard image == nil else { return }
        let cacheURL = Self.localThumbnailURL(for: file.id)

        // Cached previews are encrypted at rest. Only decrypt the tiny JPEG, off the main thread.
        if let cachedPreview = try? Data(contentsOf: cacheURL, options: [.mappedIfSafe]) {
            if let cachedImage = UIImage(data: cachedPreview) {
                image = cachedImage
                return
            }
            if let keyData = VDriveCrypto.existingLocalKeyData() {
                do {
                    let key = SymmetricKey(data: keyData)
                    let jpeg = try await Task.detached(priority: .utility) {
                        try await ThumbnailCryptoQueue.shared.decrypt(cachedPreview, key: key)
                    }.value
                    image = UIImage(data: jpeg)
                    if image != nil { return }
                } catch { }
            }
        }

        if file.isLocal {
            // Build a small preview directly from the local file URL. ImageIO and
            // AVAsset decode only a thumbnail/frame, not the full-resolution media.
            let url = file.url
            let name = file.displayName
            let jpeg = await Task.detached(priority: .utility) { () -> Data? in
                if let direct = Self.makeJPEGThumbnail(fromFileURL: url, filename: name) { return direct }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 256 * 1024 * 1024,
                      let stored = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                      let keyData = VDriveCrypto.existingLocalKeyData(),
                      let legacy = try? VDriveCrypto.open(stored, key: SymmetricKey(data: keyData)) else { return nil }
                return Self.makeJPEGThumbnail(from: legacy, filename: name)
            }.value
            if let jpeg {
                try? await Task.detached(priority: .utility) {
                    try Self.saveLocalThumbnail(jpeg, for: file.id)
                }.value
                image = UIImage(data: jpeg)
            }
            loadFailed = image == nil
            return
        }

        do {
            image = try await loadRemoteThumbnailOrMigrate()
            loadFailed = image == nil
        } catch {
            loadFailed = true
        }
    }

    @MainActor private func loadRemoteThumbnailOrMigrate() async throws -> UIImage? {
        let key = try VDriveCrypto.localKey()
        // Prefer the new full-bleed square preview. Fall back to legacy for cloud-only items.
        let currentPreview = try await GoogleDriveStore.shared.downloadThumbnail(named: file.id + ".vthumb2")
        let encryptedPreview: Data?
        if let currentPreview {
            encryptedPreview = currentPreview
        } else {
            encryptedPreview = try await GoogleDriveStore.shared.downloadThumbnail(named: file.id + ".vthumb")
        }
        guard let encryptedPreview else { return nil }
        let jpeg = try await Task.detached(priority: .utility) {
            try await ThumbnailCryptoQueue.shared.decrypt(encryptedPreview, key: key)
        }.value
        try? Self.saveLocalThumbnail(jpeg, for: file.id)
        return UIImage(data: jpeg)
    }

    nonisolated static func thumbnailDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VDriveThumbnails", isDirectory: true)
    }

    nonisolated static func localThumbnailURL(for fileID: String) -> URL {
        // v2 invalidates old aspect-fit previews and forces regeneration from the original.
        thumbnailDirectory().appendingPathComponent(fileID.replacingOccurrences(of: "/", with: "_") + ".vthumb2")
    }

    nonisolated static func legacyLocalThumbnailURL(for fileID: String) -> URL {
        thumbnailDirectory().appendingPathComponent(fileID.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    nonisolated static func saveLocalThumbnail(_ jpeg: Data, for fileID: String) throws {
        let directory = thumbnailDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directory
        try? mutableURL.setResourceValues(values)
        try jpeg.write(to: localThumbnailURL(for: fileID), options: [.atomic, .completeFileProtection])
    }

    nonisolated static func saveEncryptedThumbnail(_ encrypted: Data, for fileID: String) throws {
        let directory = thumbnailDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directory
        try? mutableURL.setResourceValues(values)
        try encrypted.write(to: localThumbnailURL(for: fileID), options: [.atomic, .completeFileProtection])
    }

    nonisolated static func removeLocalThumbnail(for fileID: String) {
        try? FileManager.default.removeItem(at: localThumbnailURL(for: fileID))
        try? FileManager.default.removeItem(at: thumbnailDirectory().appendingPathComponent(fileID.replacingOccurrences(of: "/", with: "_") + ".vthumb"))
        try? FileManager.default.removeItem(at: legacyLocalThumbnailURL(for: fileID))
    }

    nonisolated static func makeJPEGThumbnail(from data: Data, filename: String) -> Data? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let videoExtensions = ["mov", "mp4", "m4v", "avi", "mkv"]
        let mediaImage: UIImage?
        if videoExtensions.contains(ext) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("VDrive-thumb-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: temp, options: [.atomic, .completeFileProtection])
                defer { try? FileManager.default.removeItem(at: temp) }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: temp))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 320)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
                let frame = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
                mediaImage = UIImage(cgImage: frame)
            } catch {
                return nil
            }
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            mediaImage = UIImage(cgImage: thumbnail)
        }
        guard let mediaImage, mediaImage.size.width > 0, mediaImage.size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320))
        return renderer.jpegData(withCompressionQuality: 0.58) { _ in
            let scale = max(320 / mediaImage.size.width, 320 / mediaImage.size.height)
            let size = CGSize(width: mediaImage.size.width * scale, height: mediaImage.size.height * scale)
            mediaImage.draw(in: CGRect(x: (320 - size.width) / 2, y: (320 - size.height) / 2, width: size.width, height: size.height))
        }
    }

    nonisolated static func makeJPEGThumbnail(fromFileURL url: URL, filename: String) -> Data? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let videoExtensions = ["mov", "mp4", "m4v", "avi", "mkv", "3gp"]
        let mediaImage: UIImage?
        if videoExtensions.contains(ext) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            do {
                let frame = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
                mediaImage = UIImage(cgImage: frame)
            } catch { return nil }
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            mediaImage = UIImage(cgImage: thumbnail)
        }
        guard let mediaImage, mediaImage.size.width > 0, mediaImage.size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320))
        return renderer.jpegData(withCompressionQuality: 0.58) { _ in
            let scale = max(320 / mediaImage.size.width, 320 / mediaImage.size.height)
            let size = CGSize(width: mediaImage.size.width * scale, height: mediaImage.size.height * scale)
            mediaImage.draw(in: CGRect(x: (320 - size.width) / 2, y: (320 - size.height) / 2, width: size.width, height: size.height))
        }
    }


}

struct VDriveHomeView: View {
    @State private var selection: [PhotosPickerItem] = []
    @State private var pendingPhotoAssetIDs: [String] = []
    @State private var showDeleteOriginalPhotosAlert = false
    @State private var pendingCloudSync = false
    @State private var showingFileImporter = false
    @State private var authenticatorSecretInput = UserDefaults.standard.string(forKey: "vdrive.authenticator.secret") ?? ""
    @State private var showAuthenticatorSecretEntry = false
    @State private var authenticatorSecretDraft = ""
    @State private var files: [VaultFile] = []
    @State private var sortOrder: VaultSortOrder = VaultSortOrder(rawValue: UserDefaults.standard.string(forKey: "vdrive.sortOrder") ?? "") ?? .addedNewest
    @State private var selectedFileIDs: Set<String> = []
    @State private var selectionMode = false
    @State private var showBulkDeleteConfirmation = false
    @State private var bulkDeleteMode = "local"
    @State private var message = "Личное хранилище"
    @State private var busy = false
    @State private var transferProgress = 0
    @State private var transferTotal = 0
    @State private var transferLabel = ""
    @State private var transferBytes: Int64 = 0
    @State private var transferExpectedBytes: Int64 = 0
    @State private var transferSpeedBytesPerSecond: Double = 0
    @State private var autoConnectAttempted = false
    @State private var locked = true
    @State private var showingAuthenticator = true
    @State private var localStorageBytes: Int64 = 0
    @State private var cloudStorageBytes: Int64 = 0
    @State private var pin = ""
    @State private var setupPIN = ""
    @State private var pinEntry = ""
    @State private var pinSetupMode = false
    @State private var showSettings = false
    @State private var clientIDInput = UserDefaults.standard.string(forKey: "googleClientID") ?? "15564278108-3npmd22j8obehjl19rpbpeeldlg2bn3k.apps.googleusercontent.com"
    @State private var showClientID = false
    @State private var selectedFile: VaultFile?
    @StateObject private var flipMotion = FlipPrivacyMotion()
    @State private var thumbnailsBlurred = true
    @State private var sawFaceDown = false
    @State private var pendingExportAction: MediaExportAction?
    @State private var showExportConfirmation = false
    @State private var exportToFiles = false
    @State private var previewURLs: [URL] = []
    @State private var previewIndex = 0
    @State private var previewPresentation: PreviewPresentation?
    @State private var shareURL: URL?
    @State private var showingShareSheet = false
    @State private var recoveryCode = ""
    @State private var showRecoveryCodeAlert = false
    @State private var recoveryCodeInput = ""
    @State private var cloudRecoveryRecord: Data?
    @State private var showCloudRecoveryPrompt = false
    @State private var showPINAlert = false
    @State private var isConnected = GoogleDriveStore.shared.hasRefreshToken
    @State private var diagnosticLoggingEnabled = UserDefaults.standard.bool(forKey: "vdrive.diagnostics.enabled")
    @State private var cloudVaultUnlocked = false
    @State private var showGoogleSetupInfo = false
    @State private var fileProperties: FileProperties?
    @Environment(\.scenePhase) private var scenePhase

    private let pinKey = "vdrive.pin"

    var body: some View {
        mainContent
            .task {
                refreshFiles()
                await migrateLegacyLocalFiles()
                refreshFiles()
            }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
            if newPhase == .active { flipMotion.start() } else { flipMotion.stop() }
        }
        .onChange(of: flipMotion.faceDown) { _, faceDown in
            if faceDown { sawFaceDown = true }
            else if sawFaceDown { thumbnailsBlurred.toggle(); sawFaceDown = false }
        }
        .onAppear { flipMotion.start() }
        .onDisappear { flipMotion.stop() }
        .onChange(of: selection) { _, items in Task { await importItems(items) } }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showingFileImporter) {
            FileImportPicker { result in
                showingFileImporter = false
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { message = "Файлы не выбраны."; return }
                    Task { await importFilesFromPicker(urls) }
                case .failure(let error):
                    message = "Ошибка выбора файлов: \(error.localizedDescription)"
                }
            }
            .ignoresSafeArea()
        }
        .alert("Удалить оригиналы из Фото?", isPresented: $showDeleteOriginalPhotosAlert) {
            Button("Удалить оригиналы", role: .destructive) { deleteImportedPhotoOriginals() }
            Button("Оставить в Фото", role: .cancel) { finishLocalImportAndSync() }
        } message: {
            Text("Копии сохранены в VDrive на устройстве. При синхронизации в Google Drive они шифруются. Можно удалить исходные фото и видео из медиатеки Apple Фото; они попадут в «Недавно удалённые».")
        }
        .alert("Секретный ключ Authenticator", isPresented: $showAuthenticatorSecretEntry) {
            TextField("Base32 secret key", text: $authenticatorSecretDraft)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Сохранить") {
                let value = authenticatorSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                authenticatorSecretInput = value
                UserDefaults.standard.set(value, forKey: "vdrive.authenticator.secret")
                message = value.isEmpty ? "Секретный ключ удалён." : "Секретный ключ сохранён на устройстве."
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сохраняется локально на этом устройстве. Не вводи сюда пароль аккаунта или резервные коды.")
        }
        .fullScreenCover(item: $previewPresentation, onDismiss: cleanPreview) { presentation in
            VaultFullscreenViewer(items: presentation.items, initialIndex: presentation.initialIndex)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $fileProperties) { properties in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Метаданные файла", systemImage: "info.circle")
                            .font(.headline)
                        Text(properties.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Divider()
                        Text(properties.details)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
                .navigationTitle("Свойства")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { fileProperties = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: cleanShareFile) {
            if let shareURL {
                if exportToFiles {
                    FileExportPicker(url: shareURL, isPresented: $showingShareSheet)
                } else {
                    ActivityShareSheet(items: [shareURL])
                }
            }
        }
        .alert("Экспорт расшифрованного файла", isPresented: $showExportConfirmation) {
            Button("Продолжить", role: .destructive) { performPendingExport() }
            Button("Отмена", role: .cancel) { pendingExportAction = nil }
        } message: {
            Text("Файл будет временно расшифрован. После подтверждения его можно сохранить вне VDrive или передать другому приложению. Продолжить?")
        }
        .alert("Секретный ключ VDrive", isPresented: $showRecoveryCodeAlert) {
            Button("Скопировать и продолжить") {
                UIPasteboard.general.string = recoveryCode
                cloudVaultUnlocked = true
                Task {
                    await refreshCloudInventory()
                    refreshFiles()
                    message = "Хранилище готово. Выгружай файлы вручную, когда закончишь добавлять их локально."
                }
            }
            Button("Закрыть", role: .cancel) {
                cloudVaultUnlocked = true
                Task { await refreshCloudInventory(); refreshFiles() }
            }
        } message: {
            Text("Это дополнительный старый код восстановления. Основной ключ шифрования можно скопировать в настройках; Google хранит его копию для автоматического восстановления.")
        }
        .alert("Восстановление VDrive", isPresented: $showCloudRecoveryPrompt) {
            SecureField("Секретный ключ", text: $recoveryCodeInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Разблокировать облако") { Task { await restoreCloudVault() } }
            Button("Отмена", role: .cancel) {
                cloudRecoveryRecord = nil
                message = "Google подключён. Облачное хранилище скрыто до ввода секретного ключа."
            }
        } message: {
            Text("В Google Drive найдено хранилище VDrive. Введи свой секретный ключ. Пока ключ не проверен, список файлов не загружается и не отображается.")
        }
        .alert("Google Drive", isPresented: $showGoogleSetupInfo) {
            Button("Настроить Client ID") { showClientID = true }
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text("Для подключения нужен OAuth Client ID типа iOS из Google Cloud Console. Включите Google Drive API и настройте OAuth consent screen.")
        }
        .alert("Google OAuth Client ID", isPresented: $showClientID) {
            TextField("…apps.googleusercontent.com", text: $clientIDInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Сохранить") {
                UserDefaults.standard.set(clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "googleClientID")
                message = "Client ID сохранён. Подключите Google Drive."
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Вставьте Client ID типа iOS из Google Cloud Console. Секрет клиента не нужен.")
        }

    }

    @ViewBuilder
    private var mainContent: some View {
        if showingAuthenticator {
            authenticatorStub
        } else if locked {
            lockScreen
        } else {
            vaultScreen
        }
    }

    private var authenticatorStub: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 24, weight: .medium)).foregroundStyle(.primary)
                    Text("Authenticator").font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "ellipsis").font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 42, height: 42)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.horizontal, 20).padding(.top, 12)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ваши коды").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.primary)
                    Text("Одноразовые коды подтверждения").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 18)
                GlassEffectContainer(spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 10) {
                            authenticatorRow(title: "Google", code: demoCode(seed: 1, date: context.date), symbol: "g.circle.fill", seconds: 30 - Int(context.date.timeIntervalSince1970) % 30, service: "Google")
                            authenticatorRow(title: "Microsoft", code: demoCode(seed: 2, date: context.date), symbol: "m.circle.fill", seconds: 30 - Int(context.date.timeIntervalSince1970) % 30, service: "Microsoft")
                            authenticatorRow(title: "Telegram", code: demoCode(seed: 3, date: context.date), symbol: "paperplane.fill", seconds: 30 - Int(context.date.timeIntervalSince1970) % 30, service: "Telegram")
                            authenticatorRow(title: "ВКонтакте", code: demoCode(seed: 4, date: context.date), symbol: "v.circle.fill", seconds: 30 - Int(context.date.timeIntervalSince1970) % 30, service: "ВКонтакте")
                            authenticatorRow(title: "Яндекс", code: demoCode(seed: 5, date: context.date), symbol: "y.circle.fill", seconds: 30 - Int(context.date.timeIntervalSince1970) % 30, service: "Яндекс")
                        }
                    }
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 12)
            }
        }
    }

    private func demoCode(seed: Int, date: Date) -> String {
        let step = Int(date.timeIntervalSince1970) / 30
        let value = abs((step &* 1103515245 &+ seed &* 12345) ^ (seed &* 7919)) % 1_000_000
        return String(format: "%06d", value)
    }

    private func authenticatorRow(title: String, code: String, symbol: String, seconds: Int, service: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 23))
                .foregroundStyle(Color(red: 0.28, green: 0.43, blue: 0.72))
                .frame(width: 44, height: 44)
                .background(Color(red: 0.89, green: 0.92, blue: 0.98), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(code).font(.system(size: 22, weight: .semibold, design: .monospaced)).tracking(2)
            }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(.secondary.opacity(0.16), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(seconds) / 30)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.35), value: seconds)
            }.frame(width: 28, height: 28)
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    if service == "Telegram" {
                        // Telegram is a navigation trigger on this placeholder, not a real OTP.
                        // Never put its demo code on the clipboard.
                        showingAuthenticator = false
                        if UserDefaults.standard.string(forKey: pinKey) == nil {
                            pinSetupMode = true
                            message = "Задайте PIN при первом запуске"
                        }
                    } else {
                        UIPasteboard.general.string = code
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38).glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("Скопировать демонстрационный код \(service)")
        }
        .foregroundStyle(.primary)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .background else { return }
        locked = true
        showingAuthenticator = true
        pinEntry = ""
        if previewPresentation != nil {
            previewPresentation = nil
            cleanPreview()
        }
    }

    private var lockScreen: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.10, blue: 0.18), Color(red: 0.12, green: 0.17, blue: 0.29), Color(red: 0.06, green: 0.09, blue: 0.16)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()
            Circle()
                .fill(Color.blue.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: 130, y: -250)
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    Circle().fill(.white.opacity(0.07)).frame(width: 118, height: 118)
                    Circle().stroke(.white.opacity(0.15), lineWidth: 1).frame(width: 118, height: 118)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 39, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 28)
                Text("Authentication")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(pinSetupMode ? "Создайте код доступа" : "Защищённый доступ")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.top, 9)
                    .padding(.bottom, 30)
                SecureField("Введите PIN-код", text: $pinEntry)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .tracking(5)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 58)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                    .padding(.horizontal, 28)
                Button {
                    if pinSetupMode {
                        guard pinEntry.count >= 4 else { message = "PIN должен содержать минимум 4 цифры"; return }
                        UserDefaults.standard.set(pinDigest(pinEntry), forKey: pinKey)
                        pinEntry = ""; pinSetupMode = false; locked = false; showingAuthenticator = false; Task { await autoConnectGoogleIfNeeded() }
                    } else if let saved = UserDefaults.standard.string(forKey: pinKey) {
                        if saved == pinDigest(pinEntry) { pinEntry = ""; locked = false; showingAuthenticator = false; Task { await autoConnectGoogleIfNeeded(); await refreshCloudInventory() } }
                        else { message = "Неверный PIN-код" }
                    } else {
                        pinSetupMode = true
                        message = "Придумайте PIN минимум из 4 цифр"
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(pinSetupMode ? "Создать PIN" : "Разблокировать")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.20))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.top, 14)
                if !pinSetupMode {
                    Button { authenticateFaceID() } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "faceid").font(.system(size: 21, weight: .medium))
                            Text("Войти с Face ID").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(message == "Неверный PIN-код" ? Color.red.opacity(0.95) : .white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Облачные копии шифруются; локальные файлы защищены iOS")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            if UserDefaults.standard.string(forKey: pinKey) == nil {
                pinSetupMode = true
                message = "Задайте PIN при первом запуске"
            } else {
                pinSetupMode = false
            }
        }
    }
    private var vaultScreen: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // The gallery scrolls behind the floating glass panels, so the glass can
                // refract real content instead of sitting over a flat opaque background.
                ScrollView {
                    VStack(spacing: 10) {
                        Color.clear.frame(height: 124)

                        if busy {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(transferLabel.isEmpty ? "Обработка медиа…" : transferLabel)
                                        .font(.footnote.weight(.medium))
                                        .lineLimit(2)
                                    Spacer(minLength: 4)
                                    if transferExpectedBytes > 0 {
                                        Text("\(ByteCountFormatter.string(fromByteCount: transferBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: transferExpectedBytes, countStyle: .file))")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    } else if transferTotal > 0 {
                                        Text("\(transferProgress)/\(transferTotal)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if transferExpectedBytes > 0 {
                                    ProgressView(value: Double(min(transferBytes, transferExpectedBytes)), total: Double(transferExpectedBytes)).tint(.primary)
                                    HStack {
                                        Text("\(Int(Double(transferBytes) / Double(max(transferExpectedBytes, 1)) * 100))%")
                                        Spacer()
                                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(transferSpeedBytesPerSecond), countStyle: .file))/с")
                                    }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                } else if transferTotal > 0 {
                                    ProgressView(value: Double(min(transferProgress, transferTotal)), total: Double(transferTotal)).tint(.primary)
                                } else { ProgressView() }
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }

                        if files.isEmpty {
                            ContentUnavailableView(
                                "Хранилище пусто",
                                systemImage: "lock.doc",
                                description: Text("Добавьте фото или видео. На iPhone они хранятся открытыми для быстрого просмотра, в Google Drive — зашифрованными.")
                            )
                            .padding(.top, 24)
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 4),
                                    GridItem(.flexible(), spacing: 4),
                                    GridItem(.flexible(), spacing: 4)
                                ],
                                spacing: 4
                            ) {
                                ForEach(sortedFiles) { file in
                                    ZStack {
                                        VaultThumbnail(file: file)
                                            .blur(radius: thumbnailsBlurred ? 18 : 0)
                                            .frame(maxWidth: .infinity)
                                             .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: file.isLocal ? (file.uploaded ? "checkmark.icloud.fill" : "iphone") : "icloud.fill")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(5)
                                                    .background(file.uploaded ? Color.green.opacity(0.82) : Color.black.opacity(0.62), in: Circle())
                                                    .padding(5)
                                            }
                                            .overlay(alignment: .bottomLeading) {
                                                if ["mov", "mp4", "m4v", "avi", "mkv"].contains((file.displayName as NSString).pathExtension.lowercased()) {
                                                    Image(systemName: "play.fill")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(.white)
                                                        .padding(6)
                                                        .background(.black.opacity(0.65), in: Circle())
                                                        .padding(5)
                                                }
                                            }
                                        if thumbnailsBlurred {
                                            Image(systemName: "eye.slash.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.95))
                                                .padding(10)
                                                .background(.black.opacity(0.5), in: Circle())
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                     .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: selectedFileIDs.contains(file.id))
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .topTrailing) {
                                        if selectionMode {
                                            Image(systemName: selectedFileIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 23, weight: .semibold))
                                                .foregroundStyle(selectedFileIDs.contains(file.id) ? Color.accentColor : Color.white)
                                                .shadow(color: .black.opacity(0.6), radius: 3)
                                                .padding(7)
                                        }
                                    }
                                    .onTapGesture {
                                        if selectionMode {
                                            if selectedFileIDs.contains(file.id) { selectedFileIDs.remove(file.id) }
                                            else { selectedFileIDs.insert(file.id) }
                                        } else if file.isLocal { openPreview(file) }
                                        else { Task { await downloadAndOpen(file) } }
                                    }
                                    .contextMenu {
                                        Button("Свойства", systemImage: "info.circle") {
                                            Task { await showFileProperties(file) }
                                        }
                                        Button(file.isLocal ? "Открыть" : "Скачать и открыть", systemImage: file.isLocal ? "eye" : "icloud.and.arrow.down") {
                                            if file.isLocal { openPreview(file) } else { Task { await downloadAndOpen(file) } }
                                        }
                                        if file.isLocal {
                                            Button("Поделиться", systemImage: "square.and.arrow.up") { requestExport(.share, file: file) }
                                            Button("Сохранить в Фото", systemImage: "photo") { requestExport(.photos, file: file) }
                                            Button("Сохранить в Файлы", systemImage: "folder") { requestExport(.files, file: file) }
                                        }
                                        if file.isLocal && !file.uploaded {
                                            Button("Выгрузить в Google Drive", systemImage: "icloud.and.arrow.up") { Task { await uploadFile(file) } }
                                                .disabled(!isConnected || !cloudVaultUnlocked || busy)
                                            Button("Удалить с устройства", systemImage: "trash", role: .destructive) { deleteLocal(file) }
                                        } else if file.isLocal && file.uploaded {
                                            Button("Удалить с устройства", systemImage: "iphone", role: .destructive) { deleteLocal(file) }
                                            Button("Удалить из Google Drive", systemImage: "icloud", role: .destructive) { Task { await deleteCloud(file) } }
                                            Button("Удалить везде", systemImage: "trash", role: .destructive) { Task { await deleteEverywhere(file) } }
                                        } else {
                                            Button("Скачать на устройство", systemImage: "icloud.and.arrow.down") { Task { await downloadFile(file) } }
                                                .disabled(!isConnected || !cloudVaultUnlocked || busy)
                                            Button("Удалить из Google Drive", systemImage: "icloud", role: .destructive) { Task { await deleteCloud(file) } }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                        }

                        Text("\(files.count) файлов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.horizontal)
                            .padding(.bottom, 12)
                    }
                }
                .scrollIndicators(.visible)

                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            PhotosPicker(selection: $selection, maxSelectionCount: 100, matching: .any(of: [.images, .videos])) {
                                metalIconButton(icon: "plus", chromatic: true)
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .accessibilityLabel("Добавить фото или видео")
                            Button { showingFileImporter = true } label: { metalIconButton(icon: "folder.badge.plus") }
                                .buttonStyle(.plain).disabled(busy).accessibilityLabel("Добавить любые файлы из приложения Файлы")
                            Image(systemName: isConnected ? "checkmark.icloud.fill" : "icloud.slash")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(isConnected ? .green : .secondary)
                                .accessibilityLabel(isConnected ? "Google Drive подключён" : "Google Drive не подключён")
                            let pendingUploads = files.filter { !$0.uploaded }.count
                            if pendingUploads > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.circle.fill")
                                    Text("\(pendingUploads)").font(.caption.monospacedDigit().weight(.semibold))
                                }
                                .foregroundStyle(.orange)
                                .accessibilityLabel("\(pendingUploads) файлов не выгружено")
                            }
                            Spacer(minLength: 0)
                            if selectionMode {
                                Text("\(selectedFileIDs.count)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if !selectedFileIDs.isEmpty {
                                    Menu {
                                        if selectedFiles.contains(where: { $0.isLocal && !$0.uploaded }) {
                                            Button("Выгрузить выбранные", systemImage: "icloud.and.arrow.up") { Task { await bulkUploadSelected() } }
                                                .disabled(!isConnected || !cloudVaultUnlocked || busy)
                                        }
                                        if selectedFiles.contains(where: { !$0.isLocal }) {
                                            Button("Скачать выбранные", systemImage: "icloud.and.arrow.down") { Task { await bulkDownloadSelected() } }
                                                .disabled(!isConnected || !cloudVaultUnlocked || busy)
                                        }
                                        if selectedFiles.contains(where: { $0.isLocal }) {
                                            Button("Удалить с устройства", systemImage: "iphone", role: .destructive) {
                                                bulkDeleteMode = "local"; showBulkDeleteConfirmation = true
                                            }
                                        }
                                        if selectedFiles.contains(where: { $0.uploaded }) {
                                            Button("Удалить из Google Drive", systemImage: "icloud", role: .destructive) {
                                                bulkDeleteMode = "cloud"; showBulkDeleteConfirmation = true
                                            }
                                            Button("Удалить везде", systemImage: "trash", role: .destructive) {
                                                bulkDeleteMode = "all"; showBulkDeleteConfirmation = true
                                            }
                                        }
                                    } label: { metalIconButton(icon: "ellipsis.circle") }
                                    .disabled(busy)
                                    .accessibilityLabel("Действия с выбранными файлами")
                                }
                                Button("Готово") {
                                    selectionMode = false
                                    selectedFileIDs.removeAll()
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.plain)
                            } else {
                                Button { selectionMode = true; selectedFileIDs.removeAll() } label: { metalIconButton(icon: "checkmark.circle") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Выбрать файлы")
                                Menu {
                                    Section("Сортировка") {
                                        ForEach(VaultSortOrder.allCases) { order in
                                            Button {
                                                sortOrder = order
                                                UserDefaults.standard.set(order.rawValue, forKey: "vdrive.sortOrder")
                                            } label: {
                                                if sortOrder == order {
                                                    Label(order.title, systemImage: "checkmark")
                                                } else {
                                                    Text(order.title)
                                                }
                                            }
                                        }
                                    }
                                    Button("Настройки", systemImage: "gearshape") { showSettings = true }
                                    Button("Заблокировать хранилище", systemImage: "lock.fill") {
                                        locked = true
                                        showingAuthenticator = true
                                        pinEntry = ""
                                    }
                                } label: { metalIconButton(icon: "ellipsis") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Сортировка и настройки")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .animation(.spring(response: 0.38, dampingFraction: 0.76), value: selectionMode)


                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Удалить (selectedFileIDs.count) выбранных файлов?", isPresented: $showBulkDeleteConfirmation, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { Task { await bulkDeleteSelected() } }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(bulkDeleteMode == "local" ? "Удалятся только копии на этом устройстве." : bulkDeleteMode == "cloud" ? "Удалятся только копии из Google Drive." : "Файлы будут удалены и с устройства, и из Google Drive.")
            }
        }
    }

    private var sortedFiles: [VaultFile] {
        files.sorted { lhs, rhs in
            switch sortOrder {
            case .addedNewest:
                if lhs.addedDate != rhs.addedDate { return lhs.addedDate > rhs.addedDate }
                return lhs.id > rhs.id
            case .captureNewest:
                let leftDate = lhs.captureDate ?? lhs.addedDate
                let rightDate = rhs.captureDate ?? rhs.addedDate
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.id > rhs.id
            }
        }
    }

    private var selectedFiles: [VaultFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    @MainActor private func bulkUploadSelected() async {
        guard isConnected, cloudVaultUnlocked else { message = "Подключи и разблокируй Google Drive."; return }
        let targets = selectedFiles.filter { $0.isLocal && !$0.uploaded }
        busy = true
        transferProgress = 0
        transferTotal = targets.count
        transferBytes = 0
        transferExpectedBytes = 0
        transferSpeedBytesPerSecond = 0
        transferLabel = "Выгружаю выбранные файлы…"
        defer {
            busy = false
            transferLabel = ""
            transferProgress = 0
            transferTotal = 0
            transferBytes = 0
            transferExpectedBytes = 0
            transferSpeedBytesPerSecond = 0
            refreshFiles()
        }
        do {
            for (index, file) in targets.enumerated() {
                transferLabel = "Выгружаю файл \(index + 1) из \(targets.count)"
                try await GoogleDriveStore.shared.uploadPlainFile(file.url, key: VDriveCrypto.localKey()) { sent, total, speed in
                    self.transferBytes = sent
                    self.transferExpectedBytes = total
                    self.transferSpeedBytesPerSecond = speed
                }
                if let thumb = try self.makeEncryptedThumbnail(for: file.url) {
                    try await GoogleDriveStore.shared.uploadAuxiliary(thumb, name: file.id + ".vthumb2")
                }
                transferProgress = index + 1
                transferBytes = 0
                transferExpectedBytes = 0
                transferSpeedBytesPerSecond = 0
            }
            await refreshCloudInventory()
            message = "Выбранные файлы выгружены."
        } catch { message = "Ошибка массовой выгрузки: \(error.localizedDescription)" }
    }

    @MainActor private func bulkDownloadSelected() async {
        guard isConnected, cloudVaultUnlocked else { message = "Подключи и разблокируй Google Drive."; return }
        let targets = selectedFiles.filter { !$0.isLocal }
        busy = true
        transferProgress = 0
        transferTotal = targets.count
        transferBytes = 0
        transferExpectedBytes = 0
        transferSpeedBytesPerSecond = 0
        transferLabel = "Скачиваю выбранные файлы…"
        defer {
            busy = false
            transferLabel = ""
            transferProgress = 0
            transferTotal = 0
            transferBytes = 0
            transferExpectedBytes = 0
            transferSpeedBytesPerSecond = 0
            refreshFiles()
        }
        do {
            for (index, file) in targets.enumerated() {
                guard let driveID = GoogleDriveStore.shared.fileIDs[file.id] else { continue }
                transferLabel = "Скачиваю файл \(index + 1) из \(targets.count)"
                try await GoogleDriveStore.shared.downloadFile(driveID: driveID, name: file.id, to: documentsURL(), key: VDriveCrypto.localKey()) { received, total, speed in
                    self.transferBytes = received
                    self.transferExpectedBytes = total
                    self.transferSpeedBytesPerSecond = speed
                }
                transferProgress = index + 1
                transferBytes = 0
                transferExpectedBytes = 0
                transferSpeedBytesPerSecond = 0
            }
            await refreshCloudInventory()
            message = "Выбранные файлы скачаны."
        } catch { message = "Ошибка массового скачивания: \(error.localizedDescription)" }
    }

    @MainActor private func bulkDeleteSelected() async {
        let targets = selectedFiles
        busy = true
        defer {
            busy = false
            selectedFileIDs.removeAll()
            selectionMode = false
            refreshFiles()
        }
        do {
            for file in targets {
                if bulkDeleteMode == "local" {
                    if file.isLocal { try FileManager.default.removeItem(at: file.url) }
                } else if bulkDeleteMode == "cloud" {
                    if file.uploaded { try await GoogleDriveStore.shared.delete(id: file.id) }
                } else {
                    if file.uploaded { try await GoogleDriveStore.shared.delete(id: file.id) }
                    if file.isLocal {
                        try FileManager.default.removeItem(at: file.url)
                        VaultThumbnail.removeLocalThumbnail(for: file.id)
                        try? FileManager.default.removeItem(at: documentsURL().appendingPathComponent(file.id + ".thumb"))
                    }
                }
            }
            await refreshCloudInventory()
            message = "Массовое удаление завершено."
        } catch { message = "Ошибка массового удаления: \(error.localizedDescription)" }
    }

    private func metalIconButton(icon: String, chromatic: Bool = false) -> some View {
        Group {
            if chromatic {
                MetalFx(
                    variant: .circle, preset: .chromatic, strength: 0.92,
                    innerShadow: true, glow: true, glowGain: 0.32, tilt: true,
                    fill: Color(uiColor: .secondarySystemBackground)
                ) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
            } else {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
            }
        }
        .frame(width: 42, height: 42)
        .contentShape(Circle())
    }

    private func metalButton(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 8)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
        .frame(maxWidth: .infinity, minHeight: 46)
    }

    private var displayedVaultKey: String {
        VDriveCrypto.existingLocalKeyData()?.base64EncodedString() ?? "Подключи Google Drive, чтобы создать ключ"
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Занятая память") {
                    HStack { Label("На телефоне", systemImage: "iphone"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: localStorageBytes, countStyle: .file)).fontWeight(.semibold).monospacedDigit() }
                    HStack { Label("Google Drive", systemImage: "cloud"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: cloudStorageBytes, countStyle: .file)).fontWeight(.semibold).monospacedDigit() }
                    Text("На телефоне оригиналы и миниатюры хранятся открытыми для быстрого просмотра; в Google Drive они шифруются.").font(.footnote).foregroundStyle(.secondary)
                    Button("Обновить статистику") { refreshFiles(); Task { await refreshCloudInventory() } }
                }
                Section("Журнал диагностики") {
                    Toggle("Вести подробный журнал", isOn: $diagnosticLoggingEnabled)
                        .onChange(of: diagnosticLoggingEnabled) { _, enabled in VDriveDiagnosticLog.shared.setEnabled(enabled) }
                    Button("Выгрузить журнал", systemImage: "square.and.arrow.up") {
                        do { let url = try VDriveDiagnosticLog.shared.export(); shareURL = url; exportToFiles = false; showingShareSheet = true }
                        catch { message = "Не удалось подготовить журнал: \(error.localizedDescription)" }
                    }
                    Text("Записываются этапы операций, время, размеры файлов, сетевые статусы и ошибки. Пароли, токены, ключ шифрования и содержимое файлов не записываются.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Google Drive") {
                    LabeledContent("Статус", value: isConnected ? "Подключён" : "Не подключён")
                    Button("Настроить OAuth Client ID") { showClientID = true }
                    Button(isConnected ? "Переподключить Google" : "Подключить Google Drive") {
                        showSettings = false
                        Task { await connectGoogle() }
                    }
                    .disabled(clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isConnected {
                        Button("Отключить Google Drive", role: .destructive) {
                            GoogleDriveStore.shared.disconnect()
                            isConnected = false
                        }
                    }
                    Text("В Google Drive хранятся зашифрованные .vdrive-файлы, а не открытые фото.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Ключ шифрования") {
                    Text(displayedVaultKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Скопировать ключ", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = displayedVaultKey
                        message = "Ключ скопирован. Храни его в безопасном месте."
                    }
                    .disabled(VDriveCrypto.existingLocalKeyData() == nil)
                    Text("Ключ хранится в Keychain этого iPhone. Для автоматического восстановления после переустановки он также сохраняется в закрытой папке данных твоего Google Drive. Доступ к Google-аккаунту означает доступ к этой копии ключа.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Восстановление") {
                    Text("При обычном входе в тот же Google-аккаунт VDrive пытается восстановить ключ автоматически. Старый код восстановления оставлен для совместимости.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Восстановить по старому коду", systemImage: "key.fill") {
                        showSettings = false
                        Task {
                            guard isConnected else {
                                message = "Сначала подключи Google Drive."
                                return
                            }
                            do {
                                guard let record = try await GoogleDriveStore.shared.fetchCloudKeyRecord() else {
                                    message = "В Google Drive нет записи восстановления ключа."
                                    return
                                }
                                cloudRecoveryRecord = record
                                recoveryCodeInput = ""
                                showCloudRecoveryPrompt = true
                            } catch {
                                message = "Не удалось получить запись ключа: \(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(!isConnected || busy)
                    Button("Ввести секретный ключ Authenticator", systemImage: "key.horizontal.fill") {
                        authenticatorSecretDraft = authenticatorSecretInput
                        showAuthenticatorSecretEntry = true
                    }
                    if !authenticatorSecretInput.isEmpty {
                        Label("Ключ сохранён на этом устройстве", systemImage: "checkmark.shield.fill").font(.footnote).foregroundStyle(.secondary)
                        Button("Удалить ключ Authenticator", role: .destructive) {
                            authenticatorSecretInput = ""
                            authenticatorSecretDraft = ""
                            UserDefaults.standard.removeObject(forKey: "vdrive.authenticator.secret")
                        }
                    }
                }
                Section("Защита") {
                    Button("Заблокировать сейчас") { showSettings = false; locked = true; showingAuthenticator = true; pinEntry = "" }
                    Button("Изменить PIN") { pinSetupMode = true; locked = true; pinEntry = "" }
                    Button("Face ID") { authenticateFaceID() }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showSettings = false } } }
        }
    }

    @MainActor private func importItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        selection = []
        busy = true
        transferProgress = 0
        transferTotal = items.count
        transferLabel = "Подготовка фото и видео"
        message = transferLabel
        defer {
            busy = false
            transferLabel = ""
            transferProgress = 0
            transferTotal = 0
        }

        var added = 0
        var assetIDs: [String] = []
        var failures: [String] = []
        for (index, item) in items.enumerated() {
                transferProgress = index
                transferLabel = "Читаю фото или видео: \(index + 1) из \(items.count)"
                message = transferLabel
                do {
                    guard let transferred = try await item.loadTransferable(type: PickerFileTransfer.self) else {
                        failures.append("Элемент \(index + 1): iOS не передала файл")
                        continue
                    }
                    defer { try? FileManager.default.removeItem(at: transferred.url) }
                    transferLabel = "Сохраняю на iPhone: \(index + 1) из \(items.count)"
                    message = transferLabel
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? transferred.url.pathExtension
                    let addedTimestamp = Date().timeIntervalSince1970
                    let captureDate: Date? = item.itemIdentifier.flatMap { identifier in
                        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.creationDate
                    }
                    let captureTimestamp = captureDate?.timeIntervalSince1970 ?? 0
                    let name = UUID().uuidString + "__A" + String(Int(addedTimestamp)) +
                        "__C" + String(Int(captureTimestamp)) + "__media." + ext + ".vdrive"
                    let url = documentsURL().appendingPathComponent(name)
                    try await Task.detached(priority: .utility) {
                        try FileManager.default.copyItem(at: transferred.url, to: url)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                    }.value
                    VDriveCrypto.markLocalPlaintextFile(url)
                    if let jpeg = await Task.detached(priority: .utility, operation: {
                        VaultThumbnail.makeJPEGThumbnail(fromFileURL: url, filename: "media." + ext)
                    }).value {
                        try? await Task.detached(priority: .utility) {
                            try VaultThumbnail.saveLocalThumbnail(jpeg, for: name)
                        }.value
                    }
                    added += 1
                    transferProgress = index + 1
                    if let identifier = item.itemIdentifier { assetIDs.append(identifier) }
                } catch {
                    failures.append("Элемент \(index + 1): \(error.localizedDescription)")
                }
            }

            refreshFiles()
            guard added > 0 else {
                message = failures.isEmpty
                    ? "iOS не передала выбранные фото или видео. Попробуй выбрать файл ещё раз или импортировать его через «Файлы»."
                    : "Импорт не выполнен: " + failures.joined(separator: "; ")
                return
            }

            message = "Сохранено на iPhone: \(added)." +
                (failures.isEmpty ? "" : " Не удалось импортировать: \(failures.count).")
            pendingPhotoAssetIDs = assetIDs
            pendingCloudSync = isConnected
            if !assetIDs.isEmpty {
                showDeleteOriginalPhotosAlert = true
            } else {
                finishLocalImportAndSync()
            }
    }

    @MainActor private func finishLocalImportAndSync() {
        pendingPhotoAssetIDs = []
        guard pendingCloudSync else { return }
        pendingCloudSync = false
        refreshFiles()
        guard isConnected && cloudVaultUnlocked else {
            message = "Импорт завершён локально. Облако пока не разблокировано."
            return
        }
        message = "Импорт завершён. Начинаю выгрузку в Google Drive…"
        Task { @MainActor in
            await Task.yield()
            await syncAll()
        }
    }

    @MainActor private func deleteImportedPhotoOriginals() {
        let identifiers = pendingPhotoAssetIDs
        pendingPhotoAssetIDs = []
        guard !identifiers.isEmpty else {
            finishLocalImportAndSync()
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    message = "VDrive сохранил копии на устройстве, но iOS не разрешила удалить оригиналы из Фото."
                    finishLocalImportAndSync()
                }
                return
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            guard assets.count > 0 else {
                Task { @MainActor in
                    message = "Копии сохранены в VDrive. Исходники не найдены в медиатеке."
                    finishLocalImportAndSync()
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { success, error in
                Task { @MainActor in
                    if success {
                        message = "Копии сохранены в VDrive. Исходники перемещены в «Недавно удалённые»."
                    } else {
                        message = "Копии сохранены в VDrive, но оригиналы не удалены: \(error?.localizedDescription ?? "неизвестная ошибка")"
                    }
                    finishLocalImportAndSync()
                }
            }
        }
    }

    @MainActor private func importFilesFromPicker(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        busy = true
        message = "Импортирую выбранные файлы…"
        defer { busy = false }
        var added = 0
        var skipped: [String] = []
            for sourceURL in urls {
                let originalName = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "_")
                let safeName = originalName.isEmpty ? "file.bin" : originalName
                let addedTimestamp = Date().timeIntervalSince1970
                let sourceCreationDate = (try? sourceURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
                let captureTimestamp = sourceCreationDate?.timeIntervalSince1970 ?? 0
                let name = UUID().uuidString + "__A" + String(format: "%.3f", addedTimestamp) +
                    "__C" + String(format: "%.3f", captureTimestamp) + "__" + safeName + ".vdrive"
                let destination = documentsURL().appendingPathComponent(name)
                do {
                    try await Task.detached(priority: .utility) {
                        try self.copyImportedFile(from: sourceURL, to: destination)
                    }.value
                    VDriveCrypto.markLocalPlaintextFile(destination)
                } catch {
                    skipped.append(sourceURL.lastPathComponent + " (" + error.localizedDescription + ")")
                    continue
                }
                if let jpeg = await Task.detached(priority: .utility, operation: {
                    VaultThumbnail.makeJPEGThumbnail(fromFileURL: destination, filename: safeName)
                }).value {
                    try? await Task.detached(priority: .utility) {
                        try VaultThumbnail.saveLocalThumbnail(jpeg, for: name)
                    }.value
                }
                added += 1
            }

            refreshFiles()
            if added == 0 {
                message = skipped.isEmpty ? "Файлы не были добавлены." : "Не добавлено: " + skipped.joined(separator: ", ")
            } else {
                message = "Добавлено на устройство: \(added)" + (skipped.isEmpty ? "" : ". Пропущено: " + skipped.joined(separator: ", "))
            }
            if added > 0 && isConnected {
                pendingCloudSync = true
                Task { @MainActor in
                    await Task.yield()
                    finishLocalImportAndSync()
                }
            }
    }

    nonisolated private func copyImportedFile(from sourceURL: URL, to destination: URL) throws {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { readableURL in
            do {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: readableURL.path, isDirectory: &isDirectory) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                guard !isDirectory.boolValue else { throw CocoaError(.fileReadUnsupportedScheme) }
                try FileManager.default.copyItem(at: readableURL, to: destination)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                      ofItemAtPath: destination.path)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    nonisolated private func makeEncryptedThumbnail(for localFile: URL) throws -> Data? {
        let rawName = localFile.deletingPathExtension().lastPathComponent
        let mediaName = rawName.components(separatedBy: "__").dropFirst().joined(separator: "__")
        guard let jpeg = VaultThumbnail.makeJPEGThumbnail(fromFileURL: localFile, filename: mediaName) else { return nil }
        return try VDriveCrypto.seal(jpeg, key: VDriveCrypto.localKey())
    }

    private func metadataCaptureDate(at url: URL, filename: String) async -> Date? {
        await Task.detached(priority: .utility) {
            let ext = (filename as NSString).pathExtension.lowercased()
            let imageTypes = ["jpg", "jpeg", "heic", "heif", "tif", "tiff", "png", "webp"]
            if imageTypes.contains(ext),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                    ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
                    ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
                if let raw {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = .current
                    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                    if let date = formatter.date(from: raw) { return date }
                }
            }

            let videoTypes = ["mov", "mp4", "m4v", "3gp", "avi", "mkv"]
            if videoTypes.contains(ext) {
                let asset = AVURLAsset(url: url)
                if let metadata = try? await asset.load(.commonMetadata),
                   let item = metadata.first(where: { $0.commonKey == .commonKeyCreationDate }) {
                    if let date = item.dateValue { return date }
                    if let value = item.stringValue {
                        let iso = ISO8601DateFormatter()
                        if let date = iso.date(from: value) { return date }
                        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        if let date = iso.date(from: value) { return date }
                    }
                }
            }
            return nil
        }.value
    }

    @MainActor private func showFileProperties(_ file: VaultFile) async {
        guard file.isLocal else {
            let ext = (file.displayName as NSString).pathExtension
            let type = UTType(filenameExtension: ext)?.localizedDescription ?? "Неизвестный тип"
            let added = file.addedDate == .distantPast ? "Неизвестно" : DateFormatter.localizedString(from: file.addedDate, dateStyle: .medium, timeStyle: .medium)
            let captured = file.captureDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "Будет прочитана из метаданных после скачивания"
            fileProperties = FileProperties(
                title: file.displayName,
                details: "Имя: \(file.displayName)\nТип: \(type)\nРасположение: Google Drive\nДата добавления: \(added)\nДата съёмки / создания: \(captured)\nРазмер и длительность: доступны после скачивания файла на устройство."
            )
            return
        }

        let fileURL = file.url
        let displayName = file.displayName
        let addedDate = file.addedDate
        let captureDate = await metadataCaptureDate(at: fileURL, filename: displayName) ?? file.captureDate
        do {
            let details = try await Task.detached(priority: .utility) { () throws -> String in
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                let bytes = Int64(values.fileSize ?? 0)
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let ext = (displayName as NSString).pathExtension.lowercased()
                let type = UTType(filenameExtension: ext)?.localizedDescription ?? "Неизвестный тип"
                let added = addedDate == .distantPast ? "Неизвестно" : DateFormatter.localizedString(from: addedDate, dateStyle: .medium, timeStyle: .short)
                let captured = captureDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "Не сохранена"
                var lines = [
                    "Имя: \(displayName)",
                    "Тип: \(type)",
                    "Размер файла: \(formatter.string(fromByteCount: bytes)) (\(bytes) байт)",
                    "Дата добавления: \(added)",
                    "Дата съёмки / создания: \(captured)"
                ]
                if ["mov", "mp4", "m4v", "avi", "mkv", "3gp"].contains(ext) {
                    let asset = AVURLAsset(url: fileURL)
                    if let duration = try? await asset.load(.duration) {
                        let seconds = duration.seconds
                        if seconds.isFinite && seconds >= 0 {
                            let total = Int(seconds.rounded())
                            lines.append(String(format: "Длительность видео: %d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60))
                        }
                    }
                    if let tracks = try? await asset.loadTracks(withMediaType: .video),
                       let track = tracks.first,
                       let naturalSize = try? await track.load(.naturalSize),
                       let preferredTransform = try? await track.load(.preferredTransform) {
                        let size = naturalSize.applying(preferredTransform)
                        lines.append("Разрешение: \(Int(abs(size.width))) × \(Int(abs(size.height)))")
                    }
                } else if ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "bmp"].contains(ext),
                          let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                    lines.append("Разрешение: \(width.intValue) × \(height.intValue)")
                }
                return lines.joined(separator: "\n")
            }.value
            fileProperties = FileProperties(title: file.displayName, details: details)
        } catch {
            message = "Не удалось прочитать свойства файла: \(error.localizedDescription)"
        }
    }

    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func isClearlyPlaintextFile(_ url: URL, filename: String? = nil) -> Bool {
        if VDriveCrypto.isMarkedLocalPlaintextFile(url) { return true }
        let name = filename ?? VaultFile(id: url.lastPathComponent, url: url).displayName
        let ext = (name as NSString).pathExtension.lowercased()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 16)) ?? Data()
        if ["jpg", "jpeg"].contains(ext) { return bytes.starts(with: [0xFF, 0xD8, 0xFF]) }
        if ext == "png" { return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }
        if ext == "gif" { return bytes.starts(with: Data("GIF8".utf8)) }
        if ["mp4", "mov", "m4v", "3gp", "heic", "heif"].contains(ext) {
            if bytes.count >= 8, String(data: bytes[4..<8], encoding: .ascii) == "ftyp" {
                return true
            }
            if ["heic", "heif"].contains(ext), bytes.count >= 12 {
                let brand = String(data: bytes[8..<12], encoding: .ascii) ?? ""
                return ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand)
            }
        }
        if ext == "avi" { return bytes.starts(with: Data("RIFF".utf8)) }
        if ext == "mkv" { return bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) }
        if ["tif", "tiff"].contains(ext) {
            return bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        }
        if ext == "pdf" { return bytes.starts(with: Data("%PDF".utf8)) }
        if ["zip", "docx", "xlsx", "pptx", "odt", "ods", "odp"].contains(ext) {
            return bytes.starts(with: [0x50, 0x4B, 0x03, 0x04])
        }
        if ["txt", "csv", "json", "xml", "md", "rtf"].contains(ext),
           let text = String(data: bytes, encoding: .utf8) {
            return !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }
        }
        return false
    }

    @MainActor private func migrateLegacyLocalFiles() async {
        guard let keyData = VDriveCrypto.existingLocalKeyData() else { return }
        let key = SymmetricKey(data: keyData)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: documentsURL(), includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "vdrive" }
        var migrated = 0
        var skippedLarge = 0
        for url in urls {
            if isClearlyPlaintextFile(url) {
                VDriveCrypto.markLocalPlaintextFile(url)
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Legacy whole-file AES-GCM needs the complete ciphertext and plaintext
            // in memory. Avoid risking an iPhone memory-pressure kill on huge videos.
            if size > 256 * 1024 * 1024 {
                skippedLarge += 1
                continue
            }
            let staging = documentsURL().appendingPathComponent("." + UUID().uuidString + ".migration")
            do {
                try await Task.detached(priority: .utility) {
                    try VDriveCrypto.decryptFile(at: url, to: staging, key: key)
                }.value
                if FileManager.default.fileExists(atPath: staging.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
                    VDriveCrypto.markLocalPlaintextFile(url)
                    migrated += 1
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                // Plain files with uncommon extensions fail legacy authentication and
                // are deliberately left untouched.
            }
        }
        if migrated > 0 {
            message = "Переведено в локальный открытый формат: \(migrated) файлов."
        }
        if skippedLarge > 0 {
            message = "\(skippedLarge) старых крупных файлов пока оставлены в прежнем зашифрованном формате, чтобы не перегружать память. Остальные файлы доступны."
        }
    }

    private func refreshFiles() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: documentsURL(), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let local = urls.filter { $0.pathExtension == "vdrive" }.map { VaultFile(id: $0.lastPathComponent, url: $0) }
        var byName = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for name in GoogleDriveStore.shared.fileIDs.keys where name.hasSuffix(".vdrive") {
            if byName[name] == nil { byName[name] = VaultFile(id: name, url: documentsURL().appendingPathComponent(name)) }
        }
        files = byName.values.sorted { $0.id > $1.id }
        localStorageBytes = local.reduce(Int64(0)) { total, file in total + Int64((try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    @MainActor private func refreshCloudInventory() async {
        guard isConnected, cloudVaultUnlocked else { return }
        do {
            let remote = try await GoogleDriveStore.shared.listVaultMedia()
            cloudStorageBytes = remote.reduce(Int64(0)) { total, item in total + (Int64(item.size ?? "") ?? 0) }
            // Replace the inventory instead of keeping stale IDs for files deleted remotely.
            // Drive can contain duplicate names, so avoid Dictionary(uniqueKeysWithValues:) traps.
            var freshMap: [String: String] = [:]
            for item in remote { freshMap[item.name] = item.id }
            GoogleDriveStore.shared.fileIDs = freshMap
            refreshFiles()
        } catch {
            message = "Не удалось обновить список Google Drive: \(error.localizedDescription)"
        }
    }

    private func previewCompatibleURL(for file: VaultFile) throws -> URL {
        let safeName = URL(fileURLWithPath: file.displayName).lastPathComponent
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VDrive-preview-\(UUID().uuidString)-\(safeName)")
        do {
            try FileManager.default.linkItem(at: file.url, to: temp)
        } catch {
            try FileManager.default.copyItem(at: file.url, to: temp)
        }
        return temp
    }

    private func decryptedTemporaryURL(for file: VaultFile) throws -> URL {
        let safeName = URL(fileURLWithPath: file.displayName).lastPathComponent
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VDrive-\(UUID().uuidString)-\(safeName)")
        let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if isClearlyPlaintextFile(file.url) || size > 256 * 1024 * 1024 {
            try FileManager.default.copyItem(at: file.url, to: temp)
            return temp
        }
        guard let keyData = VDriveCrypto.existingLocalKeyData() else {
            throw NSError(domain: "VDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "На устройстве нет ключа для расшифровки этого файла."])
        }
        do {
            try VDriveCrypto.decryptFile(at: file.url, to: temp, key: SymmetricKey(data: keyData))
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return temp
    }

    private func openPreview(_ file: VaultFile) {
        cleanPreview()
        guard file.isLocal else { Task { await downloadAndOpen(file) }; return }
        do {
            let currentFiles = sortedFiles.filter { $0.isLocal }
            var temporaryURLs: [URL] = []
            let urls = try currentFiles.map { current -> URL in
                if isClearlyPlaintextFile(current.url) {
                    let temp = try previewCompatibleURL(for: current)
                    temporaryURLs.append(temp)
                    return temp
                }
                let temp = try decryptedTemporaryURL(for: current)
                temporaryURLs.append(temp)
                return temp
            }
            let items = zip(currentFiles, urls).enumerated().map { index, pair in
                PreviewItem(id: index, name: pair.0.displayName, url: pair.1)
            }
            guard !items.isEmpty else {
                message = "Хранилище ещё загружается. Попробуйте снова."
                return
            }
            previewURLs = temporaryURLs
            previewIndex = currentFiles.firstIndex(of: file) ?? 0
            previewPresentation = PreviewPresentation(items: items, initialIndex: previewIndex)
        } catch {
            cleanPreview()
            previewPresentation = nil
            message = "Не удалось открыть файл: \(error.localizedDescription)"
        }
    }

    private func requestExport(_ action: MediaExportAction, file: VaultFile) {
        selectedFile = file
        pendingExportAction = action
        showExportConfirmation = true
    }

    private func performPendingExport() {
        guard let file = selectedFile, let action = pendingExportAction else { return }
        pendingExportAction = nil
        do {
            let url = try decryptedTemporaryURL(for: file)
            switch action {
            case .share:
                exportToFiles = false
                shareURL = url
                showingShareSheet = true
            case .files:
                exportToFiles = true
                shareURL = url
                showingShareSheet = true
            case .photos:
                saveToPhotos(url, file: file)
            }
        } catch {
            message = "Не удалось подготовить файл: \(error.localizedDescription)"
        }
    }

    private func saveToPhotos(_ url: URL, file: VaultFile) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = "Нет разрешения добавлять файлы в Фото. Разрешение можно включить в настройках iPhone." }
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let ext = (file.displayName as NSString).pathExtension.lowercased()
                if ["mov", "mp4", "m4v", "avi", "mkv"].contains(ext) {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    message = success ? "Файл сохранён в Фото." : "Не удалось сохранить в Фото: \(error?.localizedDescription ?? "неизвестная ошибка")"
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func cleanPreview() {
        previewURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        previewURLs = []
        previewIndex = 0
        previewPresentation = nil
    }

    private func cleanShareFile() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        shareURL = nil
        exportToFiles = false
    }

    @MainActor private func uploadFile(_ file: VaultFile) async {
        guard isConnected else { showGoogleSetupInfo = true; return }
        guard cloudVaultUnlocked else { message = "Сначала разблокируй облачное хранилище секретным ключом."; return }
        guard file.isLocal else { message = "Файл уже находится только в облаке."; return }
        busy = true
        transferProgress = 0
        transferTotal = 2
        transferBytes = 0
        transferExpectedBytes = 0
        transferSpeedBytesPerSecond = 0
        transferLabel = "Шифрую и выгружаю в Google Drive…"
        defer {
            busy = false
            transferLabel = ""
            transferProgress = 0
            transferTotal = 0
            transferBytes = 0
            transferExpectedBytes = 0
            transferSpeedBytesPerSecond = 0
        }
        do {
            try await GoogleDriveStore.shared.uploadPlainFile(file.url, key: VDriveCrypto.localKey()) { sent, total, speed in
                self.transferBytes = sent
                self.transferExpectedBytes = total
                self.transferSpeedBytesPerSecond = speed
            }
            transferProgress = 1
            transferLabel = "Файл выгружен. Загружаю миниатюру…"
            let thumb = try await Task.detached(priority: .utility) {
                try self.makeEncryptedThumbnail(for: file.url)
            }.value
            if let thumb {
                try await GoogleDriveStore.shared.uploadAuxiliary(thumb, name: file.id + ".vthumb2")
            }
            transferProgress = 2
            refreshFiles()
            message = "Файл и миниатюра выгружены в Google Drive."
        } catch { message = "Ошибка выгрузки: \(error.localizedDescription)" }
    }

    @MainActor private func downloadFile(_ file: VaultFile) async {
        guard !busy else { message = "Дождись завершения текущей операции."; return }
        guard isConnected, cloudVaultUnlocked else { message = "Подключи и разблокируй Google Drive."; return }
        guard !file.isLocal, let driveID = GoogleDriveStore.shared.fileIDs[file.id] else { return }
        busy = true
        transferProgress = 0
        transferTotal = 1
        transferBytes = 0
        transferExpectedBytes = 0
        transferSpeedBytesPerSecond = 0
        transferLabel = "Скачиваю файл с Google Drive…"
        defer {
            busy = false
            transferLabel = ""
            transferProgress = 0
            transferTotal = 0
            transferBytes = 0
            transferExpectedBytes = 0
            transferSpeedBytesPerSecond = 0
        }
        do {
            try await GoogleDriveStore.shared.downloadFile(driveID: driveID, name: file.id, to: documentsURL(), key: VDriveCrypto.localKey()) { received, total, speed in
                self.transferBytes = received
                self.transferExpectedBytes = total
                self.transferSpeedBytesPerSecond = speed
            }
            transferProgress = 1
            refreshFiles()
            message = "Файл скачан на устройство."
        } catch {
            VDriveDiagnosticLog.shared.write("ERROR", "Скачивание \(file.id): \(error.localizedDescription)")
            message = "Не удалось скачать файл: \(error.localizedDescription)"
        }
    }

    @MainActor private func downloadAndOpen(_ file: VaultFile) async {
        await downloadFile(file)
        guard file.isLocal || FileManager.default.fileExists(atPath: file.url.path) else { return }
        refreshFiles()
        if let local = files.first(where: { $0.id == file.id }) { openPreview(local) }
    }

    private func deleteLocal(_ file: VaultFile) {
        do {
            guard file.isLocal else { message = "Файл хранится только в Google Drive."; return }
            try FileManager.default.removeItem(at: file.url)
            VDriveCrypto.unmarkLocalPlaintextFile(file.url)
            VaultThumbnail.removeLocalThumbnail(for: file.id)
            refreshFiles()
            message = file.uploaded ? "Удалено с устройства. Копия в Google Drive сохранена." : "Файл удалён с устройства."
        } catch { message = "Ошибка удаления: \(error.localizedDescription)" }
    }

    private func deleteCloud(_ file: VaultFile) async {
        guard cloudVaultUnlocked else { message = "Нельзя менять облако до ввода секретного ключа."; return }
        do {
            try await GoogleDriveStore.shared.delete(id: file.id)
            refreshFiles()
            message = "Копия удалена из Google Drive."
        } catch { message = "Не удалось удалить из Google Drive: \(error.localizedDescription)" }
    }

    private func deleteEverywhere(_ file: VaultFile) async {
        if file.uploaded && !cloudVaultUnlocked { message = "Нельзя менять облако до ввода кода восстановления."; return }
        do {
            if file.uploaded { try await GoogleDriveStore.shared.delete(id: file.id) }
            if file.isLocal {
                try? FileManager.default.removeItem(at: file.url)
                VDriveCrypto.unmarkLocalPlaintextFile(file.url)
            }
            VaultThumbnail.removeLocalThumbnail(for: file.id)
            refreshFiles()
            message = "Файл удалён с устройства и из Google Drive."
        } catch { message = "Ошибка удаления из Google Drive: \(error.localizedDescription)" }
    }

    @MainActor private func syncAll() async {
        guard isConnected else { showGoogleSetupInfo = true; return }
        guard cloudVaultUnlocked else { message = "Сначала разблокируй облачное хранилище кодом восстановления."; return }
        // Refresh thumbnails for every local original, including files already uploaded.
        // This replaces stale aspect-fit previews in both the local cache and Drive.
        let localFiles = files.filter { $0.isLocal }
        let pending = localFiles.filter { !$0.uploaded }
        busy = true
        transferProgress = 0
        transferTotal = max(localFiles.count, 1)
        transferBytes = 0
        transferExpectedBytes = 0
        transferSpeedBytesPerSecond = 0
        transferLabel = "Подготовка выгрузки в Google Drive"
        defer {
            busy = false
            transferLabel = ""
            transferProgress = 0
            transferTotal = 0
            transferBytes = 0
            transferExpectedBytes = 0
            transferSpeedBytesPerSecond = 0
        }
        do {
            for (index, file) in localFiles.enumerated() {
                if !file.uploaded {
                    transferLabel = "Выгружаю медиа: \(index + 1) из \(localFiles.count)"
                    try await GoogleDriveStore.shared.uploadPlainFile(file.url, key: VDriveCrypto.localKey()) { sent, total, speed in
                        self.transferBytes = sent
                        self.transferExpectedBytes = total
                        self.transferSpeedBytesPerSecond = speed
                    }
                }
                transferLabel = "Создаю квадратную миниатюру: \(index + 1) из \(localFiles.count)"
                let thumb = try await Task.detached(priority: .utility) {
                    try self.makeEncryptedThumbnail(for: file.url)
                }.value
                if let thumb {
                    transferLabel = "Передаю миниатюру: \(index + 1) из \(localFiles.count)"
                    try await GoogleDriveStore.shared.uploadAuxiliary(thumb, name: file.id + ".vthumb2")
                }
                transferProgress = index + 1
                transferBytes = 0
                transferExpectedBytes = 0
                transferSpeedBytesPerSecond = 0
            }
            refreshFiles()
            message = localFiles.isEmpty
                ? "Все файлы уже синхронизированы."
                : "Синхронизация завершена: обновлено миниатюр — \(localFiles.count), новых файлов — \(pending.count)."
        } catch { message = "Ошибка Google Drive: \(error.localizedDescription)" }
    }

    @MainActor private func downloadMissing() async {
        guard !busy else { message = "Дождись завершения текущей операции."; return }
        VDriveDiagnosticLog.shared.write("SYNC", "Начата массовая загрузка отсутствующих файлов")
        guard isConnected else { showGoogleSetupInfo = true; return }
        guard cloudVaultUnlocked else { message = "Сначала разблокируй облачное хранилище кодом восстановления."; return }
        busy = true
        transferProgress = 0
        transferTotal = 0
        transferLabel = "Получаю список файлов Google Drive…"
        defer {
            busy = false
            transferLabel = ""
            transferProgress = 0
            transferTotal = 0
        }
        transferBytes = 0
        transferExpectedBytes = 0
        transferSpeedBytesPerSecond = 0
        do {
            let localNames = Set(files.filter { $0.isLocal }.map { $0.id })
            let count = try await GoogleDriveStore.shared.downloadMissing(to: documentsURL(), localNames: localNames, key: VDriveCrypto.localKey()) { received, total, speed in
                self.transferBytes = received
                self.transferExpectedBytes = total
                self.transferSpeedBytesPerSecond = speed
            }
            VDriveDiagnosticLog.shared.write("SYNC", "Массовая загрузка завершена; files=\(count)")
            transferProgress = count
            transferTotal = max(count, 1)
            transferLabel = "Загрузка из Google Drive завершена"
            refreshFiles()
            message = count == 0 ? "Все облачные файлы уже на устройстве." : "Скачано с Google Drive: \(count)"
        } catch {
            VDriveDiagnosticLog.shared.write("ERROR", "Массовое скачивание: \(error.localizedDescription)")
            message = "Ошибка скачивания: \(error.localizedDescription)"
        }
    }

    @MainActor private func autoConnectGoogleIfNeeded() async {
        guard !autoConnectAttempted, GoogleDriveStore.shared.hasRefreshToken else { return }
        autoConnectAttempted = true
        await connectGoogle()
    }

    @MainActor private func connectGoogle() async {
        let clientID = clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (UserDefaults.standard.string(forKey: "googleClientID") ?? "15564278108-3npmd22j8obehjl19rpbpeeldlg2bn3k.apps.googleusercontent.com")
            : clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(clientID, forKey: "googleClientID")
        do {
            try await GoogleDriveStore.shared.connect(clientID: clientID)
            isConnected = true
            message = "Google подключён. Проверяю защищённое хранилище…"
            var autoKeyMismatch = false

            // Prefer automatic recovery, but never replace an existing device key
            // merely because the local originals are now plaintext.
            if let autoKey = try await GoogleDriveStore.shared.fetchAutoKey() {
                let candidate = SymmetricKey(data: autoKey)
                if autoKey.count == 32, await localFilesMatchKey(candidate) {
                    try VDriveCrypto.restoreDirectKey(autoKey)
                    cloudVaultUnlocked = true
                    message = "Ключ восстановлен через Google. Обновляю список файлов…"
                    await refreshCloudInventory()
                    refreshFiles()
                    message = "VDrive разблокирован через Google. Секретный ключ вводить не нужно."
                    return
                }
                autoKeyMismatch = true
                cloudVaultUnlocked = false
                message = "Автоматический ключ Google не совпадает с ключом на этом устройстве. Ключ не заменён; проверь, что вошёл в нужный аккаунт."
            }

            if let record = try await GoogleDriveStore.shared.fetchCloudKeyRecord() {
                // On the original installation, a valid Keychain key plus at least
                // one decryptable local file is enough to migrate without prompting.
                // With no local proof (e.g. after reinstall), retain the one-time code flow.
                let localURLs = ((try? FileManager.default.contentsOfDirectory(at: documentsURL(), includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "vdrive" }
                if !autoKeyMismatch, !localURLs.isEmpty,
                   let localKeyData = VDriveCrypto.existingLocalKeyData(),
                   await localFilesMatchKey(SymmetricKey(data: localKeyData)) {
                    do {
                        try await GoogleDriveStore.shared.createAutoKeyIfMissing(try VDriveCrypto.localKeyData())
                        cloudVaultUnlocked = true
                        await refreshCloudInventory()
                        refreshFiles()
                        message = "Ключ проверен по локальным файлам и сохранён для автоматического входа через Google."
                        return
                    } catch {
                        // Do not block a valid existing local key if cloud migration fails;
                        // keep the legacy recovery prompt available for the remote vault.
                        message = "Локальный ключ подходит к файлам, но авто-восстановление не сохранилось: \(error.localizedDescription)"
                    }
                }
                cloudRecoveryRecord = record
                recoveryCodeInput = ""
                showCloudRecoveryPrompt = true
                cloudVaultUnlocked = false
                message = "Для первого восстановления после переустановки нужен сохранённый секретный ключ."
                return
            }

            if try await GoogleDriveStore.shared.hasRemoteVaultFiles() {
                cloudVaultUnlocked = false
                message = "В Google Drive уже есть файлы, но нет записи ключа. Ничего не скачано и не перезаписано."
                return
            }

            let result = try VDriveCrypto.makeCloudKeyRecord()
            try await GoogleDriveStore.shared.createCloudKeyRecord(result.record)
            // Keep the old recovery-code record as a fallback; the direct copy is
            // separate and never overwrites an existing recovery record.
            do { try await GoogleDriveStore.shared.createAutoKeyIfMissing(try VDriveCrypto.localKeyData()) }
            catch { message = "Облако создано, но авто-восстановление не сохранилось: \(error.localizedDescription)" }
            recoveryCode = result.code
            cloudVaultUnlocked = true
            showRecoveryCodeAlert = true
            message = "Ключ создан и сохранён. Его можно посмотреть и скопировать в настройках."
        } catch {
            message = "Google Drive: \(error.localizedDescription)"
        }
    }

    @MainActor private func restoreCloudVault() async {
        guard let record = cloudRecoveryRecord else { return }
        busy = true
        defer { busy = false }
        do {
            // Decode without changing Keychain first. If local files use another key,
            // preserve the current key and ask the user to resolve the vault mismatch.
            let candidateKey = try VDriveCrypto.cloudKey(from: record, code: recoveryCodeInput)
            let localFilesMatch = await localFilesMatchKey(candidateKey)

            guard localFilesMatch else {
                recoveryCodeInput = ""
                message = "Этот облачный ключ не подходит к части локальных файлов. Текущий ключ и файлы сохранены без изменений. Для безопасного объединения нужен тот же ключ хранилища."
                showCloudRecoveryPrompt = true
                return
            }

            try VDriveCrypto.restoreCloudKey(record, code: recoveryCodeInput)
            // The legacy secret was accepted and all local files matched, so we can
            // safely create a direct recovery copy for future Google sign-ins.
            do { try await GoogleDriveStore.shared.createAutoKeyIfMissing(try VDriveCrypto.localKeyData()) }
            catch { message = "Ключ принят, но авто-восстановление не удалось сохранить: \(error.localizedDescription)" }
        } catch {
            recoveryCodeInput = ""
            message = "Секретный ключ не подошёл или запись восстановления повреждена. Локальные файлы не изменены."
            showCloudRecoveryPrompt = true
            return
        }

        cloudRecoveryRecord = nil
        recoveryCodeInput = ""
        cloudVaultUnlocked = true
        message = "Ключ принят. Обновляю список облачных файлов и миниатюры…"
        await refreshCloudInventory()
        refreshFiles()
        message = "Облако разблокировано. Оригиналы не скачивались — выбери файл, чтобы загрузить его на телефон."
    }

    private func localFilesMatchKey(_ candidateKey: SymmetricKey) async -> Bool {
        let candidateData = candidateKey.withUnsafeBytes { Data($0) }
        if let storedKey = VDriveCrypto.existingLocalKeyData() {
            if storedKey == candidateData { return true }
        } else {
            // A fresh installation has no local proof to compare; the private
            // Google Drive appData key copy is the recovery source.
            let hasLocalFiles = ((try? FileManager.default.contentsOfDirectory(at: documentsURL(), includingPropertiesForKeys: nil)) ?? [])
                .contains { $0.pathExtension == "vdrive" }
            if !hasLocalFiles { return true }
        }

        let localURLs = ((try? FileManager.default.contentsOfDirectory(at: documentsURL(), includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "vdrive" }
        let plainPaths = Set(localURLs.filter { isClearlyPlaintextFile($0) }.map { $0.path })
        let validation = await Task.detached(priority: .utility) { () -> (valid: Bool, provedByLegacyFile: Bool) in
            var provedByLegacyFile = false
            for url in localURLs where !plainPaths.contains(url.path) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 256 * 1024 * 1024 else { return (false, false) }
                let matches = autoreleasepool { () -> Bool in
                    do {
                        let encrypted = try Data(contentsOf: url, options: [.mappedIfSafe])
                        _ = try VDriveCrypto.open(encrypted, key: candidateKey).count
                        return true
                    } catch { return false }
                }
                if !matches { return (false, false) }
                provedByLegacyFile = true
            }
            return (true, provedByLegacyFile)
        }.value
        guard validation.valid else { return false }
        // A different existing Keychain key may only be replaced if a legacy
        // encrypted local file proves the candidate, not merely because files are plaintext.
        return VDriveCrypto.existingLocalKeyData() == nil
            || VDriveCrypto.existingLocalKeyData() == candidateData
            || validation.provedByLegacyFile
    }

    private func pinDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func authenticateFaceID() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            message = "Face ID недоступен. Используйте PIN."
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Разблокировать VDrive") { success, authError in
            DispatchQueue.main.async {
                if success { locked = false; showingAuthenticator = false; pinEntry = ""; Task { await autoConnectGoogleIfNeeded(); await refreshCloudInventory() } }
                else { message = authError?.localizedDescription ?? "Не удалось разблокировать" }
            }
        }
    }
}


/// Stream network transfers to disk and report actual byte counts.
private final class VDriveTransferSession: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (Int64, Int64, Double) -> Void
    private var session: URLSession!
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var responseData = Data()
    private var outputHandle: FileHandle?
    private var lastReport = Date.distantPast
    private var lastBytes: Int64 = 0
    private var lastDate = Date()
    private var speed: Double = 0
    private var receivedDownloadBytes: Int64 = 0
    private var expectedDownloadBytes: Int64 = 0

    init(progress: @escaping (Int64, Int64, Double) -> Void) {
        self.progress = progress
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    }

    func download(_ request: URLRequest, expectedBytes: Int64 = 0) async throws -> (URL, URLResponse) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vdrive-download-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        outputHandle = try FileHandle(forWritingTo: url)
        do {
            let (_, response) = try await perform(request, uploadFile: nil, expectedDownloadBytes: expectedBytes)
            try outputHandle?.close()
            outputHandle = nil
            return (url, response)
        } catch {
            try? outputHandle?.close()
            outputHandle = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func upload(_ request: URLRequest, file: URL) async throws -> (Data, URLResponse) {
        try await perform(request, uploadFile: file)
    }

    private func perform(_ request: URLRequest, uploadFile: URL?, expectedDownloadBytes: Int64 = 0) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            responseData = Data()
            receivedDownloadBytes = 0
            self.expectedDownloadBytes = expectedDownloadBytes
            lastBytes = 0
            lastDate = Date()
            lastReport = .distantPast
            let task: URLSessionTask = uploadFile.map { session.uploadTask(with: request, fromFile: $0) } ?? session.dataTask(with: request)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let outputHandle {
            do {
                try outputHandle.write(contentsOf: data)
                receivedDownloadBytes += Int64(data.count)
                report(receivedDownloadBytes, expectedDownloadBytes)
            } catch { dataTask.cancel() }
        } else { responseData.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if outputHandle != nil {
            if response.expectedContentLength > 0 { expectedDownloadBytes = response.expectedContentLength }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error); return }
        guard let response = task.response else { continuation.resume(throwing: DriveError.invalidResponse); return }
        continuation.resume(returning: (outputHandle == nil ? responseData : Data(), response))
    }

    private func report(_ bytes: Int64, _ total: Int64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastDate)
        if elapsed >= 0.05 {
            speed = Double(max(0, bytes - lastBytes)) / elapsed
            lastBytes = bytes
            lastDate = now
        }
        guard now.timeIntervalSince(lastReport) >= 0.2 || (total > 0 && bytes >= total) else { return }
        lastReport = now
        let callback = progress
        let currentSpeed = speed
        DispatchQueue.main.async { callback(bytes, total, currentSpeed) }
    }
}

private final class GoogleDriveStore: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleDriveStore()
    private let tokenAccount = "vdrive.google.refresh"
    private let mapKey = "vdrive.google.fileMap"
    private var clientID = ""
    private var accessToken = ""
    private let downloadLock = NSLock()
    private var activeDownloadIDs = Set<String>()
    private func beginDownload(_ id: String) -> Bool {
        downloadLock.lock()
        defer { downloadLock.unlock() }
        guard !activeDownloadIDs.contains(id) else { return false }
        activeDownloadIDs.insert(id)
        return true
    }
    private func endDownload(_ id: String) {
        downloadLock.lock()
        activeDownloadIDs.remove(id)
        downloadLock.unlock()
    }
    var fileIDs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: mapKey) }
    }
    var hasRefreshToken: Bool { readKeychain() != nil }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return keyWindow
        }
        if let firstWindow = scenes.first?.windows.first {
            return firstWindow
        }
        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }
        fatalError("No active UIWindowScene available")
    }

    func connect(clientID: String) async throws {
        self.clientID = clientID
        if hasRefreshToken {
            do {
                try await ensureAccessToken()
                VDriveDiagnosticLog.shared.write("AUTH", "Существующая Google-сессия восстановлена из Keychain; OAuth экран не открывался")
                return
            } catch {
                accessToken = ""
                VDriveDiagnosticLog.shared.write("AUTH", "Сохранённый refresh token недействителен; потребуется повторная авторизация")
            }
        }
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        let scheme = "com.googleusercontent.apps.\(prefix)"
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.randomString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Self.randomString(length: 24)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/drive.appdata"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true")
        ]
        if !hasRefreshToken { components.queryItems?.append(URLQueryItem(name: "prompt", value: "consent")) }
        guard let authURL = components.url else { throw DriveError.invalidResponse }
        VDriveDiagnosticLog.shared.write("AUTH", "Запуск OAuth; refresh token уже есть: \(hasRefreshToken)")
        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: DriveError.invalidResponse); return }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            guard session.start() else { continuation.resume(throwing: DriveError.authFailed); return }
            Self.activeSession = session
        }
        guard URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw DriveError.authFailed
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirect)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: data, encoding: .utf8) ?? "OAuth token error")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.access_token
        if let refresh = token.refresh_token, !refresh.isEmpty { try saveKeychain(refresh) }
        VDriveDiagnosticLog.shared.write("AUTH", "OAuth завершён; refresh token сохранён: \(hasRefreshToken)")
    }

    func fetchCloudKeyRecord() async throws -> Data? {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "q", value: "name = 'vdrive-key-record.dat' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size)")
        ]
        var listRequest = URLRequest(url: components.url!)
        listRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
        guard let listHTTP = listResponse as? HTTPURLResponse, (200..<300).contains(listHTTP.statusCode) else {
            throw DriveError.server(String(data: listData, encoding: .utf8) ?? "Не удалось проверить ключ хранилища")
        }
        let matches = try JSONDecoder().decode(DriveFileList.self, from: listData).files
        guard let record = matches.first else { return nil }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(record.id)?alt=media")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server("Не удалось скачать ключ хранилища")
        }
        return data
    }

    /// A second, direct recovery copy. It is created only for a new vault or after
    /// the user has successfully unlocked the legacy recovery record.
    func fetchAutoKey() async throws -> Data? {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "q", value: "name = 'vdrive-key-auto.dat' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size)")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server("Не удалось проверить автоматическое восстановление ключа")
        }
        let matches = try JSONDecoder().decode(DriveFileList.self, from: data).files
        guard let file = matches.first else { return nil }
        var download = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")!)
        download.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (keyData, keyResponse) = try await URLSession.shared.data(for: download)
        guard let keyHTTP = keyResponse as? HTTPURLResponse, (200..<300).contains(keyHTTP.statusCode) else {
            throw DriveError.server("Не удалось получить автоматическую копию ключа")
        }
        return keyData
    }

    func createAutoKeyIfMissing(_ keyData: Data) async throws {
        try await ensureAccessToken()
        guard keyData.count == 32 else { throw DriveError.server("Некорректный ключ хранилища") }
        guard try await fetchAutoKey() == nil else { return }
        let boundary = "vdrive-auto-key-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "name": "vdrive-key-auto.dat",
            "mimeType": "application/octet-stream",
            "parents": ["appDataFolder"]
        ]
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(keyData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: responseData, encoding: .utf8) ?? "Не удалось сохранить автоматическую копию ключа")
        }
    }

    func hasRemoteVaultFiles() async throws -> Bool {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "1"),
            URLQueryItem(name: "q", value: "name contains '.vdrive' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id)")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: data, encoding: .utf8) ?? "Не удалось проверить облачные файлы")
        }
        return !(try JSONDecoder().decode(RemoteFileIDs.self, from: data).files.isEmpty)
    }

    func createCloudKeyRecord(_ data: Data) async throws {
        try await ensureAccessToken()
        // Never replace an existing recovery record.
        guard try await fetchCloudKeyRecord() == nil else {
            throw DriveError.server("Запись ключа уже существует; отказ от перезаписи.")
        }
        let boundary = "vdrive-key-\(UUID().uuidString)"
        let metadata: [String: Any] = [
            "name": "vdrive-key-record.dat",
            "mimeType": "application/json",
            "parents": ["appDataFolder"]
        ]
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: responseData, encoding: .utf8) ?? "Не удалось сохранить ключ хранилища")
        }
    }

    func uploadPlainFile(_ plaintextFile: URL, key: SymmetricKey, progress: @escaping (Int64, Int64, Double) -> Void = { _, _, _ in }) async throws {
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VDrive-cloud-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let encryptedFile = stagingDirectory.appendingPathComponent(plaintextFile.lastPathComponent)
        let originalSize = Int64((try? plaintextFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        await MainActor.run { progress(0, originalSize, 0) }
        try await Task.detached(priority: .utility) {
            try VDriveCrypto.encryptFile(at: plaintextFile, to: encryptedFile, key: key) { done, total, speed in
                DispatchQueue.main.async { progress(done, total, speed) }
            }
        }.value
        await MainActor.run { progress(originalSize, originalSize, 0) }
        try await upload(encryptedFile) { sent, total, speed in
            guard total > 0, originalSize > 0 else {
                progress(sent, originalSize, speed)
                return
            }
            let fraction = min(1.0, max(0.0, Double(sent) / Double(total)))
            progress(Int64(Double(originalSize) * fraction), originalSize,
                     speed * Double(originalSize) / Double(total))
        }
        var map = fileIDs
        map[plaintextFile.lastPathComponent] = map.removeValue(forKey: encryptedFile.lastPathComponent)
        fileIDs = map
    }

    func upload(_ file: URL, progress: @escaping (Int64, Int64, Double) -> Void = { _, _, _ in }) async throws {
        try await ensureAccessToken()
        // Assemble multipart body on disk; do not duplicate large encrypted videos in RAM.
        let boundary = "vdrive-\(UUID().uuidString)"
        let metadata: [String: Any] = ["name": file.lastPathComponent, "mimeType": "application/octet-stream"]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("vdrive-upload-\(UUID().uuidString).body")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        try output.write(contentsOf: metadataData)
        try output.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close(); try? output.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let transfer = VDriveTransferSession(progress: progress)
        let (responseData, response) = try await transfer.upload(request, file: bodyURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: responseData, encoding: .utf8) ?? "Upload error")
        }
        let uploaded = try JSONDecoder().decode(DriveFileResponse.self, from: responseData)
        var map = fileIDs
        map[file.lastPathComponent] = uploaded.id
        fileIDs = map
    }

    func uploadAuxiliary(_ data: Data, name: String) async throws {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: "1"),
            URLQueryItem(name: "q", value: "name = '\(name)' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]
        var lookup = URLRequest(url: components.url!)
        lookup.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (lookupData, lookupResponse) = try await URLSession.shared.data(for: lookup)
        guard let lookupHTTP = lookupResponse as? HTTPURLResponse, (200..<300).contains(lookupHTTP.statusCode) else {
            throw DriveError.server(String(data: lookupData, encoding: .utf8) ?? "Не удалось найти старую миниатюру")
        }
        let existing = try JSONDecoder().decode(DriveFileList.self, from: lookupData).files.first
        var request: URLRequest
        if let existing {
            // Replace media content in-place; repeated syncs must not create duplicate thumbnails.
            request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(existing.id)?uploadType=media")!)
            request.httpMethod = "PATCH"
            request.httpBody = data
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        } else {
            let boundary = "vdrive-sidecar-" + UUID().uuidString
            let metadata: [String: Any] = ["name": name, "mimeType": "application/octet-stream"]
            var body = Data()
            body.append(("--" + boundary + "\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n").data(using: .utf8)!)
            body.append(try JSONSerialization.data(withJSONObject: metadata))
            body.append(("\r\n--" + boundary + "\r\nContent-Type: application/octet-stream\r\n\r\n").data(using: .utf8)!)
            body.append(data)
            body.append(("\r\n--" + boundary + "--\r\n").data(using: .utf8)!)
            request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name")!)
            request.httpMethod = "POST"
            request.setValue("multipart/related; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: responseData, encoding: .utf8) ?? "Thumbnail upload error")
        }
    }

    func listVaultMedia() async throws -> [DriveFileResponse] {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "q", value: "trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size)")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: data, encoding: .utf8) ?? "Не удалось получить список файлов Drive")
        }
        let remote = try JSONDecoder().decode(DriveFileList.self, from: data).files.filter { $0.name.hasSuffix(".vdrive") }
        return remote
    }

    func downloadFile(driveID: String, name: String, to directory: URL, key: SymmetricKey, progress: @escaping (Int64, Int64, Double) -> Void = { _, _, _ in }) async throws {
        let started = Date()
        VDriveDiagnosticLog.shared.write("DOWNLOAD", "Начало; driveID=\(driveID.prefix(8)); extension=\((name as NSString).pathExtension)")
        guard beginDownload(driveID) else {
            VDriveDiagnosticLog.shared.write("DOWNLOAD", "Повторный запрос пропущен: файл уже скачивается; id=\(driveID.prefix(8))")
            throw DriveError.server("Этот файл уже скачивается. Дождись завершения текущей загрузки.")
        }
        defer { endDownload(driveID) }
        try await ensureAccessToken()
        let metadataURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(driveID)?fields=size")!
        var metadataRequest = URLRequest(url: metadataURL)
        metadataRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (metadataData, metadataResponse) = try await URLSession.shared.data(for: metadataRequest)
        guard let metadataHTTP = metadataResponse as? HTTPURLResponse, (200..<300).contains(metadataHTTP.statusCode) else {
            throw DriveError.server("Не удалось проверить размер файла перед скачиванием.")
        }
        let metadata = try JSONDecoder().decode(DriveFileMetadata.self, from: metadataData)
        let remoteSize = Int64(metadata.size ?? "") ?? 0
        VDriveDiagnosticLog.shared.write("DOWNLOAD", "Метаданные получены; bytes=\(remoteSize)")
        if remoteSize > 256 * 1024 * 1024 {
            var rangeRequest = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(driveID)?alt=media")!)
            rangeRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            rangeRequest.setValue("bytes=0-7", forHTTPHeaderField: "Range")
            let (rangeURL, rangeResponse) = try await URLSession.shared.download(for: rangeRequest)
            defer { try? FileManager.default.removeItem(at: rangeURL) }
            guard let rangeHTTP = rangeResponse as? HTTPURLResponse, rangeHTTP.statusCode == 206 else {
                throw DriveError.server("Google Drive не поддержал безопасную проверку формата большого файла. Скачивание отменено.")
            }
            let prefix = try Data(contentsOf: rangeURL)
            guard prefix == Data("VDRCHNK1".utf8) else {
                VDriveDiagnosticLog.shared.write("DOWNLOAD", "Отмена до полной загрузки: старый монолитный формат; bytes=\(remoteSize)")
                throw DriveError.server("Старый формат шифрования, файл слишком велик для безопасной загрузки на iPhone (\(ByteCountFormatter.string(fromByteCount: remoteSize, countStyle: .file))). Нужна повторная выгрузка оригинала.")
            }
            VDriveDiagnosticLog.shared.write("DOWNLOAD", "Большой файл подтверждён как потоковый формат")
        }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/" + driveID + "?alt=media")!)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let transfer = VDriveTransferSession(progress: progress)
        let (downloadedURL, response) = try await transfer.download(request, expectedBytes: remoteSize)
        let downloadedBytes = (try? downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        VDriveDiagnosticLog.shared.write("DOWNLOAD", "Ответ Drive; HTTP=\(status); bytes=\(downloadedBytes); seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: downloadedURL)
            VDriveDiagnosticLog.shared.write("ERROR", "HTTP ошибка скачивания; status=\(status)")
            throw DriveError.server("Не удалось скачать " + name)
        }
        let destination = directory.appendingPathComponent(name)
        let staging = directory.appendingPathComponent("." + UUID().uuidString + ".vdrive-part")
        defer { try? FileManager.default.removeItem(at: downloadedURL); try? FileManager.default.removeItem(at: staging) }
        VDriveDiagnosticLog.shared.write("DECRYPT", "Начало; bytes=\(downloadedBytes)")
        do {
            progress(0, remoteSize, 0)
            try await Task.detached(priority: .utility) {
                try VDriveCrypto.decryptFile(at: downloadedURL, to: staging, key: key) { done, total, speed in
                    DispatchQueue.main.async { progress(done, total, speed) }
                }
            }.value
        } catch {
            VDriveDiagnosticLog.shared.write("ERROR", "Расшифровка: \(error.localizedDescription)")
            throw error
        }
        VDriveDiagnosticLog.shared.write("DECRYPT", "Завершено; seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        VDriveCrypto.markLocalPlaintextFile(destination)
        VDriveDiagnosticLog.shared.write("DOWNLOAD", "Сохранено; localBytes=\((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0); totalSeconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
    }

    func downloadThumbnail(named name: String) async throws -> Data? {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "1"),
            URLQueryItem(name: "q", value: "name = '" + name + "' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]
        var listRequest = URLRequest(url: components.url!)
        listRequest.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
        guard let listHTTP = listResponse as? HTTPURLResponse, (200..<300).contains(listHTTP.statusCode) else {
            throw DriveError.server(String(data: listData, encoding: .utf8) ?? "Не удалось найти миниатюру в Google Drive")
        }
        guard let remote = try JSONDecoder().decode(DriveFileList.self, from: listData).files.first else { return nil }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/" + remote.id + "?alt=media")!)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server("Не удалось скачать миниатюру из Google Drive")
        }
        return data
    }

    func downloadMissing(to directory: URL, localNames: Set<String>, key: SymmetricKey, progress: @escaping (Int64, Int64, Double) -> Void = { _, _, _ in }) async throws -> Int {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "q", value: "trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size)")
        ]
        var listRequest = URLRequest(url: components.url!)
        listRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
        guard let listHTTP = listResponse as? HTTPURLResponse, (200..<300).contains(listHTTP.statusCode) else {
            throw DriveError.server(String(data: listData, encoding: .utf8) ?? "Не удалось получить список Google Drive")
        }
        let remote = try JSONDecoder().decode(DriveFileList.self, from: listData).files
        var map = fileIDs
        for item in remote where item.name.hasSuffix(".vdrive") { map[item.name] = item.id }
        fileIDs = map
        let diskNames = Set(((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "vdrive" }.map { $0.lastPathComponent })
        var existingNames = localNames.union(diskNames)
        let pending = remote.filter { $0.name.hasSuffix(".vdrive") && !existingNames.contains($0.name) }
        VDriveDiagnosticLog.shared.write("SYNC", "Файлов в облаке=\(remote.count); отсутствуют локально=\(pending.count)")
        var count = 0
        for item in pending {
            let destination = directory.appendingPathComponent(item.name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { existingNames.insert(item.name); continue }
            VDriveDiagnosticLog.shared.write("SYNC", "Очередь: \(item.name); cloudBytes=\(item.size ?? "unknown")")
            try await downloadFile(driveID: item.id, name: item.name, to: directory, key: key, progress: progress)
            existingNames.insert(item.name)
            count += 1
            VDriveDiagnosticLog.shared.write("SYNC", "Завершён файл \(item.name); \(count)/\(pending.count)")
        }
        return count
    }
    private func deleteDriveFile(named name: String) async throws {
        try await ensureAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "q", value: "name = '" + name.replacingOccurrences(of: "'", with: "\\'") + "' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]
        var listRequest = URLRequest(url: components.url!)
        listRequest.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: listRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server("Не удалось найти облачный файл " + name)
        }
        let matches = try JSONDecoder().decode(DriveFileList.self, from: data).files
        for item in matches {
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/" + item.id)!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
            let (_, deleteResponse) = try await URLSession.shared.data(for: request)
            guard let http = deleteResponse as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
                throw DriveError.deleteFailed
            }
        }
    }

    func delete(id: String) async throws {
        try await ensureAccessToken()
        if let driveID = fileIDs[id] {
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(driveID)")!)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
                throw DriveError.deleteFailed
            }
        } else {
            // Inventory can be stale after reconnect; resolve by name instead of silently doing nothing.
            try await deleteDriveFile(named: id)
        }
        // Remove encrypted thumbnail sidecars as well; otherwise orphaned previews remain in Drive.
        try await deleteDriveFile(named: id + ".vthumb")
        try await deleteDriveFile(named: id + ".vthumb2")
        var map = fileIDs
        map.removeValue(forKey: id)
        fileIDs = map
    }

    func disconnect() {
        accessToken = ""
        deleteKeychain()
        VDriveDiagnosticLog.shared.write("AUTH", "Google Drive отключён пользователем")
    }

    private func ensureAccessToken() async throws {
        if !accessToken.isEmpty { return }
        guard let refresh = readKeychain() else { VDriveDiagnosticLog.shared.write("AUTH", "Refresh token отсутствует в Keychain"); throw DriveError.needsLogin }
        VDriveDiagnosticLog.shared.write("AUTH", "Обновление access token сохранённым refresh token")
        if clientID.isEmpty {
            clientID = UserDefaults.standard.string(forKey: "googleClientID") ?? "15564278108-3npmd22j8obehjl19rpbpeeldlg2bn3k.apps.googleusercontent.com"
        }
        guard !clientID.isEmpty else { throw DriveError.needsLogin }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DriveError.server(String(data: data, encoding: .utf8) ?? "Token refresh error")
        }
        accessToken = try JSONDecoder().decode(TokenResponse.self, from: data).access_token
        VDriveDiagnosticLog.shared.write("AUTH", "Access token обновлён; HTTP \(http.statusCode)")
    }

    private func readKeychain() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: tokenAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveKeychain(_ value: String) throws {
        deleteKeychain()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: tokenAccount, kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw DriveError.keychain(status) }
    }

    private func deleteKeychain() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: tokenAccount] as CFDictionary)
    }

    private static var activeSession: ASWebAuthenticationSession?
    private static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
}
private struct DriveFileResponse: Decodable { let id: String; let name: String; let size: String? }
private struct DriveFileMetadata: Decodable { let size: String? }
private struct DriveFileList: Decodable { let files: [DriveFileResponse] }
private struct RemoteFileIDs: Decodable {
    struct Item: Decodable { let id: String }
    let files: [Item]
}
private enum DriveError: LocalizedError {
    case invalidResponse, authFailed, needsLogin, deleteFailed, keychain(OSStatus), server(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Некорректный ответ Google."
        case .authFailed: return "Авторизация Google не завершилась. Проверьте OAuth Client ID и redirect URI."
        case .needsLogin: return "Подключите Google Drive заново."
        case .deleteFailed: return "Google Drive не подтвердил удаление."
        case .keychain(let status): return "Ошибка Keychain: \(status)"
        case .server(let text): return text
        }
    }
}
private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private struct MetalShimmerOverlay: View {
    @State private var moving = false
    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.34),
                    .init(color: .white.opacity(0.82), location: 0.5),
                    .init(color: .white.opacity(0.12), location: 0.62),
                    .init(color: .white.opacity(0), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: proxy.size.width * 0.75)
            .rotationEffect(.degrees(18))
            .offset(x: moving ? proxy.size.width * 1.5 : -proxy.size.width)
            .blendMode(.screen)
            .onAppear {
                withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) { moving = true }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PreviewItem: Identifiable {
    let id: Int
    let name: String
    let url: URL
}

private struct PreviewPresentation: Identifiable {
    let id = UUID()
    let items: [PreviewItem]
    let initialIndex: Int
}

private struct VaultFullscreenViewer: View {
    let items: [PreviewItem]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playhead: Double = 0
    @State private var duration: Double = 0
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var controlsVisible = true

    private var current: PreviewItem? { items.indices.contains(index) ? items[index] : nil }
    private var isVideo: Bool { current.flatMap { UTType(filenameExtension: URL(fileURLWithPath: $0.name).pathExtension)?.conforms(to: .movie) } ?? false }
    private var isImage: Bool { current.flatMap { UTType(filenameExtension: URL(fileURLWithPath: $0.name).pathExtension)?.conforms(to: .image) } ?? false }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let current {
                if isImage, let image = UIImage(contentsOfFile: current.url.path) {
                    GeometryReader { proxy in
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(zoom)
                            .gesture(MagnificationGesture().onChanged { value in zoom = min(max(lastZoom * value, 1), 5) }.onEnded { _ in lastZoom = zoom })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() } }
                    }
                } else if isVideo {
                    if let player {
                        NativeAVPlayerView(player: player)
                            .ignoresSafeArea()
                    } else {
                        ProgressView().tint(.white)
                    }
                } else {
                    QuickLookDocumentView(url: current.url)
                }
            }
            // Native AVPlayerViewController owns the entire video UI.
            // Do not place VDrive's close/title/counter overlay over its controls.
            if controlsVisible && !isVideo {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        viewerButton("xmark", label: "Закрыть") { dismiss() }
                        Spacer()
                        Text(current?.name ?? "").font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.white)
                        Spacer()
                        Text(items.isEmpty ? "0 / 0" : "\(index + 1) / \(items.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 18)
                    .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                    if !isVideo {
                        Spacer()
                        HStack {
                            viewerButton("chevron.left", label: "Предыдущий файл") { showPrevious() }
                                .disabled(index == 0).opacity(index == 0 ? 0.3 : 1)
                            Spacer()
                            if isImage { viewerButton("arrow.up.left.and.arrow.down.right", label: "Сбросить масштаб") { withAnimation { zoom = 1; lastZoom = 1 } } }
                            Spacer()
                            viewerButton("chevron.right", label: "Следующий файл") { showNext() }
                                .disabled(index >= items.count - 1).opacity(index >= items.count - 1 ? 0.3 : 1)
                        }
                        .padding(.horizontal, 28).padding(.vertical, 24)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .onAppear { index = min(max(initialIndex, 0), max(items.count - 1, 0)); configurePlayer() }
        .onChange(of: index) { _, _ in configurePlayer() }
        .onDisappear { player?.pause(); player = nil }
    }

    private func viewerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func configurePlayer() {
        player?.pause()
        player = nil
        isPlaying = false
        playhead = 0
        duration = 0
        guard let current, UTType(filenameExtension: URL(fileURLWithPath: current.name).pathExtension)?.conforms(to: .movie) == true else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // AVPlayer still attempts playback; expose the system's normal player controls.
        }
        let newPlayer = AVPlayer(url: current.url)
        newPlayer.isMuted = false
        player = newPlayer
        newPlayer.play()
        isPlaying = true
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }
    private func seek(by offset: Double) {
        guard let player else { return }
        let target = min(max(playhead + offset, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        playhead = target
    }
    private func showPrevious() { guard index > 0 else { return }; index -= 1; zoom = 1; lastZoom = 1 }
    private func showNext() { guard index + 1 < items.count else { return }; index += 1; zoom = 1; lastZoom = 1 }
    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct NativeAVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}

private struct QuickLookDocumentView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct FileImportPicker: UIViewControllerRepresentable {
    let completion: (Result<[URL], Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<[URL], Error>) -> Void
        init(completion: @escaping (Result<[URL], Error>) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.success([]))
        }
    }
}

private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FileExportPicker
        init(_ parent: FileExportPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.isPresented = false
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
