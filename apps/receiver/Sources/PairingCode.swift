import AppKit
import CoreImage

/// The PNG is a pairing credential. Only the private, short-lived bridge may cache it.
enum PairingCode {
    static func png(_ invitation: String) throws -> Data {
        guard let image = CIFilter(name: "CIQRCodeGenerator", parameters: [
            "inputMessage": Data(invitation.utf8), "inputCorrectionLevel": "M"
        ])?.outputImage else { throw EncodingError.unavailable }
        // Four white modules on each edge keep scanning independent of chat themes.
        let bounds = image.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
        let padded = image.composited(over: background).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let cg = CIContext().createCGImage(padded, from: padded.extent),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw EncodingError.unavailable }
        return data
    }
    private enum EncodingError: Error { case unavailable }
}
