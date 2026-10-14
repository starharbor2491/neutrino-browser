// SPDX-License-Identifier: MPL-2.0
import Foundation
import NeutrinoRust

/// The actor isolates Codable snapshots. Rust owns SQLite, transactions, revision
/// ordering, schema checks, size limits, rollback and WAL checkpointing.
private final class RustDatabaseConnection: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    init(path: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let pointer = path.withCString({ neutrino_database_open($0, &error) }) else {
            try Self.check(error)
            throw ValidationError("Cannot open library.")
        }
        handle = pointer
    }
    deinit { neutrino_database_free(handle) }
    static func check(_ error: UnsafeMutablePointer<CChar>?) throws {
        if let error { defer { neutrino_string_free(error) }; throw ValidationError(String(cString:error)) }
    }
}
public actor LibraryDatabase {
    private let connection: RustDatabaseConnection
    public init(url: URL) throws { connection = try RustDatabaseConnection(path:url.path) }
    public func load() throws -> LibraryState {
        var error: UnsafeMutablePointer<CChar>?
        let data = neutrino_database_load(connection.handle, &error)
        try RustDatabaseConnection.check(error)
        guard let data else { return LibraryState() }
        defer { neutrino_string_free(data) }
        var state = try JSONDecoder().decode(LibraryState.self,from:Data(String(cString:data).utf8))
        state.normalize(); return state
    }
    public func save(_ state: LibraryState, revision: UInt64) throws {
        let data = try JSONEncoder().encode(state)
        let error = data.withUnsafeBytes { bytes in
            neutrino_database_save(connection.handle, bytes.bindMemory(to:UInt8.self).baseAddress, bytes.count, revision)
        }
        try RustDatabaseConnection.check(error)
    }
    /// Debounced UI saves normalize on this serial actor, never concurrently on
    /// the interactive actor. Superseded queued snapshots do no transform work.
    public func saveNormalized(_ state: LibraryState, revision: UInt64) throws {
        try Task.checkCancellation()
        var snapshot = state; snapshot.normalize()
        try Task.checkCancellation()
        try save(snapshot, revision: revision)
    }
    public func checkpoint() throws { try RustDatabaseConnection.check(neutrino_database_checkpoint(connection.handle)) }
}
