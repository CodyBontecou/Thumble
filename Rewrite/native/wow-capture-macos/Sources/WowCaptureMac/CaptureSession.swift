import CoreGraphics
import Foundation

struct ProcessIdentity: Equatable, Sendable {
  let pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64
  let executable: String, device: UInt64, inode: UInt64, size: Int64
  let modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64,
    changedNanoseconds: Int64
}
struct WindowIdentity: Equatable, Sendable {
  let window: UInt32, process: ProcessIdentity
  let x: Double, y: Double, width: Double, height: Double
  let contentWidth: Double, contentHeight: Double, scale: Double
  let pixelWidth: Int, pixelHeight: Int
}
@MainActor
struct CaptureCandidate {
  let identity: WindowIdentity
  let image: @MainActor () async throws -> CGImage
}
@MainActor
struct CaptureEnvironment {
  let permitted: @MainActor () -> Bool
  let windows: @MainActor () async throws -> [CaptureCandidate]
}
/// One helper owns one private selected context. Parent TS owns all deadlines and termination.
@MainActor
public final class CaptureSession {
  private let environment: CaptureEnvironment
  private var context: (source: UInt32, generation: UInt64)?
  private var latestReceipt: UInt64 = 0
  private var window: WindowIdentity?
  private var invalidated = false
  private var capturing = false
  init(environment: CaptureEnvironment) { self.environment = environment }
  public convenience init() { self.init(environment: .live) }
  public func perform(_ request: CaptureRequest) async -> CaptureResponse {
    if let context,
      context.source != request.source || context.generation != request.generationValue
    {
      invalidated = true
    }
    guard !invalidated, !capturing, request.receiptValue > latestReceipt else {
      return .status(.unavailable)
    }
    capturing = true
    defer { capturing = false }
    context = (request.source, request.generationValue)
    latestReceipt = request.receiptValue
    guard environment.permitted() else { return .status(.permissionRequired) }
    do {
      let candidates = try await environment.windows()
      guard !Task.isCancelled, !invalidated, context?.source == request.source,
        context?.generation == request.generationValue
      else {
        invalidated = true
        return .status(.unavailable)
      }
      guard candidates.count == 1, let candidate = candidates.first else {
        if window != nil { invalidated = true }
        return .status(candidates.isEmpty ? .gameNotVisible : .multipleGameWindows)
      }
      if let window, window != candidate.identity {
        invalidated = true
        return .status(.unavailable)
      }
      window = candidate.identity
      guard environment.permitted() else { return .status(.permissionRequired) }
      let image = try await candidate.image()
      guard !Task.isCancelled, !invalidated, context?.source == request.source,
        context?.generation == request.generationValue
      else {
        invalidated = true
        return .status(.unavailable)
      }
      guard image.width == candidate.identity.pixelWidth,
        image.height == candidate.identity.pixelHeight
      else {
        invalidated = true
        return .status(.unavailable)
      }
      let after = try await environment.windows()
      guard after.count == 1, after.first?.identity == candidate.identity else {
        invalidated = true
        return .status(.unavailable)
      }
      guard !Task.isCancelled, !invalidated, context?.source == request.source,
        context?.generation == request.generationValue
      else {
        invalidated = true
        return .status(.unavailable)
      }
      guard let panel = try OpticalPanel.decode(image) else { return .status(.panelNotVisible) }
      return .frame(panel)
    } catch {
      invalidated = true
      return .status(.unavailable)
    }
  }
}
