import Foundation
import CryptoKit
import Security

enum VDriveCrypto {
    private static let account = "app.vdrive.dev-key"

    private struct CloudKeyRecord: Codable {
        let format: String
        let version: Int
        let wrappedKey: String
    }

    static func localKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data, bytes.count == 32 else {
                throw cryptoError(-25300, "Ключ шифрования повреждён. Новый ключ не создан, чтобы не потерять доступ к файлам.")
            }
            return SymmetricKey(data: bytes)
        }
        // A new key is created only when Keychain confirms that no key exists.
        // Other Keychain errors must never silently replace the key used by existing files.
        guard status == errSecItemNotFound else {
            throw cryptoError(status, "Не удалось прочитать ключ из Keychain. Существующие файлы не изменены.")
        }

        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try storeKey(bytes)
        return SymmetricKey(data: bytes)
    }

    static func existingLocalKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data, bytes.count == 32 else { return nil }
        return bytes
    }

    /// Exports the existing local key for an explicitly authorized Google Drive recovery copy.
    static func localKeyData() throws -> Data {
        try localKey().withUnsafeBytes { Data($0) }
    }

    /// Restores a key copied from this user's private Google Drive appData.
    /// Callers must validate local encrypted files before invoking this method.
    static func restoreDirectKey(_ data: Data) throws {
        guard data.count == 32 else {
            throw cryptoError(-1, "Облачная копия ключа повреждена.")
        }
        try storeKey(data)
    }

    /// Generates a high-entropy secret code and a cloud-only encrypted key record.
    /// The user keeps only the code; the record is stored privately in Google Drive appData.
    static func makeCloudKeyRecord() throws -> (record: Data, code: String) {
        let rawKey = try localKey().withUnsafeBytes { Data($0) }
        let secretBytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let secretKey = SymmetricKey(data: secretBytes)
        let sealed = try AES.GCM.seal(rawKey, using: secretKey)
        guard let combined = sealed.combined else {
            throw cryptoError(-1, "Не удалось подготовить ключ облачного хранилища.")
        }
        let record = CloudKeyRecord(
            format: "VDriveCloudKey",
            version: 1,
            wrappedKey: combined.base64EncodedString()
        )
        return (try JSONEncoder().encode(record), secretBytes.base64URLEncodedString())
    }

    /// Unwraps the cloud vault key without changing the current device key.
    /// This lets the app verify local files before replacing the Keychain key.
    static func cloudKey(from recordData: Data, code: String) throws -> SymmetricKey {
        let record = try JSONDecoder().decode(CloudKeyRecord.self, from: recordData)
        guard record.format == "VDriveCloudKey",
              record.version == 1,
              let secretBytes = Data(base64URLString: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              secretBytes.count == 32,
              let combined = Data(base64Encoded: record.wrappedKey) else {
            throw cryptoError(-1, "Неверный секретный ключ.")
        }

        let secretKey = SymmetricKey(data: secretBytes)
        let box = try AES.GCM.SealedBox(combined: combined)
        let rawKey = try AES.GCM.open(box, using: secretKey)
        guard rawKey.count == 32 else {
            throw cryptoError(-1, "Запись облачного ключа повреждена.")
        }
        return SymmetricKey(data: rawKey)
    }

    /// Restores the vault key only if the user's secret code authenticates the cloud record.
    static func restoreCloudKey(_ recordData: Data, code: String) throws {
        let key = try cloudKey(from: recordData, code: code)
        let rawKey = key.withUnsafeBytes { Data($0) }
        try storeKey(rawKey)
    }

    private static func storeKey(_ bytes: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw cryptoError(status, "Не удалось сохранить ключ в Keychain.")
        }
        var add = query
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw cryptoError(addStatus, "Не удалось сохранить ключ в Keychain.")
        }
    }

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    private static func cryptoError(_ code: OSStatus, _ description: String) -> NSError {
        NSError(domain: "VDriveCrypto", code: Int(code), userInfo: [NSLocalizedDescriptionKey: description])
    }
}


    // Chunked authenticated file format. Keeps peak memory bounded to one chunk
    // instead of loading large videos into RAM. Legacy AES-GCM blobs remain readable.
    private static let fileMagic = Data("VDRCHNK1".utf8)
    private static let defaultFileChunkSize = 1_048_576

    static func encryptFile(at source: URL, to destination: URL, key: SymmetricKey) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let total = UInt64((attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        let chunkSize = UInt32(defaultFileChunkSize)
        var header = fileMagic
        header.appendBigEndian(total)
        header.appendBigEndian(chunkSize)

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        try output.write(contentsOf: header)

        var remaining = total
        var index: UInt64 = 0
        while remaining > 0 {
            let count = Int(min(remaining, UInt64(chunkSize)))
            let plaintext = try readExactly(count, from: input)
            var aad = header
            aad.appendBigEndian(index)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
            guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
            try output.write(contentsOf: combined)
            remaining -= UInt64(count)
            index += 1
        }
        try output.synchronize()
    }

    static func decryptFile(at source: URL, to destination: URL, key: SymmetricKey) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let first = try readExactly(fileMagic.count, from: input)
        guard first == fileMagic else {
            // Older VDrive versions encrypted the complete file as one AES-GCM box.
            // This compatibility path is intentionally isolated; new uploads use chunks.
            let legacy = try Data(contentsOf: source, options: [.mappedIfSafe])
            let plaintext = try open(legacy, key: key)
            try plaintext.write(to: destination, options: [.atomic, .completeFileProtection])
            return
        }

        let rest = try readExactly(12, from: input)
        var header = first
        header.append(rest)
        let total = rest.readBigEndianUInt64(at: 0)
        let chunkSize = rest.readBigEndianUInt32(at: 8)
        guard chunkSize >= 65_536, chunkSize <= 4_194_304 else {
            throw cryptoError(-1, "Формат облачного файла повреждён.")
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".vdrive-decrypt-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            var remaining = total
            var index: UInt64 = 0
            while remaining > 0 {
                let plainCount = Int(min(remaining, UInt64(chunkSize)))
                let sealedCount = plainCount + 28
                let combined = try readExactly(sealedCount, from: input)
                let box = try AES.GCM.SealedBox(combined: combined)
                var aad = header
                aad.appendBigEndian(index)
                let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
                guard plaintext.count == plainCount else {
                    throw cryptoError(-1, "Размер блока облачного файла не совпадает.")
                }
                try output.write(contentsOf: plaintext)
                remaining -= UInt64(plainCount)
                index += 1
            }
            guard try input.read(upToCount: 1) == nil else {
                throw cryptoError(-1, "В облачном файле обнаружены лишние данные.")
            }
            try output.synchronize()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
                throw cryptoError(-1, "Файл оборван или повреждён.")
            }
            result.append(part)
        }
        return result
    }

}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[offset + $1]) }
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(self[offset + $1]) }
    }
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var value = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: value)
    }
}
