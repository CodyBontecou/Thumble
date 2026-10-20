import Foundation
import XCTest

final class ProfileArtifactAdoptionTests: XCTestCase {
    private let serverID = "server-1"

    private func metadata(
        data: Data = Data(repeating: 7, count: ProfileArtifactAdoptionConstants.chunkBytes + 3),
        operationID: UUID = UUID(),
        recordID: UUID = UUID(),
        serverID: String = "server-1"
    ) -> ProfileArtifactAdoptionMetadata {
        ProfileArtifactAdoptionMetadata(
            operationID: operationID,
            recordID: recordID,
            intendedServerID: serverID,
            contentHash: String(repeating: "a", count: 64),
            rawSHA256: ProfileArtifactAdoptionMetadata.sha256(data),
            byteCount: data.count,
            chunkCount: ProfileArtifactAdoptionMetadata.chunkCount(forByteCount: data.count)
        )
    }

    func testMetadataBoundsHashesServerAndChunkMath() {
        let one = Data([1])
        XCTAssertNil(metadata(data: one).validate(expectedServerID: serverID))
        XCTAssertEqual(metadata(data: one, serverID: "other").validate(expectedServerID: serverID), .wrongServer)
        let badHash = ProfileArtifactAdoptionMetadata(
            operationID: UUID(), recordID: UUID(), intendedServerID: serverID,
            contentHash: String(repeating: "A", count: 64), rawSHA256: String(repeating: "b", count: 64),
            byteCount: 1, chunkCount: 1
        )
        XCTAssertEqual(badHash.validate(expectedServerID: serverID), .invalidHash)
        for count in [1, ProfileArtifactAdoptionConstants.chunkBytes,
                      ProfileArtifactAdoptionConstants.chunkBytes + 1,
                      ProfileArtifactAdoptionConstants.maximumArtifactBytes] {
            let value = metadata(data: Data(repeating: 1, count: count))
            XCTAssertNil(value.validate(expectedServerID: serverID))
            XCTAssertEqual(value.expectedChunkBytes(at: value.chunkCount - 1),
                           count - (value.chunkCount - 1) * ProfileArtifactAdoptionConstants.chunkBytes)
        }
        let empty = metadata(data: Data())
        XCTAssertEqual(empty.validate(expectedServerID: serverID), .invalidSize)
        let tooLargeCount = ProfileArtifactAdoptionConstants.maximumArtifactBytes + 1
        let tooLarge = ProfileArtifactAdoptionMetadata(
            operationID: UUID(), recordID: UUID(), intendedServerID: serverID,
            contentHash: String(repeating: "a", count: 64), rawSHA256: String(repeating: "b", count: 64),
            byteCount: tooLargeCount,
            chunkCount: ProfileArtifactAdoptionMetadata.chunkCount(forByteCount: tooLargeCount)
        )
        XCTAssertEqual(tooLarge.validate(expectedServerID: serverID), .invalidSize)
    }

    func testMetadataAndResultRejectHostileServerAndDestinationShapes() {
        let data = Data([1])
        XCTAssertEqual(metadata(data: data, serverID: "").validate(expectedServerID: ""), .invalidEnvelope)
        XCTAssertEqual(metadata(data: data, serverID: "server\nname").validate(expectedServerID: "server\nname"), .invalidEnvelope)
        let long = String(repeating: "s", count: 129)
        XCTAssertEqual(metadata(data: data, serverID: long).validate(expectedServerID: long), .invalidEnvelope)

        let value = metadata(data: data)
        let id = UUID()
        XCTAssertFalse(ProfileArtifactAdoptionResult(
            metadata: value, serverID: serverID, status: .succeeded,
            destinationProfileIDs: [id, id]
        ).validates(against: value))
        XCTAssertFalse(ProfileArtifactAdoptionResult(
            metadata: value, serverID: serverID, status: .succeeded,
            destinationProfileIDs: Array(repeating: UUID(), count: 257)
        ).validates(against: value))
        XCTAssertFalse(ProfileArtifactAdoptionResult(
            metadata: value, serverID: "other", status: .succeeded,
            destinationProfileIDs: [UUID()]
        ).validates(against: value))
    }

    func testRetiredRequestsDecodeAndRejectWithoutUploadOrProfilePayloads() throws {
        let value = metadata(data: Data([1, 2, 3]))
        for type: ControllerMessageType in [.profileArtifactAdoptionBegin, .profileArtifactAdoptionChunk,
                                             .profileArtifactAdoptionCommit, .profileArtifactAdoptionCancel] {
            let request = ControllerMessage(type: type,
                profileArtifactAdoptionMetadata: type == .profileArtifactAdoptionBegin ? value : nil,
                profileArtifactAdoptionOperationID: type == .profileArtifactAdoptionBegin ? nil : value.operationID,
                profileArtifactAdoptionChunkIndex: type == .profileArtifactAdoptionChunk ? 0 : nil,
                profileArtifactAdoptionChunkData: type == .profileArtifactAdoptionChunk ? Data([1, 2, 3]) : nil)
            let encoded = try ControllerWireCodec.encode(request, using: JSONEncoder())
            let decoded = try ControllerWireCodec.decode(encoded, using: JSONDecoder())
            XCTAssertNil(RetiredProfileArtifactAdoption.response(to: decoded, isPaired: false))
            let response = try XCTUnwrap(RetiredProfileArtifactAdoption.response(to: decoded, isPaired: true))
            XCTAssertEqual(response.type, .error)
            XCTAssertTrue(response.message?.contains("retired") == true)
            XCTAssertNil(response.profileArtifactAdoptionMetadata)
            XCTAssertNil(response.profileArtifactAdoptionResult)
            XCTAssertNil(response.profileArtifactAdoptionChunkData)
            XCTAssertNil(response.gamepadProfiles)
        }
        let malformed = ControllerMessage(type: .profileArtifactAdoptionBegin, message: "never reflect this value")
        let rejection = try XCTUnwrap(RetiredProfileArtifactAdoption.response(to: malformed, isPaired: true))
        XCTAssertFalse(rejection.message?.contains("never reflect") == true)
        XCTAssertNil(RetiredProfileArtifactAdoption.response(to: .init(type: .ping), isPaired: true))
        XCTAssertNil(RetiredProfileArtifactAdoption.response(to: .init(type: .profileArtifactAdoptionResult), isPaired: true))
    }
}
