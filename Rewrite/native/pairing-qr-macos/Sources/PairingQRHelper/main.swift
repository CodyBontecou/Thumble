import Foundation
import PairingQR

func run() throws {
  guard CommandLine.arguments.dropFirst() == ["render"] else {
    throw PairingQRError.invalidInvitation
  }
  var input = Data()
  while let chunk = try FileHandle.standardInput.read(
    upToCount: PairingQR.maximumInputBytes + 1 - input.count), !chunk.isEmpty
  {
    input.append(chunk)
    guard input.count <= PairingQR.maximumInputBytes else { throw PairingQRError.invalidInvitation }
  }
  let png = try PairingQR.render(input)
  try FileHandle.standardOutput.write(contentsOf: png)
}
do { try run() } catch {
  // Input may contain a live secret. Never interpolate input, arguments or errors.
  try? FileHandle.standardError.write(contentsOf: Data("pairing_qr_render_failed\n".utf8))
  exit(1)
}
