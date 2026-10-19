// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import NeutrinoCore

/// Erases one UUID-named profile through directory descriptors. No child path
/// follows a symbolic link, even if another process replaces an entry mid-walk.
enum ChromiumProfileData {
    static func erase(profileID: UUID, dataDirectory: URL) throws {
        guard dataDirectory.isFileURL else { throw ValidationError("The Chromium data location is not a local directory.") }
        let root = open(dataDirectory.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if root < 0 {
            if errno == ENOENT { return }
            throw failure()
        }
        defer { close(root) }
        guard let chromium = try directory("Chromium", relativeTo: root) else { return }
        defer { close(chromium) }
        guard let profiles = try directory("Profiles", relativeTo: chromium) else { return }
        defer { close(profiles) }
        let name = profileID.uuidString
        guard let profile = try directory(name, relativeTo: profiles) else { return }
        defer { close(profile) }
        try eraseContents(profile)
        guard unlinkat(profiles, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw failure() }
    }
    /// Cookies and site storage in a Chromium profile folder, for "Clear when Neutrino quits".
    static let siteDataEntries = [
        "Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal",
        "Local Storage", "Session Storage", "IndexedDB", "Service Worker", "File System", "databases",
        "WebStorage", "Shared Dictionary", "SharedStorage", "SharedStorage-wal", "blob_storage",
        "Network/Trust Tokens", "Network/Trust Tokens-journal", "Network/Reporting and NEL", "Network/Reporting and NEL-journal",
    ]
    static let cacheEntries = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    /// Removes named files and folders inside one profile without following symbolic
    /// links. Bookmarks, extensions and settings stay. Call only while Chromium is stopped.
    static func eraseEntries(_ paths: [String], profileID: UUID, dataDirectory: URL) throws {
        guard dataDirectory.isFileURL else { throw ValidationError("The Chromium data location is not a local directory.") }
        let root = open(dataDirectory.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if root < 0 {
            if errno == ENOENT { return }
            throw failure()
        }
        defer { close(root) }
        guard let chromium = try directory("Chromium", relativeTo: root) else { return }
        defer { close(chromium) }
        guard let profiles = try directory("Profiles", relativeTo: chromium) else { return }
        defer { close(profiles) }
        guard let profile = try directory(profileID.uuidString, relativeTo: profiles) else { return }
        defer { close(profile) }
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { continue }
            var parent = dup(profile)
            guard parent >= 0 else { throw failure() }
            defer { close(parent) }
            var found = true
            for component in components.dropLast() {
                guard let next = try directory(component, relativeTo: parent) else { found = false; break }
                close(parent); parent = next
            }
            if found { try removeEntry(name, in: parent) }
        }
    }
    private static func removeEntry(_ name: String, in parent: Int32) throws {
        var metadata = stat()
        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw failure()
        }
        if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
            guard let child = try directory(name, relativeTo: parent) else { return }
            do { try eraseContents(child) } catch { close(child); throw error }
            close(child)
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw failure() }
        } else {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw failure() }
        }
    }
    private static func directory(_ name: String, relativeTo parent: Int32) throws -> Int32? {
        let result = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if result >= 0 { return result }
        if errno == ENOENT { return nil }
        throw failure()
    }
    private static func eraseContents(_ descriptor: Int32) throws {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw failure() }
        guard let stream = fdopendir(copy) else { close(copy); throw failure() }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw failure() }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            var metadata = stat()
            if fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw failure()
            }
            if (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                guard let child = try directory(name, relativeTo: descriptor) else { continue }
                do { try eraseContents(child) } catch { close(child); throw error }
                close(child)
                guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw failure() }
            } else {
                // Includes symbolic links: remove the entry, never its target.
                guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else { throw failure() }
            }
        }
    }
    private static func failure() -> ValidationError {
        ValidationError("Chromium profile data could not be erased safely (\(String(cString: strerror(errno)))). The pending deletion can be retried from Settings.")
    }
}
