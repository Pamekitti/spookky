import Foundation
import Darwin
import SpookkyCore
import SpookkyFiles

public enum ChangeGroup: String, Codable, Sendable, CaseIterable { case staged = "Staged", unstaged = "Unstaged", untracked = "Untracked", conflicts = "Conflicts", committed = "Committed" }
public struct ChangedFile: Sendable, Equatable, Identifiable {
    public let path: String
    public let oldPath: String?
    public let group: ChangeGroup
    public let status: String
    public let supported: Bool
    public var id: String { group.rawValue + ":" + path }
    public init(path: String, oldPath: String? = nil, group: ChangeGroup, status: String, supported: Bool = true) {
        self.path = path; self.oldPath = oldPath; self.group = group; self.status = status; self.supported = supported
    }
}
public struct ChangesSnapshot: Sendable {
    public let generation = UUID()
    public let files: [ChangedFile]
    public let head: String?
    public let base: String?
    public let reference: String?
    public let fingerprint: Data
    public let notice: String?
    public let indexPath: String
    public let indexSignature: String
    public let referenceCommit: String?
}
public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case context, addition, removal, header, notice }
    public let kind: Kind
    public let old: Int?
    public let new: Int?
    public let text: String
    public init(_ kind: Kind, old: Int? = nil, new: Int? = nil, text: String) { self.kind = kind; self.old = old; self.new = new; self.text = text }
}
public struct TextDiff: Sendable {
    public let lines: [DiffLine]
    public let notice: String?
    public var timings: [String: Double] = [:]
    public var worktreeSignature: String? = nil
    public var cost: Int { lines.reduce(0) { $0 + $1.text.utf8.count * 2 + 128 } }
}
public struct DiffSources: Sendable {
    public let old: String?
    public let new: String?
    public let notice: String?
}
public enum ChangesError: LocalizedError {
    case changed, unsupported(String)
    public var errorDescription: String? {
        switch self { case .changed: return "Files changed during this read. Refresh to inspect the latest version."
        case .unsupported(let value): return value }
    }
}
public struct GitChanges: Sendable {
    public let git: GitRepository
    private let readOptions: [String]?
    public init(git: GitRepository = GitRepository(executor: NativeGitExecutor(timeout: 15, outputLimit: 4 * 1024 * 1024))) { self.git = git; self.readOptions = nil }
    private init(git: GitRepository, options: [String]) { self.git = git; self.readOptions = options }
    private func prepared(_ root: String) async throws -> GitChanges {
        let result = try await git.command(root, ["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"])
        guard !result.truncated, result.status == 0 || result.status == 1 else { _ = try result.checked(); throw ChangesError.unsupported("Cannot inspect Git content filters safely.") }
        var options = ["-c", "core.fsmonitor=false"]
        for item in result.outputData.split(separator: 0) {
            guard let key = String(data: Data(item), encoding: .utf8) else { throw ChangesError.unsupported("Unsupported Git filter configuration.") }
            options += ["-c", key + (key.hasSuffix(".required") ? "=false" : "=")]
        }
        return GitChanges(git: git, options: options)
    }
    private func read(_ root: String, _ arguments: [String]) async throws -> GitResult {
        let result = try await git.command(root, (readOptions ?? []) + ["--literal-pathspecs", "-c", "core.quotePath=false", "-c", "color.ui=false"] + arguments)
        try result.validate(); return result
    }
    public func fingerprint(_ root: String) async throws -> Data {
        if readOptions == nil { return try await prepared(root).fingerprint(root) }
        let status = try await read(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=dirty"])
        let head = try await git.command(root, ["rev-parse", "--verify", "HEAD"])
        var value = status.outputData; value.append(0); value.append(head.outputData)
        let index = try await read(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
        let path = index.output.trimmingCharacters(in: .newlines)
        value.append(Data(Self.signature(path).utf8))
        return value
    }
    public func snapshot(root: String, reference: String? = nil) async throws -> ChangesSnapshot {
        if readOptions == nil { return try await prepared(root).snapshot(root: root, reference: reference) }
        let before = try await fingerprint(root)
        let status = try await read(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=dirty"])
        let headResult = try await git.command(root, ["rev-parse", "--verify", "HEAD"])
        let head = headResult.status == 0 ? headResult.output.trimmingCharacters(in: .newlines) : nil
        var base: String?, referenceCommit: String?, files: [ChangedFile]
        if let reference {
            guard let head else { throw ChangesError.unsupported("This repository has no commits yet. Use Uncommitted to inspect its files.") }
            let resolved = try await git.resolve(root, reference: reference)
            referenceCommit = resolved
            let merge = try await git.command(root, ["merge-base", resolved, head])
            if merge.status == 1 { throw ChangesError.unsupported("These branches have no common ancestor. Choose another comparison branch.") }
            base = try merge.checked().trimmingCharacters(in: .newlines)
            files = try Self.parseNames(try await read(root, ["diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", base!, head, "--"]).outputData)
            guard try await git.resolve(root, reference: reference) == resolved else { throw ChangesError.changed }
        } else { files = try Self.parseStatus(status.outputData) }
        guard before == (try await fingerprint(root)) else { throw ChangesError.changed }
        let hasSubmodules = FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".gitmodules"))
        let notice = [hasSubmodules ? "Submodule commits are compared. Open submodules as workspaces to inspect nested file edits." : nil,
                      (readOptions?.count ?? 0) > 2 ? "External Git content filters are disabled." : nil].compactMap { $0 }.joined(separator: "\n")
        let indexPath = try await read(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"]).output.trimmingCharacters(in: .newlines)
        let indexSignature = Self.signature(indexPath)
        guard before == (try await fingerprint(root)) else { throw ChangesError.changed }
        return ChangesSnapshot(files: files, head: head, base: base, reference: reference, fingerprint: before, notice: notice.isEmpty ? nil : notice, indexPath: indexPath, indexSignature: indexSignature, referenceCommit: referenceCommit)
    }
    private static func path(_ bytes: Data) -> (String, Bool) {
        if let value = String(data: bytes, encoding: .utf8) { return (value, true) }
        return ("Unsupported filename [" + bytes.map { String(format: "%02x", $0) }.joined() + "]", false)
    }
    public static func parseStatus(_ data: Data) throws -> [ChangedFile] {
        // Data slices retain source indices. Normalize before reading record offsets.
        let tokens = data.split(separator: UInt8(0)).map { (chunk: Data) in Data(chunk) }
        var index = 0, files: [ChangedFile] = [], cost = 0
        while index < tokens.count {
            try Task.checkCancellation()
            let record = tokens[index]; index += 1
            guard record.count >= 4, record[2] == 32 else { throw ChangesError.unsupported("Invalid Git status response.") }
            let x = Character(UnicodeScalar(record[0])), y = Character(UnicodeScalar(record[1]))
            let (name, valid) = path(Data(record.dropFirst(3)))
            var old: String?, oldValid = true
            if x == "R" || x == "C" || y == "R" || y == "C" {
                guard index < tokens.count else { throw ChangesError.unsupported("Incomplete Git rename response.") }
                (old, oldValid) = path(tokens[index]); index += 1
            }
            guard cost < 4 * 1024 * 1024 else { throw ChangesError.unsupported("Change list exceeds the metadata limit. Inspect this repository in Terminal.") }
            let pair = String([x, y])
            func append(_ group: ChangeGroup, _ status: String) {
                let oldBytes = old?.utf8.count ?? 0
                cost += (name.utf8.count + oldBytes) * 2 + 512
                files.append(ChangedFile(path: name, oldPath: old, group: group, status: status, supported: valid && oldValid))
            }
            if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair) { append(.conflicts, "Conflict") }
            else if pair == "??" { append(.untracked, "Added") }
            else {
                if x != " " && x != "?" { append(.staged, String(x)) }
                if y != " " && y != "?" { append(.unstaged, String(y)) }
            }
        }
        return files
    }
    public static func parseNames(_ data: Data) throws -> [ChangedFile] {
        let tokens = data.split(separator: UInt8(0)).map { (chunk: Data) in Data(chunk) }
        var index = 0, files: [ChangedFile] = [], cost = 0
        while index < tokens.count {
            let status = String(decoding: tokens[index], as: UTF8.self); index += 1
            guard index < tokens.count else { throw ChangesError.unsupported("Incomplete Git comparison response.") }
            var (name, valid) = path(tokens[index]); index += 1
            var old: String?
            if status.hasPrefix("R") || status.hasPrefix("C") {
                old = name
                guard index < tokens.count else { throw ChangesError.unsupported("Incomplete Git rename response.") }
                let next = path(tokens[index]); index += 1; name = next.0; valid = valid && next.1
            }
            let oldBytes = old?.utf8.count ?? 0
            cost += (name.utf8.count + oldBytes) * 2 + 512
            guard cost <= 4 * 1024 * 1024 else { throw ChangesError.unsupported("Change list exceeds the metadata limit. Inspect this repository in Terminal.") }
            files.append(ChangedFile(path: name, oldPath: old, group: .committed, status: status, supported: valid))
        }
        return files
    }
    public func diff(root: String, file: ChangedFile, snapshot: ChangesSnapshot, context: Int = 3) async throws -> TextDiff {
        if readOptions == nil {
            let started = ProcessInfo.processInfo.systemUptime
            let reader = try await prepared(root)
            let preparedAt = ProcessInfo.processInfo.systemUptime
            var result = try await reader.diff(root: root, file: file, snapshot: snapshot, context: context)
            result.timings["configuration_ms"] = (preparedAt - started) * 1000
            return result
        }
        guard file.supported else { throw ChangesError.unsupported("This filename cannot be represented safely. Inspect it in your terminal.") }
        let started = ProcessInfo.processInfo.systemUptime
        try await validateComparison(root, snapshot)
        let validatedAt = ProcessInfo.processInfo.systemUptime
        let before = fileSignature(root, file.path)
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--submodule=short", "--ignore-submodules=dirty", "--unified=\(min(20_000, max(3, context)))"]
        switch file.group {
        case .staged: args += ["--cached"]
        case .committed: guard let base = snapshot.base, let head = snapshot.head else { throw ChangesError.changed }; args += [base, head]
        case .unstaged: break
        case .untracked, .conflicts: throw ChangesError.unsupported("Open working-file content for this entry.")
        }
        args += ["--", file.path]; if let old = file.oldPath { args.append(old) }
        let result = try await read(root, args)
        let readAt = ProcessInfo.processInfo.systemUptime
        try await validateComparison(root, snapshot)
        guard before == fileSignature(root, file.path) else { throw ChangesError.changed }
        let checkedAt = ProcessInfo.processInfo.systemUptime
        guard let text = String(data: result.outputData, encoding: .utf8) else { return TextDiff(lines: [], notice: "Unsupported text encoding. Open in an editor.") }
        let parsed = Self.parsePatch(text)
        return TextDiff(lines: parsed.lines, notice: [parsed.notice, (readOptions?.count ?? 0) > 2 ? "External Git content filters are disabled for this preview." : nil].compactMap { $0 }.joined(separator: "\n"), timings: ["validate_before_ms": (validatedAt - started) * 1000, "patch_read_ms": (readAt - validatedAt) * 1000, "validate_after_ms": (checkedAt - readAt) * 1000, "parse_ms": (ProcessInfo.processInfo.systemUptime - checkedAt) * 1000], worktreeSignature: before)
    }
    public func sources(root: String, file: ChangedFile, snapshot: ChangesSnapshot, expectedWorktreeSignature: String?) async throws -> DiffSources {
        if readOptions == nil { return try await prepared(root).sources(root: root, file: file, snapshot: snapshot, expectedWorktreeSignature: expectedWorktreeSignature) }
        guard file.supported else { throw ChangesError.unsupported("Unsupported filename.") }
        try await validateComparison(root, snapshot)
        let before = fileSignature(root, file.path)
        if let expectedWorktreeSignature, expectedWorktreeSignature != before { throw ChangesError.changed }
        let oldPath = file.oldPath ?? file.path
        let oldObject: String?
        let newObject: String?
        switch file.group {
        case .staged:
            oldObject = file.status.hasPrefix("A") ? nil : snapshot.head.map { $0 + ":" + oldPath }
            newObject = file.status.hasPrefix("D") ? nil : ":" + file.path
        case .committed:
            oldObject = file.status.hasPrefix("A") ? nil : snapshot.base.map { $0 + ":" + oldPath }
            newObject = file.status.hasPrefix("D") ? nil : snapshot.head.map { $0 + ":" + file.path }
        case .unstaged:
            oldObject = ":" + file.path; newObject = nil
        case .untracked, .conflicts: throw ChangesError.unsupported("Use working-file content for this entry.")
        }
        async let old = blob(root, object: oldObject)
        async let new = file.group == .unstaged ? workingSource(root, path: file.path, deleted: file.status.hasPrefix("D")) : blob(root, object: newObject)
        let pair = try await (old, new)
        try await validateComparison(root, snapshot)
        guard before == fileSignature(root, file.path) else { throw ChangesError.changed }
        let notice = [pair.0.notice, pair.1.notice].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let newAbsent = file.group == .unstaged ? file.status.hasPrefix("D") : newObject == nil
        return DiffSources(old: oldObject == nil || pair.0.limited ? nil : pair.0.text,
                           new: newAbsent || pair.1.limited ? nil : pair.1.text, notice: notice.isEmpty ? nil : notice)
    }
    private func blob(_ root: String, object: String?) async throws -> FilePreview {
        guard let object else { return FilePreview() }
        let result = try await read(root, ["cat-file", "blob", object])
        return FileService.decode(result.outputData)
    }
    private func workingSource(_ root: String, path: String, deleted: Bool) async throws -> FilePreview {
        if deleted { return FilePreview() }
        return try await FileService().preview(root: root, path: path)
    }
    private func validateComparison(_ root: String, _ snapshot: ChangesSnapshot) async throws {
        let result = try await git.command(root, ["rev-parse", "--verify", "HEAD"])
        guard !result.truncated else { throw ChangesError.changed }
        let head = result.status == 0 ? result.output.trimmingCharacters(in: .newlines) : nil
        guard head == snapshot.head, Self.signature(snapshot.indexPath) == snapshot.indexSignature else { throw ChangesError.changed }
        if let reference = snapshot.reference, let expected = snapshot.referenceCommit {
            guard try await git.resolve(root, reference: reference) == expected else { throw ChangesError.changed }
        }
    }
    public func conflictStage(root: String, file: ChangedFile, stage: Int) async throws -> Data {
        guard file.supported, (1...3).contains(stage) else { throw ChangesError.unsupported("Unavailable conflict stage.") }
        return try await read(root, ["show", ":\(stage):" + file.path]).outputData
    }
    private func fileSignature(_ root: String, _ path: String) -> String {
        Self.signature((root as NSString).appendingPathComponent(path))
    }
    private static func signature(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "missing" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    public static func parsePatch(_ text: String) -> TextDiff {
        var rows: [DiffLine] = [], old = 0, new = 0, inHunk = false, bytes = 0
        let pattern = try! NSRegularExpression(pattern: "^@@ -([0-9]+)(?:,[0-9]+)? \\+([0-9]+)(?:,[0-9]+)? @@")
        for slice in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(slice); bytes += line.utf8.count
            if bytes > 2 * 1024 * 1024 || rows.count >= 20_000 { return TextDiff(lines: rows, notice: "Diff preview limited to 2 MiB or 20,000 lines.") }
            if line.hasPrefix("@@ "), let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                old = Int((line as NSString).substring(with: match.range(at: 1)))!; new = Int((line as NSString).substring(with: match.range(at: 2)))!
                rows.append(DiffLine(.header, text: line)); inHunk = true
            } else if inHunk, line.hasPrefix("+") { rows.append(DiffLine(.addition, new: new, text: String(line.dropFirst()))); new += 1 }
            else if inHunk, line.hasPrefix("-") { rows.append(DiffLine(.removal, old: old, text: String(line.dropFirst()))); old += 1 }
            else if inHunk, line.hasPrefix(" ") { rows.append(DiffLine(.context, old: old, new: new, text: String(line.dropFirst()))); old += 1; new += 1 }
            else if !line.isEmpty && !line.hasPrefix("diff --git ") && !line.hasPrefix("index ") && !line.hasPrefix("--- ") && !line.hasPrefix("+++ ") { rows.append(DiffLine(.notice, text: line)) }
        }
        return TextDiff(lines: rows, notice: nil)
    }
}
