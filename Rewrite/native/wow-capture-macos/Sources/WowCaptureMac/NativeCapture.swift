import AppKit
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

@MainActor
extension CaptureEnvironment {
  static let live = CaptureEnvironment(
    permitted: { CGPreflightScreenCaptureAccess() },
    windows: {
      // Background-only helper: initialize display connection without launching a GUI product.
      _ = NSApplication.shared.setActivationPolicy(.prohibited)
      let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)
      guard content.windows.count <= 4096 else { throw CaptureProtocolError.invalidReply }
      var result: [CaptureCandidate] = []
      for window in content.windows {
        guard let app = window.owningApplication,
          app.bundleIdentifier == "com.blizzard.worldofwarcraft",
          window.windowLayer == 0, window.frame.width >= 320, window.frame.height >= 320
        else { continue }
        guard let running = NSRunningApplication(processIdentifier: app.processID),
          running.bundleIdentifier == "com.blizzard.worldofwarcraft",
          let process = ProcessIdentity.read(app.processID),
          process.executable == running.executableURL?.path
        else { throw CaptureProtocolError.invalidReply }
        guard
          GameWindowPolicy.accepts(
            bundle: app.bundleIdentifier, executable: process.executable, layer: window.windowLayer,
            width: window.frame.width, height: window.frame.height)
        else { continue }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let width = filter.contentRect.width
        let height = filter.contentRect.height
        let pixelWidth = width * scale
        let pixelHeight = height * scale
        guard
          [
            window.frame.origin.x, window.frame.origin.y, window.frame.width, window.frame.height,
            width, height, scale, pixelWidth, pixelHeight,
          ].allSatisfy({ $0.isFinite }),
          scale > 0, width > 0, height > 0, pixelWidth.rounded() >= 1, pixelHeight.rounded() >= 1,
          pixelWidth.rounded() <= 8192, pixelHeight.rounded() <= 8192
        else { throw CaptureProtocolError.invalidReply }
        let w = Int(pixelWidth.rounded())
        let h = Int(pixelHeight.rounded())
        guard w * h <= 16_777_216 else { throw CaptureProtocolError.invalidReply }
        let identity = WindowIdentity(
          window: window.windowID, process: process,
          x: window.frame.origin.x, y: window.frame.origin.y, width: window.frame.width,
          height: window.frame.height,
          contentWidth: width, contentHeight: height, scale: scale, pixelWidth: w, pixelHeight: h)
        result.append(
          CaptureCandidate(
            identity: identity,
            image: {
              let configuration = SCStreamConfiguration()
              configuration.width = w
              configuration.height = h
              configuration.showsCursor = false
              return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            }))
        // Two eligible windows are already ambiguous; never choose one or enumerate their pixels.
        if result.count == 2 { break }
      }
      return result
    })
}
extension ProcessIdentity {
  static func read(_ pid: pid_t) -> Self? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let count = withUnsafeMutableBytes(of: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0.baseAddress, Int32(size))
    }
    guard count == size, info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
      info.pbi_start_tvusec < 1_000_000
    else {
      return nil
    }
    var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard length > 0, let zero = path.firstIndex(of: 0), zero > 0,
      let executable = String(bytes: path[..<zero], encoding: .utf8), executable.hasPrefix("/")
    else { return nil }
    let fd = executable.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var attributes = stat()
    guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
      attributes.st_size > 0, attributes.st_ino > 0
    else { return nil }
    // Read process start again after opening the privately discovered executable.
    var after = proc_bsdinfo()
    let again = withUnsafeMutableBytes(of: &after) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0.baseAddress, Int32(size))
    }
    guard again == size, after.pbi_pid == info.pbi_pid,
      after.pbi_start_tvsec == info.pbi_start_tvsec,
      after.pbi_start_tvusec == info.pbi_start_tvusec
    else { return nil }
    return Self(
      pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
      executable: executable, device: UInt64(UInt32(bitPattern: attributes.st_dev)),
      inode: attributes.st_ino, size: attributes.st_size,
      modifiedSeconds: Int64(attributes.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(attributes.st_mtimespec.tv_nsec),
      changedSeconds: Int64(attributes.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(attributes.st_ctimespec.tv_nsec))
  }
}
public enum CapturePermission {
  /// Does not enumerate windows, capture, create NSApplication or request permission.
  public static func status() -> String {
    CGPreflightScreenCaptureAccess() ? "authorized" : "permission-required"
  }
  /// Only the explicit executable flag invokes this user-visible OS permission API.
  public static func request() -> String {
    CGRequestScreenCaptureAccess() ? "authorized" : "permission-required"
  }
}

enum GameWindowPolicy {
  static func accepts(
    bundle: String?, executable: String, layer: Int, width: Double, height: Double
  ) -> Bool {
    bundle == "com.blizzard.worldofwarcraft" && layer == 0 && width.isFinite && height.isFinite
      && width >= 320 && height >= 320 && executable.hasPrefix("/")
      && (executable.contains("/_classic_era_/") || executable.contains("/_forever_/"))
  }
}
