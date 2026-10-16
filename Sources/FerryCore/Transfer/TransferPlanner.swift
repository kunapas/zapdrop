import Foundation

/// Expands a selection (files and folders) into a flat, ordered list of folders to create and files to copy.
/// Folder contents are listed one level at a time, so huge trees never need to be held as nested structures.
public struct TransferPlanner: Sendable {
    public let session: DeviceSession
    public let caseInsensitive: Bool
    /// Guard against malformed metadata (loops or absurd depth).
    public var maxDepth = 128

    public init(session: DeviceSession, caseInsensitive: Bool) {
        self.session = session
        self.caseInsensitive = caseInsensitive
    }

    public func plan(_ request: TransferRequest, cancellation: CancellationFlag? = nil,
                     onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> TransferPlan {
        var builder = Builder(caseInsensitive: caseInsensitive)
        var visited = Set<ObjectID>()

        // Depth-first, but using an explicit stack: (item, raw path of its parent, sanitised dir of its parent, depth)
        var stack: [(RemoteItem, [String], [String], Int)] = sortedForCopy(request.items).reversed().map {
            ($0, request.sourceFolderPath, [], 0)
        }
        while let (item, parentRaw, parentDir, depth) = stack.popLast() {
            if Task.isCancelled || cancellation?.isCancelled == true { throw FerryError.cancelled }
            let entry = builder.add(item, remoteParentPath: parentRaw, directory: parentDir)
            onProgress?(builder.entries.count)
            guard item.isFolder else { continue }
            guard depth < maxDepth, visited.insert(item.id).inserted else {
                Log.warning("planner", "Skipping folder loop or excessive depth")
                continue
            }
            let children = try await session.children(of: RemoteLocation(storageID: item.storageID, folderID: item.id))
            let childDir = entry.directory + [entry.name]
            for child in sortedForCopy(children).reversed() {
                stack.append((child, entry.remotePath, childDir, depth + 1))
            }
        }
        return builder.finish()
    }

    /// Files before folders within a level, then by name — keeps the copy order predictable.
    func sortedForCopy(_ items: [RemoteItem]) -> [RemoteItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return !a.isFolder }
            let c = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }

    struct Builder {
        let caseInsensitive: Bool
        var entries: [PlannedEntry] = []
        var reserved: [String: Set<String>] = [:]
        var totalBytes: UInt64 = 0
        var files = 0
        var folders = 0

        mutating func add(_ item: RemoteItem, remoteParentPath: [String], directory: [String]) -> PlannedEntry {
            let dirKey = directory.joined(separator: "/")
            var taken = reserved[dirKey, default: []]
            let clean = FileNameSanitizer.sanitize(item.name)
            var name = clean.name
            var rename: PlannedEntry.Rename? = clean.wasChanged ? .sanitized(original: item.name) : nil
            if taken.contains(key(name)) {
                var n = 1
                repeat {
                    name = FileNameSanitizer.numberedVariant(of: clean.name, number: n)
                    n += 1
                } while taken.contains(key(name))
                rename = .nameClash(original: item.name)
            }
            taken.insert(key(name))
            reserved[dirKey] = taken
            let entry = PlannedEntry(id: entries.count, source: item, remotePath: remoteParentPath + [item.name],
                                     directory: directory, name: name, rename: rename)
            entries.append(entry)
            if item.isFolder { folders += 1 } else {
                files += 1
                totalBytes = ProgressMath.add(totalBytes, item.size ?? 0)
            }
            return entry
        }

        func key(_ name: String) -> String { FileNameSanitizer.collisionKey(name, caseSensitive: !caseInsensitive) }

        func finish() -> TransferPlan {
            TransferPlan(entries: entries, totalBytes: totalBytes, fileCount: files, folderCount: folders,
                         reservedNames: reserved)
        }
    }
}
