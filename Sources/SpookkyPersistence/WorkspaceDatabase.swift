import Foundation
import GRDB
import SpookkyCore
import SpookkyWorkspace

public actor WorkspaceDatabase: WorkspacePersistence, HistoryCatalogPersistence {
    private let queue: DatabaseQueue
    public init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try PrivateFiles.directory(directory)
        queue = try DatabaseQueue(path: path)
        let needsBackup = try queue.read { db in
            try db.tableExists("workspace_snapshot") && (Int.fetchOne(db, sql: "SELECT version FROM workspace_snapshot WHERE id = 1") ?? 8) < 8
        }
        if needsBackup {
            let oldVersion = try queue.read { try Int.fetchOne($0, sql: "SELECT version FROM workspace_snapshot WHERE id = 1") ?? 7 }
            let backupPath = path + (oldVersion < 6 ? ".pre-v6-" : oldVersion < 7 ? ".pre-v7-" : ".pre-v8-") + UUID().uuidString + ".sqlite"
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
            try state.validate(); state.version = 4; try state.validate()
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 4, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        migrator.registerMigration("workspace-v5") { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return }
            guard row["version"] as Int == 4 else { throw LaunchError.invalid("This database requires a newer Spookky version.") }
            var state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 4 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate(); state.migrateWorkspaceNames(); state.version = 5; try state.validate()
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 5, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        migrator.registerMigration("workspace-v6") { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return }
            guard row["version"] as Int == 5 else { throw LaunchError.invalid("This database requires a newer Spookky version.") }
            var state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 5 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate(); state.migrateConversationWorkspaces(); try state.validate()
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 6, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        migrator.registerMigration("workspace-v7") { db in
            try db.execute(sql: "CREATE TABLE conversation_catalog (provider TEXT NOT NULL, session_id TEXT NOT NULL, project_id TEXT, directory TEXT NOT NULL, updated_at DOUBLE NOT NULL, search_text TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(provider, session_id))")
            try db.execute(sql: "CREATE INDEX conversation_catalog_recent ON conversation_catalog(project_id, updated_at DESC, provider, session_id)")
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return }
            guard row["version"] as Int == 6 else { throw LaunchError.invalid("This database requires a newer Spookky version.") }
            var state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 6 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate()
            let records = state.migrateHistoryCatalog()
            try state.validate(); try Self.writeHistory(records, in: db)
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 7, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        migrator.registerMigration("workspace-v8") { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return }
            guard row["version"] as Int == 7 else { throw LaunchError.invalid("This database requires a newer Spookky version.") }
            var state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            state.migratePersistentThreads()
            try state.validate()
            try db.execute(sql: "UPDATE workspace_snapshot SET version = 8, payload = ? WHERE id = 1", arguments: [try JSONEncoder().encode(state)])
        }
        try migrator.migrate(queue)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    public func load() async throws -> WorkspaceState? {
        try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT version, payload FROM workspace_snapshot WHERE id = 1") else { return nil }
            guard row["version"] as Int == 8 else { throw LaunchError.invalid("This workspace database was written by a newer Spookky version. The file was preserved.") }
            let state = try JSONDecoder().decode(WorkspaceState.self, from: row["payload"] as Data)
            guard state.version == 8 else { throw LaunchError.invalid("Workspace snapshot version does not match its database record.") }
            try state.validate(); return state
        }
    }
    public func save(_ state: WorkspaceState) async throws {
        guard state.version == 8 else { throw LaunchError.invalid("Workspace metadata must be migrated before saving.") }
        try state.validate()
        let payload = try JSONEncoder().encode(state)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO workspace_snapshot(id, version, payload) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET version = excluded.version, payload = excluded.payload",
                           arguments: [state.version, payload])
        }
    }

    public func history(_ query: StoredHistoryQuery) async throws -> [ConversationCatalogRecord] {
        try await queue.read { db in
            var clauses: [String] = [], arguments = StatementArguments()
            if !query.allProjects {
                if let id = query.projectID { clauses.append("project_id = ?"); arguments += [id.uuidString] }
                else { clauses.append("project_id IS NULL") }
            }
            let search = Self.searchKey(query.search)
            if !search.isEmpty { clauses.append("instr(search_text, ?) > 0"); arguments += [search] }
            let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            arguments += [query.limit, query.offset]
            return try Data.fetchAll(db, sql: "SELECT payload FROM conversation_catalog" + filter + " ORDER BY updated_at DESC, provider, session_id LIMIT ? OFFSET ?", arguments: arguments)
                .map { try JSONDecoder().decode(ConversationCatalogRecord.self, from: $0) }
        }
    }

    public func conversation(_ id: ConversationID) async throws -> ConversationCatalogRecord? {
        try await queue.read { try Self.historyRecord(id, in: $0) }
    }

    public func saveHistory(_ records: [ConversationCatalogRecord]) async throws {
        try await queue.write { try Self.writeHistory(records, in: $0) }
    }
    public func setHistoryAlias(_ id: ConversationID, alias: String) async throws -> ConversationCatalogRecord? {
        try await queue.write { db in
            guard var record = try Self.historyRecord(id, in: db) else { return nil }
            record.localAlias = alias
            try Self.upsertHistory(record, in: db); return record
        }
    }
    public func unassignHistoryProject(_ id: UUID) async throws {
        try await queue.write { db in
            while true {
                let page = try Data.fetchAll(db, sql: "SELECT payload FROM conversation_catalog WHERE project_id = ? LIMIT 100", arguments: [id.uuidString])
                guard !page.isEmpty else { return }
                for data in page {
                    var record = try JSONDecoder().decode(ConversationCatalogRecord.self, from: data)
                    record.projectID = nil; try Self.upsertHistory(record, in: db)
                }
            }
        }
    }
    public func mergeHistoryMetadata(_ records: [ConversationCatalogRecord], preservingProjectFor: Set<ConversationID>,
                                     registeredProjectIDs: Set<UUID>) async throws -> [ConversationCatalogRecord] {
        try await queue.write { db in
            var merged: [ConversationCatalogRecord] = []
            for record in records {
                let previous = try Self.historyRecord(record.id, in: db)
                let next = record.mergingMetadata(over: previous, preservingProject: preservingProjectFor.contains(record.id),
                                                  registeredProjectIDs: registeredProjectIDs)
                try Self.upsertHistory(next, in: db)
                merged.append(next)
            }
            return merged
        }
    }
    public func historyDirectories(projectID: UUID) async throws -> [String] {
        try await queue.read { try String.fetchAll($0, sql: "SELECT DISTINCT directory FROM conversation_catalog WHERE project_id = ? LIMIT 4096", arguments: [projectID.uuidString]) }
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func historyRecord(_ id: ConversationID, in db: Database) throws -> ConversationCatalogRecord? {
        try Data.fetchOne(db, sql: "SELECT payload FROM conversation_catalog WHERE provider = ? AND session_id = ?", arguments: [id.provider.rawValue, id.sessionID])
            .map { try JSONDecoder().decode(ConversationCatalogRecord.self, from: $0) }
    }
    private static func writeHistory(_ records: [ConversationCatalogRecord], in db: Database) throws {
        for var record in records {
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM conversation_catalog WHERE provider = ? AND session_id = ?", arguments: [record.id.provider.rawValue, record.id.sessionID]),
               let previous = try? JSONDecoder().decode(ConversationCatalogRecord.self, from: data) {
                record.localAlias = record.localAlias ?? previous.localAlias
                record.workspaceID = record.workspaceID ?? previous.workspaceID
                record.terminalID = record.terminalID ?? previous.terminalID
            }
            try upsertHistory(record, in: db)
        }
    }
    private static func upsertHistory(_ record: ConversationCatalogRecord, in db: Database) throws {
        let search = searchKey([record.displayTitle, record.metadata.directory, record.id.sessionID].joined(separator: "\n"))
        try db.execute(sql: "INSERT INTO conversation_catalog(provider, session_id, project_id, directory, updated_at, search_text, payload) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(provider, session_id) DO UPDATE SET project_id = excluded.project_id, directory = excluded.directory, updated_at = excluded.updated_at, search_text = excluded.search_text, payload = excluded.payload",
            arguments: [record.id.provider.rawValue, record.id.sessionID, record.projectID?.uuidString, record.metadata.directory, record.metadata.updatedAt.timeIntervalSince1970, search, try JSONEncoder().encode(record)])
    }
}
