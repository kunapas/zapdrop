import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@inline(__always) func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buf, count)
    #else
    return Glibc.write(fd, buf, count)
    #endif
}

// MARK: - Free space

public protocol VolumeSpaceProvider: Sendable {
    /// Bytes available for new files on the volume containing `url`.
    func availableBytes(at url: URL) throws -> UInt64
}

public struct SystemVolumeSpace: VolumeSpaceProvider {
    public init() {}
    public func availableBytes(at url: URL) throws -> UInt64 {
        #if os(macOS)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        #endif
        var s = statvfs()
        guard statvfs(url.path, &s) == 0 else { throw ZapdropError.fromErrno(errno, context: "statvfs") }
        return UInt64(s.f_bavail) &* UInt64(s.f_frsize)
    }
}

// MARK: - Inspecting paths without following links

public enum PathKind: Equatable, Sendable { case missing, file, directory, symlink, other }

public enum LocalFS {
    public static func kind(of url: URL) -> PathKind {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    public static func fileSize(of url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(st.st_size)
    }

    /// Verifies the user-chosen root is an existing, writable directory (following a link here is fine —
    /// the user picked it).
    public static func validateRoot(_ root: URL) throws {
        var st = stat()
        guard stat(root.path, &st) == 0 else { throw ZapdropError.destinationUnavailable }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ZapdropError.destinationUnavailable }
        guard access(root.path, W_OK) == 0 else { throw ZapdropError.permissionDenied }
    }

    /// Makes sure `root/components…` exists as real directories. Never follows a link below `root`.
    @discardableResult
    public static func ensureDirectory(root: URL, components: [String]) throws -> URL {
        var current = root.standardizedFileURL
        for component in components {
            current = try SafePath.join(root: current, components: [component])
            switch kind(of: current) {
            case .directory:
                continue
            case .missing:
                if mkdir(current.path, 0o755) != 0 {
                    let err = errno
                    if err == EEXIST, kind(of: current) == .directory { continue }
                    throw ZapdropError.fromErrno(err, context: component)
                }
            case .symlink:
                throw ZapdropError.unsafeDestinationPath
            case .file, .other:
                throw ZapdropError.destinationConflict(name: component)
            }
        }
        return current
    }

    public static func removeIfRegularFile(_ url: URL) {
        if kind(of: url) == .file { unlink(url.path) }
    }

    /// Moves `source` to `destination`. Without `replacing`, fails rather than overwrite anything that
    /// appeared at the destination in the meantime.
    public static func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        if replacing {
            if kind(of: destination) == .directory || kind(of: destination) == .symlink {
                throw ZapdropError.destinationConflict(name: destination.lastPathComponent)
            }
            guard rename(source.path, destination.path) == 0 else {
                throw ZapdropError.fromErrno(errno, context: destination.lastPathComponent)
            }
            return
        }
        #if canImport(Darwin)
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let err = errno
        if err == EEXIST { throw ZapdropError.destinationConflict(name: destination.lastPathComponent) }
        if err != ENOTSUP && err != EINVAL { throw ZapdropError.fromErrno(err, context: destination.lastPathComponent) }
        // File system without RENAME_EXCL support (e.g. some exFAT/SMB volumes). A hard link fails if the name is
        // taken, so it can't overwrite a file that appeared in the meantime.
        if link(source.path, destination.path) == 0 {
            unlink(source.path)
            return
        }
        if errno == EEXIST { throw ZapdropError.destinationConflict(name: destination.lastPathComponent) }
        // No hard links either (exFAT): check, then rename.
        #endif
        guard kind(of: destination) == .missing else {
            throw ZapdropError.destinationConflict(name: destination.lastPathComponent)
        }
        guard rename(source.path, destination.path) == 0 else {
            throw ZapdropError.fromErrno(errno, context: destination.lastPathComponent)
        }
    }

    public static func setModificationDate(_ date: Date, of url: URL) {
        do {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        } catch {
            Log.warning("fs", "Could not set modification date", url.lastPathComponent)
        }
    }

    /// Name for the in-progress file next to `finalName`. Unique, clearly marked, within 255 bytes.
    public static func partialName(for finalName: String) -> String {
        let tag = String(UInt32.random(in: 0...UInt32.max), radix: 16)
        let suffix = ".\(tag).zapdroppart"
        let base = FileNameSanitizer.truncate(finalName, toUTF8Bytes: FileNameSanitizer.maxComponentBytes - suffix.utf8.count)
        return base + suffix
    }

    public static let partialExtension = "zapdroppart"
}

