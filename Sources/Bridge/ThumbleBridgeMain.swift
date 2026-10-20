import Foundation

@main
private enum ThumbleBridgeMain {
    static func main() {
        guard CommandLine.arguments.count == 1 else {
            emitFailure(code: "arguments_not_allowed", message: "thumble-bridge accepts no command-line arguments")
            exit(2)
        }
        do {
            let requestData = try readSingleBoundedRequest()
            let probe = try JSONDecoder().decodeUnique(BridgeRequestKind.self, from: requestData)
            if probe.profileArtifactCommand != nil {
                guard probe.skinCommand == nil, probe.phoneLayoutCommand == nil,
                      requestData.count <= 12 * 1024 * 1024 else { throw ThumbleBridgeInputError.tooLarge }
                let request = try JSONDecoder().decodeUnique(ThumbleProfileArtifactBridgeRequest.self, from: requestData)
                try emit(ThumbleProfileArtifactBridge.validate(request), maximumBytes: 24 * 1024 * 1024)
            } else if probe.phoneLayoutCommand != nil {
                guard probe.skinCommand == nil, requestData.count <= 24 * 1024 * 1024 else { throw ThumbleBridgeInputError.tooLarge }
                let request = try JSONDecoder().decodeUnique(ThumblePhoneLayoutBridgeRequest.self, from: requestData)
                try emit(ThumblePhoneLayoutBridge.transform(request))
            } else if probe.skinCommand != nil {
                let request = try JSONDecoder().decodeUnique(ThumbleSkinBridgeRequest.self, from: requestData)
                try emit(ThumbleSkinBridge.transform(request))
            } else {
                guard requestData.count <= thumbleConfigurationBridgeMaximumBytes else { throw ThumbleBridgeInputError.tooLarge }
                let request = try JSONDecoder().decodeUnique(ThumbleConfigurationBridgeRequest.self, from: requestData)
                try emit(ThumbleConfigurationBridge.transform(request))
            }
        } catch let error as ThumblePhoneLayoutBridgeError {
            emitFailure(code: error.rawValue, message: "Phone layout operation failed validation")
            exit(1)
        } catch let error as ThumbleSkinBridgeError {
            emitFailure(code: error.rawValue, message: "Skin operation failed validation")
            exit(1)
        } catch let error as ThumbleConfigurationBridgeError {
            emitFailure(code: error.rawValue, message: error.localizedDescription)
            exit(1)
        } catch {
            emitFailure(code: "invalid_request", message: "Bridge request failed validation")
            exit(1)
        }
    }

    // 40 MiB native archives expand to Base64, with room for an 8 MiB profile.
    private static let maximumSkinRequestBytes = 64 * 1024 * 1024

    private static func readSingleBoundedRequest() throws -> Data {
        var data = Data()
        while true {
            let remaining = maximumSkinRequestBytes + 2 - data.count
            guard remaining > 0 else { throw ThumbleBridgeInputError.tooLarge }
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, remaining)),
                  !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        guard data.count <= maximumSkinRequestBytes + 1 else {
            throw ThumbleBridgeInputError.tooLarge
        }
        guard data.last == 0x0A else { throw ThumbleBridgeInputError.missingNewline }
        data.removeLast()
        guard !data.isEmpty, !data.contains(0x0A), !data.contains(0x0D) else {
            throw ThumbleBridgeInputError.multipleRequests
        }
        return data
    }

    private static func emit<T: Encodable>(_ value: T, maximumBytes: Int = thumbleConfigurationBridgeMaximumBytes) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw ThumbleBridgeInputError.tooLarge
        }
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func emitFailure(code: String, message: String) {
        let failure = ThumbleConfigurationBridgeFailure(code: code, message: message)
        if let data = try? JSONEncoder().encode(failure) {
            try? FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
        }
    }
}

private enum ThumbleBridgeInputError: Error {
    case tooLarge
    case missingNewline
    case multipleRequests
}

private struct BridgeRequestKind: Decodable {
    let skinCommand: String?
    let phoneLayoutCommand: String?
    let profileArtifactCommand: String?
}
