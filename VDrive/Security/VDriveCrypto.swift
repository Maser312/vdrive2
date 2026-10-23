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

private extension Data {
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