// MARK: - Writing a file safely

/// Writes incoming bytes to a new partial file. Memory use is independent of file size.
public final class LocalFileWriter: ByteSink {
    public let partialURL: URL
    public private(set) var bytesWritten: UInt64 = 0
    private var fd: Int32
    private var hasher: SHA256Hasher?
    private let cancellation: CancellationFlag?
    private let maxBytes: UInt64?

    /// Creates the partial file exclusively (`O_EXCL`), refusing to follow links (`O_NOFOLLOW`).
    /// `maxBytes`: the size the phone declared. A phone that sends more is stopped there, not when the disk is full.
    public init(partialURL: URL, computeDigest: Bool, cancellation: CancellationFlag? = nil, maxBytes: UInt64? = nil) throws {
        self.partialURL = partialURL
        self.cancellation = cancellation
        self.maxBytes = maxBytes
        self.hasher = computeDigest ? SHA256Hasher() : nil
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fd = open(partialURL.path, flags, 0o644)
        guard fd >= 0 else { throw ZapdropError.fromErrno(errno, context: partialURL.lastPathComponent) }
        self.fd = fd
    }

    deinit { if fd >= 0 { close(fd) } }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        if cancellation?.isCancelled == true { throw ZapdropError.cancelled }
        guard fd >= 0 else { throw ZapdropError.io(detail: "write after close") }
        guard var base = bytes.baseAddress, bytes.count > 0 else { return }
        if let maxBytes, ProgressMath.add(bytesWritten, UInt64(bytes.count)) > maxBytes {
            throw ZapdropError.sizeMismatch(expected: maxBytes, actual: ProgressMath.add(bytesWritten, UInt64(bytes.count)))
        }
        var remaining = bytes.count
        while remaining > 0 {
            let n = posixWrite(fd, base, remaining)
            if n < 0 {
                if errno == EINTR { continue }
                throw ZapdropError.fromErrno(errno, context: partialURL.lastPathComponent)
            }
            remaining -= n
            base = base.advanced(by: n)
        }
        hasher?.update(bytes)
        bytesWritten = ProgressMath.add(bytesWritten, UInt64(bytes.count))
    }

    /// Flushes to disk and closes. Returns the SHA-256 of everything written, if requested.
    public func finish() throws -> [UInt8]? {
        guard fd >= 0 else { return nil }
        #if canImport(Darwin)
        // F_FULLFSYNC asks the drive to flush its cache too; fall back to fsync if unsupported.
        if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            let err = errno; close(fd); fd = -1
            throw ZapdropError.fromErrno(err, context: partialURL.lastPathComponent)
        }
        #else
        if fsync(fd) != 0 {
            let err = errno; close(fd); fd = -1
            throw ZapdropError.fromErrno(err, context: partialURL.lastPathComponent)
        }
        #endif
        let rc = close(fd)
        fd = -1
        if rc != 0 { throw ZapdropError.fromErrno(errno, context: partialURL.lastPathComponent) }
        return hasher?.finalize()
    }

    /// Closes (if needed) and deletes the partial file.
    public func discard() {
        if fd >= 0 { close(fd); fd = -1 }
        LocalFS.removeIfRegularFile(partialURL)
    }
}

/// Re-reads a written file (bypassing the cache where the OS allows) and returns its SHA-256.
public enum ReadBackVerifier {
    public static func digest(of url: URL, cancellation: CancellationFlag? = nil, chunkSize: Int = 1 << 20) throws -> [UInt8] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ZapdropError.fromErrno(errno, context: url.lastPathComponent) }
        defer { close(fd) }
        #if canImport(Darwin)
        _ = fcntl(fd, F_NOCACHE, 1)
        #endif
        var hasher = SHA256Hasher()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            if cancellation?.isCancelled == true { throw ZapdropError.cancelled }
            let n = read(fd, buffer.baseAddress, chunkSize)
            if n < 0 { if errno == EINTR { continue }; throw ZapdropError.fromErrno(errno, context: url.lastPathComponent) }
            if n == 0 { break }
            hasher.update(UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
        }
        return hasher.finalize()
    }
}
