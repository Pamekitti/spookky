import Foundation
import GRDB
import SpookkyCore
import SpookkyWorkspace

public actor WorkspaceDatabase: WorkspacePersistence {
    private let queue: DatabaseQueue
    public init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try PrivateFiles.directory(directory)
        queue = try DatabaseQueue(path: path)
        let needsBackup = try queue.read { db in
            try db.tableExists("workspace_snapshot") && (Int.fetchOne(db, sql: "SELECT version FROM workspace_snapshot WHERE id = 1") ?? 4) < 4
        }
        if needsBackup {
            let backupPath = path + ".pre-v4-" + UUID().uuidString + ".sqlite"
            let backup = try DatabaseQueue(path: backupPath)
            try queue.backup(to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("workspace-v1") { db in
            try db.create(table: "workspace_snapshot") { table in
                table.column("id", .integer).primaryKey()
                table.column("version", .integer).notNull()
                table.column("payload", .blob).notNull()
            }
        }
        migrator.registerMigration("workspace-v2") { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return }
            guard row["version"] as Int == 1 else {
                if row["version"] as Int == 2 { return }
                throw LaunchError.invalid("This database requires a newer Spookky version.")
            }
            var state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 1 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate()
            state.migrateLocations()
            try state.validate()
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 2, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        migrator.registerMigration("workspace-v3") { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return }
            guard row["version"] as Int == 2 else { throw LaunchError.invalid("This database requires a newer Spookky version.") }
            var state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 2 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate(); state.version = 3; try state.validate()
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 3, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        migrator.registerMigration("workspace-v4") { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return }
            guard row["version"] as Int == 3 else { throw LaunchError.invalid("This database requires a newer Spookky version.") }
            var state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 3 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate(); state.migrateWorkspaceNames(); try state.validate()
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 4, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        try migrator.migrate(queue)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    public func load() async throws -> WorkspaceState? {
        try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return nil }
            guard row["version"] as Int == 4 else { throw LaunchError.invalid("This workspace database was written by a newer Spookky version. The file was preserved.") }
            let state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 4 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate(); return state
        }
    }
    public func save(_ state: WorkspaceState) async throws {
        guard state.version == 4 else { throw LaunchError.invalid("Workspace metadata must be migrated before saving.") }
        try state.validate()
        let payload = try JSONEncoder().encode(state)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO workspace_snapshot(id, version, payload) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET version = excluded.version, payload = excluded.payload",
                           arguments: [state.version, payload])
        }
    }
}
