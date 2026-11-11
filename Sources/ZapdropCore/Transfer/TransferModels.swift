import Foundation

// MARK: - Request

public struct TransferOptions: Sendable, Equatable {
    public var duplicatePolicy: DuplicatePolicy
    public var preserveModificationDates: Bool
    /// Re-read every written file and compare it with what arrived over USB (slower; see docs/DECISIONS.md D8).
    public var verifyAfterCopy: Bool
    /// Extra free space to keep on the Mac beyond the files themselves.
    public var freeSpaceMargin: UInt64

    public init(duplicatePolicy: DuplicatePolicy = .ask, preserveModificationDates: Bool = true,
                verifyAfterCopy: Bool = false, freeSpaceMargin: UInt64 = 100_000_000) {
        self.duplicatePolicy = duplicatePolicy
        self.preserveModificationDates = preserveModificationDates
        self.verifyAfterCopy = verifyAfterCopy
        self.freeSpaceMargin = freeSpaceMargin
    }
}

public struct TransferRequest: Sendable {
    /// Items selected in one folder of the phone.
    public var items: [RemoteItem]
    public var storageID: StorageID
    /// Raw names from the storage root to the folder containing `items` (used to find files again after a reconnect).
    public var sourceFolderPath: [String]
    public var destination: URL
    public var options: TransferOptions
    /// Whether names that differ only by case clash at the destination (true for default macOS volumes).
    public var destinationIsCaseInsensitive: Bool

    public init(items: [RemoteItem], storageID: StorageID, sourceFolderPath: [String], destination: URL,
                options: TransferOptions = TransferOptions(), destinationIsCaseInsensitive: Bool = true) {
        self.items = items
        self.storageID = storageID
        self.sourceFolderPath = sourceFolderPath
        self.destination = destination
        self.options = options
        self.destinationIsCaseInsensitive = destinationIsCaseInsensitive
    }
}

// MARK: - Duplicates

public enum DuplicateAction: String, Sendable, Equatable, CaseIterable {
    case replace, skip, keepBoth
}

public enum DuplicatePolicy: Sendable, Equatable {
    case ask
    case always(DuplicateAction)
}

public struct DuplicateConflict: Sendable, Equatable {
    public let fileName: String
    public let destination: URL
    public let incomingSize: UInt64?
    public let incomingModified: Date?
    public let existingSize: UInt64?
    public let existingModified: Date?
    public let remainingFiles: Int
}

public struct DuplicateDecision: Sendable, Equatable {
    public var action: DuplicateAction
    public var applyToAll: Bool
    public init(_ action: DuplicateAction, applyToAll: Bool = false) {
        self.action = action
        self.applyToAll = applyToAll
    }
}

/// Asks the user what to do about a name clash. Returning `nil` cancels the whole transfer.
public protocol DuplicateResolver: Sendable {
    func resolve(_ conflict: DuplicateConflict) async -> DuplicateDecision?
}

/// Applies the duplicate policy, remembering "apply to all" answers for the rest of a job.
public final class DuplicateResolutionService: @unchecked Sendable {
    private let resolver: DuplicateResolver?
    private let state: Locked<DuplicatePolicy>

    public init(policy: DuplicatePolicy, resolver: DuplicateResolver?) {
        self.state = Locked(policy)
        self.resolver = resolver
    }

    /// `nil` means the user cancelled.
    public func decide(_ conflict: DuplicateConflict) async -> DuplicateAction? {
        switch state.current {
        case .always(let action):
            return action
        case .ask:
            guard let resolver else { return .keepBoth } // never overwrite without an explicit choice
            guard let decision = await resolver.resolve(conflict) else { return nil }
            if decision.applyToAll { state.withLock { $0 = .always(decision.action) } }
            return decision.action
        }
    }
}

// MARK: - Plan

public struct PlannedEntry: Sendable, Identifiable {
    public enum Rename: Sendable, Equatable {
        /// Characters the Mac can't use were replaced.
        case sanitized(original: String)
        /// Another file in the same folder already had this name on the Mac (e.g. differs only by case).
        case nameClash(original: String)
    }
    public let id: Int
    public var source: RemoteItem
    /// Raw path from the storage root, including the item's own name.
    public let remotePath: [String]
    /// Sanitised folder components under the destination.
    public let directory: [String]
    /// Sanitised (and de-clashed) name.
    public let name: String
    public let rename: Rename?

    public var isDirectory: Bool { source.isFolder }
    public var size: UInt64 { source.size ?? 0 }
    public var relativePath: String { (directory + [name]).joined(separator: "/") }
}

public struct TransferPlan: Sendable {
    public var entries: [PlannedEntry]
    public var totalBytes: UInt64
    public var fileCount: Int
    public var folderCount: Int
    /// Collision keys of every planned name, per destination folder (joined path → keys).
    public var reservedNames: [String: Set<String>]
}

// MARK: - Progress and results

public enum TransferPhase: Sendable, Equatable {
    case queued
    case preparing(itemsFound: Int)
    case running
    case completed
    case partiallyCompleted
    case failed(ZapdropError)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .partiallyCompleted, .failed, .cancelled: return true
        default: return false
        }
    }
    public var isActive: Bool {
        switch self {
        case .preparing, .running: return true
        default: return false
        }
    }
}

public enum ItemStatus: Sendable, Equatable {
    case pending
    case active
    /// `savedAs` is set when the file was saved under a different name than on the phone.
    case completed(savedAs: String?, verified: Bool)
    case skipped(SkipReason)
    case failed(ZapdropError)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .failed(let e): return e.isRetryable
        case .cancelled: return true
        default: return false
        }
    }
}

public enum SkipReason: Sendable, Equatable {
    case alreadyExists
}

public struct ItemState: Sendable, Identifiable {
    public let entry: PlannedEntry
    public var status: ItemStatus
    public var bytesTransferred: UInt64
    public var id: Int { entry.id }
}

public struct TransferSnapshot: Sendable {
    public var phase: TransferPhase
    public var totalBytes: UInt64
    /// Bytes accounted for: finished, skipped or failed files plus the active file's progress.
    public var processedBytes: UInt64
    /// Bytes actually received over USB in this run.
    public var transferredBytes: UInt64
    public var totalFiles: Int
    public var completedFiles: Int
    public var skippedFiles: Int
    public var failedFiles: Int
    public var cancelledFiles: Int
    public var currentFileName: String?
    public var currentFileBytes: UInt64
    public var currentFileTotal: UInt64
    public var bytesPerSecond: Double
    public var secondsRemaining: Double?
    public var lastError: ZapdropError?
    public var itemsVersion: Int

    public var fraction: Double { ProgressMath.fraction(done: processedBytes, total: totalBytes) }
    public var currentFileFraction: Double { ProgressMath.fraction(done: currentFileBytes, total: currentFileTotal) }

    static let empty = TransferSnapshot(phase: .queued, totalBytes: 0, processedBytes: 0, transferredBytes: 0,
                                        totalFiles: 0, completedFiles: 0, skippedFiles: 0, failedFiles: 0,
                                        cancelledFiles: 0, currentFileName: nil, currentFileBytes: 0,
                                        currentFileTotal: 0, bytesPerSecond: 0, secondsRemaining: nil,
                                        lastError: nil, itemsVersion: 0)
}

/// End-of-job report shown to the user. Nothing is ever skipped silently.
public struct TransferSummary: Sendable {
    public var copied: [ItemState]
    public var renamed: [ItemState]
    public var skipped: [ItemState]
    public var failed: [ItemState]
    public var cancelled: [ItemState]
    public var foldersCreated: Int
}
