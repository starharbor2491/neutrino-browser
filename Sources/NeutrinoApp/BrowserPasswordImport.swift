// SPDX-License-Identifier: MPL-2.0
import CommonCrypto
import Foundation
import NeutrinoCore
import Security

/// Imports saved passwords from a Chromium-family browser on this Mac, as Arc,
/// Brave, Vivaldi and Opera offer during setup. Chromium encrypts each password
/// with a key it keeps in Keychain; macOS asks the person before Neutrino can read it.
enum BrowserPasswordImport {
    /// The Keychain item holding each browser's password key.
    private static let keyServices: [String: (service: String, name: String)] = [
        "chrome": ("Chrome Safe Storage", "Chrome"), "edge": ("Microsoft Edge Safe Storage", "Edge"),
        "brave": ("Brave Safe Storage", "Brave"), "arc": ("Arc Safe Storage", "Arc"),
        "vivaldi": ("Vivaldi Safe Storage", "Vivaldi"), "opera": ("Opera Safe Storage", "Opera"),
        "operagx": ("Opera Safe Storage", "Opera GX"),
    ]

    /// Reads and decrypts the browser's logins away from the main thread, since
    /// macOS may wait for the person to answer its Keychain prompt.
    static func read(source: String) async throws -> (name: String, logins: [(origin: String, username: String, password: String)]) {
        guard let key = keyServices[source] else { throw ValidationError("Importing passwords from that browser isn’t supported.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = try RustCore.request(["op": "browserLogins", "source": source, "home": home]) as? [[String: Any]] ?? []
        guard !found.isEmpty else { throw ValidationError("\(key.name) has no saved passwords on this Mac.") }
        let rows = found.compactMap { row -> (String, String, Data)? in
            guard let origin = row["origin"] as? String, let username = row["username"] as? String,
                  let encrypted = (row["encrypted"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return (origin, username, encrypted)
        }
        let service = key.service
        let logins = try await Task.detached(priority: .userInitiated) { () throws -> [(origin: String, username: String, password: String)] in
            guard let secret = keychainSecret(service: service) else {
                throw ValidationError("Neutrino couldn’t use \(key.name)’s password key. Allow access when macOS asks, or export a CSV from \(key.name) instead.")
            }
            guard let aesKey = derivedKey(secret) else { throw ValidationError("\(key.name)’s password key couldn’t be used.") }
            return rows.compactMap { origin, username, encrypted in
                decrypt(encrypted, key: aesKey).map { (origin, username, $0) }
            }
        }.value
        guard !logins.isEmpty else { throw ValidationError("\(key.name)’s passwords use encryption Neutrino can’t read. Export a CSV from \(key.name) instead.") }
        return (key.name, logins)
    }

    private static func keychainSecret(service: String) -> Data? {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Chromium on macOS: PBKDF2-HMAC-SHA1 over the Keychain secret with salt "saltysalt", 1003 rounds, 16 bytes.
    static func derivedKey(_ secret: Data) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            secret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), secretBytes.baseAddress?.assumingMemoryBound(to: Int8.self), secret.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return Int(status) == kCCSuccess ? key : nil
    }

    /// A "v10" value: AES-128-CBC with an IV of sixteen spaces.
    static func decrypt(_ value: Data, key: Data) -> String? {
        guard value.count > 3, value.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = Data(value.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, cipher.count,
                                out.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        guard Int(status) == kCCSuccess else { return nil }
        return String(data: output.prefix(moved), encoding: .utf8)
    }
}
