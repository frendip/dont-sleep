import Foundation
import Darwin

public enum RecoveryPhase: String, Codable, Sendable { case prepared, active, restoring, restored }
public struct RecoveryRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: UUID
    public var generation: UInt64
    public let bootID: String
    public var phase: RecoveryPhase
    public let original: SleepSnapshot
    public var deadline: UInt64?
    public var stopReason: String?
    public init(version: Int = 1, sessionID: UUID, generation: UInt64, bootID: String, phase: RecoveryPhase, original: SleepSnapshot, deadline: UInt64? = nil, stopReason: String? = nil) {
        self.version = version; self.sessionID = sessionID; self.generation = generation
        self.bootID = bootID; self.phase = phase; self.original = original; self.deadline = deadline; self.stopReason = stopReason
    }
    func validate() throws {
        guard version == 1, generation > 0, !bootID.isEmpty, bootID.utf8.count <= 128 else { throw PlatformError.invalidJournal }
        if let stopReason {
            guard !stopReason.isEmpty, stopReason.utf8.count <= 64,
                  stopReason.unicodeScalars.allSatisfy({
                      (65...90).contains($0.value) || (97...122).contains($0.value)
                  }) else { throw PlatformError.invalidJournal }
        }
        try original.validateBaseline()
    }
}

/// All operations are relative to a retained directory descriptor. Production
/// paths must have root-owned, non-writable ancestors and a private final dir.
final class SecureDirectory {
    let descriptor: Int32
    let owner: uid_t
    init(url: URL, owner: uid_t, privateDirectory: Bool = true) throws {
        self.owner = owner
        guard url.isFileURL, url.path.hasPrefix("/") else { throw PlatformError.unsafeFile("directory") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw PlatformError.system("open root", errno) }
        do {
            let components = url.path.split(separator: "/")
            for (index, component) in components.enumerated() {
                guard component != ".", component != ".." else { throw PlatformError.unsafeFile("path component") }
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PlatformError.unsafeFile("directory component") }
                close(fd); fd = next
                var st = stat()
                guard fstat(fd, &st) == 0 else { throw PlatformError.system("fstat", errno) }
                let final = index == components.count - 1
                if owner == 0 || final {
                    guard st.st_uid == owner, st.st_mode & 0o022 == 0 else { throw PlatformError.unsafeFile("directory permissions") }
                    if final && privateDirectory && st.st_mode & 0o077 != 0 { throw PlatformError.unsafeFile("private directory permissions") }
                }
            }
            descriptor = fd
        } catch { close(fd); throw error }
    }
    deinit { close(descriptor) }
    func openFile(_ name: String, flags: Int32, mode: mode_t = 0o600, privateFile: Bool = true) throws -> Int32 {
        let fd = openat(descriptor, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode)
        guard fd >= 0 else { throw PlatformError.system("open protected file", errno) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == owner,
              st.st_nlink == 1, st.st_mode & (privateFile ? 0o077 : 0o022) == 0 else {
            close(fd); throw PlatformError.unsafeFile(name)
        }
        return fd
    }
    func readFile(_ name: String, privateFile: Bool = true) throws -> Data? {
        let fd: Int32
        do { fd = try openFile(name, flags: O_RDONLY, privateFile: privateFile) }
        catch PlatformError.system(_, let code) where code == ENOENT { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= 0, st.st_size <= 65536 else { throw PlatformError.unsafeFile("file size") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw PlatformError.system("read", errno) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 65536 else { throw PlatformError.unsafeFile("file size") }
        }
        return data
    }
    func writeAtomically(_ data: Data, named name: String) throws {
        let temporary = ".journal-" + UUID().uuidString
        let fd = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw PlatformError.system("write", errno) }
                guard count > 0 else { throw PlatformError.system("short write", EIO) }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw PlatformError.system("fsync file", errno) }
        // F_FULLFSYNC requests flushing drive caches on this macOS-only backend.
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw PlatformError.system("full fsync", errno) }
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw PlatformError.system("rename journal", errno) }
        guard fsync(descriptor) == 0 else { throw PlatformError.system("fsync directory", errno) }
    }
}

/// Call only from the sole writer's serial queue, while WriterLock is held.
public final class RecoveryJournal {
    private let directory: SecureDirectory
    public init(directory: URL, expectedOwner: uid_t = 0) throws { self.directory = try SecureDirectory(url: directory, owner: expectedOwner) }
    public func load() throws -> RecoveryRecord? {
        guard let data = try directory.readFile("recovery.json") else { return nil }
        guard let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data) else { throw PlatformError.invalidJournal }
        try record.validate(); return record
    }
    public func persist(_ record: RecoveryRecord) throws {
        try record.validate()
        if let old = try load(), old.phase != .restored {
            guard old.sessionID == record.sessionID, old.original == record.original,
                  old.bootID == record.bootID, record.generation >= old.generation,
                  !(old.phase == .restoring && (record.phase == .prepared || record.phase == .active)) else { throw PlatformError.conflictingSession }
        }
        let data = try JSONEncoder().encode(record)
        try directory.writeAtomically(data, named: "recovery.json")
    }
    public func markRestored(sessionID: UUID) throws {
        guard var record = try load(), record.sessionID == sessionID else { throw PlatformError.conflictingSession }
        record.phase = .restored; try persist(record)
    }
}

/// The owner retains this lock for its entire process lifetime. Every power
/// child inherits the SAME open-file description, so owner death alone cannot
/// release the lock while that child is still running.
public final class WriterLock {
    private let directory: SecureDirectory
    public let descriptor: Int32
    public private(set) var isHeld = false
    public init(directory: URL, expectedOwner: uid_t = 0) throws {
        let secure = try SecureDirectory(url: directory, owner: expectedOwner)
        self.directory = secure; self.descriptor = try secure.openFile("writer.lock", flags: O_RDWR | O_CREAT)
    }
    public func acquire() throws {
        guard !isHeld else { return }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw PlatformError.writerBusy }
        isHeld = true
    }
    /// Only after all power children are reaped. Unlocking is shared with child
    /// descriptors; releasing early would defeat crash fencing.
    public func release() { if isHeld { flock(descriptor, LOCK_UN); isHeld = false } }
    deinit { close(descriptor) } // Do not LOCK_UN: an orphan child may still hold it.
}
