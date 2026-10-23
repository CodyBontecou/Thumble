import Darwin
import Foundation

/// Private native disk owner. No caller-selected production paths or credential storage.
public final class EditorJournalFileStore: EditorJournalStorage {
  enum FaultPoint { case beforeReplace, afterReplace }
  private let gate = NSLock()
  private let directory: Int32
  private let pin: String
  private let fault: ((FaultPoint) throws -> Void)?
  public convenience init(certificateSHA256: String) throws {
    guard
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { throw EditorJournalError.unavailable }
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    // Canonicalize only the OS-provided parent. Child paths remain no-follow.
    guard let pointer = realpath(support.path, nil) else { throw EditorJournalError.unavailable }
    let parent = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    free(pointer)
    try self.init(
      directory: parent.appendingPathComponent("ThumbleEditorJournalV1", isDirectory: true),
      certificateSHA256: certificateSHA256, create: true)
  }
  init(
    directory: URL, certificateSHA256: String, create: Bool = false,
    fault: ((FaultPoint) throws -> Void)? = nil
  ) throws {
    guard EditorJournalCodec.hash(certificateSHA256), directory.isFileURL else {
      throw EditorJournalError.invalid
    }
    self.directory = try Self.openDirectory(directory.path, create: create)
    pin = certificateSHA256
    self.fault = fault
  }
  deinit { Darwin.close(directory) }
  private static func openDirectory(_ path: String, create: Bool) throws -> Int32 {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
      throw EditorJournalError.invalid
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
      throw EditorJournalError.invalid
    }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw EditorJournalError.unavailable }
    do {
      for (index, part) in parts.enumerated() {
        var next = Darwin.openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0 && errno == ENOENT && create && index == parts.count - 1 {
          guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else {
            throw EditorJournalError.unavailable
          }
          next = Darwin.openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard next >= 0 else { throw EditorJournalError.unavailable }
        Darwin.close(fd)
        fd = next
      }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
        throw EditorJournalError.unavailable
      }
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }
  private func regular(_ fd: Int32, allowEmpty: Bool) throws -> Int {
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
      value.st_uid == getuid(), value.st_mode & 0o077 == 0, value.st_size >= (allowEmpty ? 0 : 1),
      value.st_size <= EditorJournalCodec.maximumBytes
    else { throw EditorJournalError.unavailable }
    return Int(value.st_size)
  }
  private func stageExists() throws -> Bool {
    let fd = Darwin.openat(directory, pin + ".new", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return false }
      throw EditorJournalError.unavailable
    }
    defer { Darwin.close(fd) }
    _ = try regular(fd, allowEmpty: true)
    return true
  }
  private func locked<T>(_ action: () throws -> T) throws -> T {
    try gate.withLock {
      let lock = Darwin.openat(
        directory, pin + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard lock >= 0 else { throw EditorJournalError.unavailable }
      defer { Darwin.close(lock) }
      _ = try regular(lock, allowEmpty: true)
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw EditorJournalError.unavailable }
      defer { _ = flock(lock, LOCK_UN) }
      _ = try stageExists()
      return try action()
    }
  }
  private func readUnlocked() throws -> Data? {
    let fd = Darwin.openat(directory, pin + ".json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw EditorJournalError.unavailable
    }
    defer { Darwin.close(fd) }
    let size = try regular(fd, allowEmpty: false)
    var data = Data(count: size)
    try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < size {
        let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), size - offset)
        guard count > 0 else { throw EditorJournalError.unavailable }
        offset += count
      }
    }
    var extra: UInt8 = 0
    guard Darwin.read(fd, &extra, 1) == 0 else { throw EditorJournalError.unavailable }
    let parsed = try EditorJournalCodec.decode(data)
    guard parsed.certificateSHA256 == pin else { throw EditorJournalError.invalid }
    return data
  }
  public func load() throws -> Data? { try locked { try readUnlocked() } }
  public func save(_ candidate: Data, replacing expected: Data?) throws {
    guard try EditorJournalCodec.decode(candidate).certificateSHA256 == pin else {
      throw EditorJournalError.invalid
    }
    try locked {
      guard try readUnlocked() == expected else { throw EditorJournalError.changedOnDisk }
      let stage = pin + ".new"
      if try stageExists() {
        guard unlinkat(directory, stage, 0) == 0 else { throw EditorJournalError.unavailable }
      }
      let fd = Darwin.openat(
        directory, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw EditorJournalError.unavailable }
      var replaced = false
      defer {
        Darwin.close(fd)
        if !replaced { _ = unlinkat(directory, stage, 0) }
      }
      do {
        #if os(iOS)
          // The staged inode gets protection before any replace can publish it.
          var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
          let found = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
          guard found == 0 else { throw EditorJournalError.unavailable }
          try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: String(
              decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        #endif
        try candidate.withUnsafeBytes { buffer in
          var offset = 0
          while offset < candidate.count {
            let count = Darwin.write(
              fd, buffer.baseAddress!.advanced(by: offset), candidate.count - offset)
            guard count > 0 else { throw EditorJournalError.unavailable }
            offset += count
          }
        }
        guard fsync(fd) == 0 else { throw EditorJournalError.unavailable }
        try fault?(.beforeReplace)
        guard renameat(directory, stage, directory, pin + ".json") == 0 else {
          throw EditorJournalError.unavailable
        }
        replaced = true
        try fault?(.afterReplace)
        guard fsync(directory) == 0, try readUnlocked() == candidate else {
          throw EditorJournalError.uncertain(nil)
        }
      } catch {
        if replaced { throw EditorJournalError.uncertain(nil) }
        throw error
      }
    }
  }
}
