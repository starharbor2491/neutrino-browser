// SPDX-License-Identifier: MPL-2.0
import CommonCrypto
import CryptoKit
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
        if source == "firefox" { return try await readFirefox() }
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

    /// Firefox keeps its logins encrypted with a key from its own key store, which is
    /// protected by a primary password that is empty unless the person set one.
    private static func readFirefox() async throws -> (name: String, logins: [(origin: String, username: String, password: String)]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let found = try RustCore.request(["op": "firefoxLogins", "home": home]) as? [String: Any] else {
            throw ValidationError("Firefox’s saved passwords use an unsupported format.")
        }
        let logins = try await Task.detached(priority: .userInitiated) { try firefoxDecrypt(found) }.value
        guard !logins.isEmpty else { throw ValidationError("Firefox’s passwords couldn’t be read. Export a CSV from Firefox instead.") }
        return ("Firefox", logins)
    }

    /// Decrypts what Rust read from key4.db and logins.json, as NSS does without a primary password.
    static func firefoxDecrypt(_ found: [String: Any]) throws -> [(origin: String, username: String, password: String)] {
        guard let salt = base64(found["globalSalt"]), let check = found["check"] as? [String: Any],
              let keyItem = found["key"] as? [String: Any] else { throw ValidationError("Firefox’s saved passwords use an unsupported format.") }
        guard pbes2(check, globalSalt: salt) == Data("password-check".utf8) else {
            throw ValidationError("Firefox has a primary password. Export a CSV from Firefox instead.")
        }
        guard let master = pbes2(keyItem, globalSalt: salt), master.count >= 24 else { throw ValidationError("Firefox’s password key couldn’t be used.") }
        return (found["logins"] as? [[String: Any]] ?? []).compactMap { row in
            guard let origin = row["origin"] as? String, let user = row["username"] as? [String: Any], let secret = row["password"] as? [String: Any],
                  let username = firefoxField(user, key: master), let password = firefoxField(secret, key: master), !password.isEmpty else { return nil }
            return (origin, String(username.prefix(500)), String(password.prefix(8192)))
        }
    }

    /// A key-store item: PBKDF2-HMAC-SHA256 over SHA-1(global salt + empty password), then AES-256-CBC.
    static func pbes2(_ item: [String: Any], globalSalt: Data) -> Data? {
        guard let salt = base64(item["salt"]), let iv = base64(item["iv"]), let cipher = base64(item["data"]),
              let iterations = item["iterations"] as? Int, (1...10_000_000).contains(iterations), iv.count == kCCBlockSizeAES128 else { return nil }
        let password = Data(Insecure.SHA1.hash(data: globalSalt))
        var key = Data(count: kCCKeySizeAES256)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES256)
                }
            }
        }
        guard Int(status) == kCCSuccess else { return nil }
        return decrypt(CCAlgorithm(kCCAlgorithmAES), key: key, iv: iv, data: cipher)
    }

    /// A login field: 3DES-CBC with the first 24 bytes of the key, or AES-256-CBC in newer profiles.
    static func firefoxField(_ item: [String: Any], key master: Data) -> String? {
        guard let iv = base64(item["iv"]), let cipher = base64(item["data"]) else { return nil }
        let plain = item["cipher"] as? String == "aes"
            ? (master.count >= kCCKeySizeAES256 ? decrypt(CCAlgorithm(kCCAlgorithmAES), key: master.prefix(kCCKeySizeAES256), iv: iv, data: cipher) : nil)
            : decrypt(CCAlgorithm(kCCAlgorithm3DES), key: master.prefix(kCCKeySize3DES), iv: iv, data: cipher)
        return plain.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decrypt(_ algorithm: CCAlgorithm, key: Data, iv: Data, data: Data) -> Data? {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), algorithm, CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, data.count,
                                out.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        return Int(status) == kCCSuccess ? output.prefix(moved) : nil
    }

    private static func base64(_ value: Any?) -> Data? { (value as? String).flatMap { Data(base64Encoded: $0) } }

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
