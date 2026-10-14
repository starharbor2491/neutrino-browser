// SPDX-License-Identifier: MPL-2.0
import AppKit
import NeutrinoCore
import Security
@preconcurrency import WebKit

/// macOS-only effects. Rust decides the exact file and Keychain scope.
@MainActor
enum AppUninstaller {
    static func request(_ app: AppState) {
        guard app.ready,!app.terminating,!app.finalQuitDataFrozen else{return}
        guard DistributionManager.shared.canUninstall else {
            app.notice = "Finish the pending update, then uninstall Neutrino. This prevents its installer from recreating the application."
            return
        }
        let alert=NSAlert()
        alert.alertStyle = .critical
        alert.messageText="Uninstall Neutrino and erase its data?"
        alert.informativeText="This permanently deletes Neutrino.app, all Profiles, website sign-ins, passwords, tabs, bookmarks, notes, modules, settings, caches, and update files. Files you downloaded or exported stay on your Mac. This cannot be undone."
        alert.addButton(withTitle:"Cancel")
        alert.addButton(withTitle:"Uninstall and erase")
        guard alert.runModal() == .alertSecondButtonReturn else{return}
        guard DistributionManager.shared.canUninstall else {
            app.notice = "Finish the pending update before uninstalling Neutrino."
            return
        }
        do {try validatePaths(plannedPaths(app))}catch{app.notice=error.localizedDescription;return}
        app.uninstallRequested=true
        NSApp.terminate(nil)
    }
    private static func plannedPaths(_ app: AppState) throws -> [URL] {
        let home=FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        guard let paths=try RustCore.request(["op":"uninstallPaths","home":home.path,"dataDirectory":app.dataDirectory.standardizedFileURL.path]) as? [String] else {throw ValidationError("Could not determine Neutrino’s data files.")}
        return paths.map{URL(fileURLWithPath:$0)}
    }
    static func remove(_ app: AppState) async -> [String] {
        var failures=[String]()
        func attempt(_ label: String,_ work: () throws -> Void){do{try work()}catch{failures.append(label+": "+error.localizedDescription)}}
        let paths: [URL]
        do { paths = try plannedPaths(app); try validatePaths(paths) }
        catch { return [error.localizedDescription] }
        ChatGPTAccount.shared.cancelSignIn()
        app.webKitDataStores.removeAll()
        // Engines and workers have exited, and application writes are frozen.
        let identifiers:[UUID]=await withCheckedContinuation {continuation in WKWebsiteDataStore.fetchAllDataStoreIdentifiers {continuation.resume(returning:$0)}}
        for id in identifiers {
            do {try await WebsiteStoreRemoval.remove(id)}catch{failures.append("Website store: "+error.localizedDescription)}
        }
        var services = Set<String>()
        attempt("Keychain inventory") {
            var result:CFTypeRef?
            let status=SecItemCopyMatching([kSecClass as String:kSecClassGenericPassword,kSecReturnAttributes as String:true,kSecMatchLimit as String:kSecMatchLimitAll] as CFDictionary,&result)
            guard status==errSecSuccess || status==errSecItemNotFound else{throw ValidationError("The Keychain could not be inspected.")}
            services=Set((result as? [[String:Any]] ?? []).compactMap{$0[kSecAttrService as String] as? String})
        }
        for service in services where (try? RustCore.request(["op":"uninstallKeychainService","service":service]) as? Bool)==true {
            attempt("Keychain entry") { try SecureVault.delete(service:service) }
        }
        for path in paths {
            attempt(path.lastPathComponent) {
                guard FileManager.default.fileExists(atPath:path.path) else{return}
                try validatePaths([path])
                try FileManager.default.removeItem(at:path)
            }
        }
        UserDefaults.standard.removePersistentDomain(forName:"org.neutrino.browser")
        // Keep the installed application available for a retry if data erasure
        // failed. A partial result must never be reported as a full uninstall.
        guard failures.isEmpty else { return failures }
        attempt("Application") {
            let bundle=Bundle.main.bundleURL.standardizedFileURL
            guard Bundle.main.bundleIdentifier=="org.neutrino.browser",bundle.pathExtension=="app",
                  (try bundle.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])).isDirectory==true,
                  (try bundle.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else {throw ValidationError("This executable is not an installed Neutrino.app.")}
            try FileManager.default.removeItem(at:bundle)
        }
        return failures
    }
    private static func validatePaths(_ paths: [URL]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        for path in paths {
            var ancestor = path
            while ancestor.path != home && ancestor.path != "/" {
                if (try? ancestor.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true {
                    throw ValidationError("Refused a symbolic link in " + path.path)
                }
                ancestor.deleteLastPathComponent()
            }
        }
    }
}
