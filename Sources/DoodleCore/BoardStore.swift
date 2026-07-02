import Foundation

// MARK: - Locked Store (flock for concurrent writers)
// Single-file JSON + exclusive lock around read-modify-write.
// Readers can read without lock (eventual visibility is fine for this use case).

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BoardStoreError: Error, CustomStringConvertible {
    case ioError(String)
    case lockFailed(String)

    public var description: String {
        switch self {
        case .ioError(let m): return "IO error: \(m)"
        case .lockFailed(let m): return "Lock error: \(m)"
        }
    }
}

public enum BoardStore {
    /// Load board (best effort). Creates empty board on first use / missing file.
    public static func load() throws -> Board {
        let url = BoardPath.resolvedURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Board()
        }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return Board() }
            return try JSONDecoder().decode(Board.self, from: data)
        } catch {
            throw BoardStoreError.ioError("Failed to read or decode board at \(url.path): \(error)")
        }
    }

    /// Perform a read-modify-write under exclusive flock.
    /// Use for any mutation (set, rm).
    public static func withLock<T>(_ body: (inout Board) throws -> T) throws -> T {
        let url = BoardPath.resolvedURL
        try BoardPath.ensureParentDirectory()

        // Open (or create) the file for locking + read/write
        let path = url.path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            throw BoardStoreError.lockFailed("Failed to open board file for locking: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        // Acquire exclusive lock (blocks until available)
        let lockResult = flock(fd, LOCK_EX)
        guard lockResult == 0 else {
            throw BoardStoreError.lockFailed("flock(LOCK_EX) failed: \(String(cString: strerror(errno)))")
        }
        defer { flock(fd, LOCK_UN) }

        // Read current (or default)
        var board: Board
        do {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                board = try JSONDecoder().decode(Board.self, from: data)
            } else {
                board = Board()
            }
        } catch {
            // Corrupt? Start fresh but don't lose the lock semantics
            board = Board()
        }

        // Mutate
        let result = try body(&board)

        // Write back atomically under lock
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(board)
        try data.write(to: url, options: .atomic)

        return result
    }

    /// Convenience: load then filter/sort for presentation.
    public static func loadFiltered(status: String? = nil, includeDone: Bool = false) throws -> [DoodleItem] {
        var items = try load().items

        if !includeDone {
            items = items.filter { $0.status != "done" }
        }
        if let status {
            items = items.filter { $0.status == status }
        }

        // Sort: most recent first within groups (presentation can regroup)
        items.sort { $0.updated_at > $1.updated_at }
        return items
    }

    // MARK: - High-level mutators (locked)

    /// Create or update an item by (normalized) name.
    /// Only provided non-nil fields are overwritten for updates.
    /// Always sets updated_at to now and resolves source from env.
    public static func set(
        displayName: String,
        type: String? = nil,
        status: String? = nil,
        summary: String? = nil,
        detail: String? = nil
    ) throws -> DoodleItem {
        let normalized = NameNormalizer.normalize(displayName)
        let now = DoodleDate.nowISO()
        let resolvedSource = resolvedSource()

        return try withLock { board in
            if let idx = board.items.firstIndex(where: { $0.name == normalized }) {
                // Partial update
                var item = board.items[idx]
                item.display_name = displayName  // last casing wins
                if let type { item.type = type }
                if let status { item.status = status }
                if let summary { item.summary = summary }
                if let detail { item.detail = detail.isEmpty ? nil : detail }
                item.source = resolvedSource
                item.updated_at = now
                board.items[idx] = item
                return item
            } else {
                // New item
                let item = DoodleItem(
                    name: normalized,
                    display_name: displayName,
                    type: type ?? "note",
                    status: status ?? "active",
                    summary: summary ?? "",
                    detail: (detail?.isEmpty == false) ? detail : nil,
                    source: resolvedSource,
                    updated_at: now
                )
                board.items.append(item)
                return item
            }
        }
    }

    public static func get(name: String) throws -> DoodleItem? {
        let normalized = NameNormalizer.normalize(name)
        let board = try load()
        return board.items.first { $0.name == normalized }
    }

    public static func remove(name: String) throws -> Bool {
        let normalized = NameNormalizer.normalize(name)
        return try withLock { board in
            let before = board.items.count
            board.items.removeAll { $0.name == normalized }
            return board.items.count < before
        }
    }

    public static func resolvedSource() -> String {
        let env = ProcessInfo.processInfo.environment
        if let s = env["DOODLE_SOURCE"], !s.isEmpty { return s }
        if let a = env["AGENT_NAME"], !a.isEmpty { return a }
        return "unknown"
    }

    /// For pretty printing / humans (used by CLI --pretty and future).
    public static func prettyPrint(items: [DoodleItem]) -> String {
        guard !items.isEmpty else { return "No items." }

        var lines: [String] = []
        let grouped = Dictionary(grouping: items, by: { $0.status })
        let order = ["waiting_on_user", "active", "blocked", "done"]

        for key in order {
            guard let group = grouped[key], !group.isEmpty else { continue }
            let title: String
            switch key {
            case "waiting_on_user": title = "Waiting on You"
            case "active": title = "Active"
            case "blocked": title = "Blocked"
            case "done": title = "Done"
            default: title = key.capitalized
            }
            lines.append("\(title):")
            for item in group.sorted(by: { $0.updated_at > $1.updated_at }) {
                let age = DoodleDate.relative(from: item.updated_at)
                let detailLine = item.detail.map { "\n    \($0)" } ?? ""
                lines.append("  • \(item.display_name) [\(item.type)] — \(item.summary)  (\(item.source), \(age))\(detailLine)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
