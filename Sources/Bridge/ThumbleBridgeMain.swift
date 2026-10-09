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
            let request = try JSONDecoder().decodeUnique(ThumbleConfigurationBridgeRequest.self, from: requestData)
            let response = try ThumbleConfigurationBridge.transform(request)
            try emit(response)
        } catch let error as ThumbleConfigurationBridgeError {
            emitFailure(code: error.rawValue, message: error.localizedDescription)
            exit(1)
        } catch {
            emitFailure(code: "invalid_request", message: "Bridge request failed validation")
            exit(1)
        }
    }

    private static func readSingleBoundedRequest() throws -> Data {
        var data = Data()
        while true {
            let remaining = thumbleConfigurationBridgeMaximumBytes + 2 - data.count
            guard remaining > 0 else { throw ThumbleBridgeInputError.tooLarge }
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, remaining)),
                  !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        guard data.count <= thumbleConfigurationBridgeMaximumBytes + 1 else {
            throw ThumbleBridgeInputError.tooLarge
        }
        guard data.last == 0x0A else { throw ThumbleBridgeInputError.missingNewline }
        data.removeLast()
        guard !data.isEmpty, !data.contains(0x0A), !data.contains(0x0D) else {
            throw ThumbleBridgeInputError.multipleRequests
        }
        return data
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        guard data.count <= thumbleConfigurationBridgeMaximumBytes else {
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
