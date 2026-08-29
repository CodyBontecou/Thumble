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

    func testAssemblerOrderedSuccessDuplicateBusyCancelTimeoutAndTamper() throws {
        let data = Data(repeating: 9, count: ProfileArtifactAdoptionConstants.chunkBytes + 3)
        let value = metadata(data: data)
        let assembler = ProfileArtifactAdoptionAssembler()
        XCTAssertEqual(assembler.begin(value, expectedServerID: serverID, nowMilliseconds: 10), .accepted)
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 0, data: data.prefix(ProfileArtifactAdoptionConstants.chunkBytes), nowMilliseconds: 11), .chunkAccepted(0))
        // A replayed begin is a full retry boundary, so chunk zero is accepted again.
        XCTAssertEqual(assembler.begin(value, expectedServerID: serverID, nowMilliseconds: 12), .accepted)
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 0, data: data.prefix(ProfileArtifactAdoptionConstants.chunkBytes), nowMilliseconds: 13), .chunkAccepted(0))
        assembler.reset()
        XCTAssertEqual(assembler.begin(value, expectedServerID: serverID, nowMilliseconds: 14), .accepted)
        let other = metadata(data: data)
        XCTAssertEqual(assembler.begin(other, expectedServerID: serverID, nowMilliseconds: 15), .rejected(.uploadBusy))
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 1, data: data.suffix(3), nowMilliseconds: 15), .rejected(.outOfOrder))
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 0, data: data.prefix(ProfileArtifactAdoptionConstants.chunkBytes), nowMilliseconds: 16), .chunkAccepted(0))
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 0, data: data.prefix(ProfileArtifactAdoptionConstants.chunkBytes), nowMilliseconds: 17), .rejected(.outOfOrder))
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 1, data: data.suffix(3), nowMilliseconds: 18), .chunkAccepted(1))
        XCTAssertEqual(assembler.commit(operationID: value.operationID, nowMilliseconds: 19), .completed)
        let completed = try XCTUnwrap(assembler.takeCompleted())
        XCTAssertEqual(completed.data, data)
        XCTAssertEqual(completed.metadata, value)

        XCTAssertEqual(assembler.begin(value, expectedServerID: serverID, nowMilliseconds: 100), .accepted)
        XCTAssertEqual(assembler.cancel(operationID: UUID()), .rejected(.operationConflict))
        XCTAssertEqual(assembler.cancel(operationID: value.operationID), .cancelled)
        XCTAssertNil(assembler.activeOperationID)

        XCTAssertEqual(assembler.begin(value, expectedServerID: serverID, nowMilliseconds: 1_000), .accepted)
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 0, data: data.prefix(ProfileArtifactAdoptionConstants.chunkBytes), nowMilliseconds: 31_000), .rejected(.uploadExpired))
        XCTAssertNil(assembler.activeOperationID)

        var tampered = data
        tampered[tampered.startIndex] ^= 1
        XCTAssertEqual(assembler.begin(value, expectedServerID: serverID, nowMilliseconds: 40_000), .accepted)
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 0, data: tampered.prefix(ProfileArtifactAdoptionConstants.chunkBytes), nowMilliseconds: 40_001), .chunkAccepted(0))
        XCTAssertEqual(assembler.append(operationID: value.operationID, index: 1, data: tampered.suffix(3), nowMilliseconds: 40_002), .chunkAccepted(1))
        XCTAssertEqual(assembler.commit(operationID: value.operationID, nowMilliseconds: 40_003), .rejected(.invalidHash))
    }

    func testStrictMessageEnvelopesAndChunkFrameStayBounded() throws {
        let data = Data(repeating: 4, count: ProfileArtifactAdoptionConstants.chunkBytes)
        let value = metadata(data: data)
        let begin = ControllerMessage(type: .profileArtifactAdoptionBegin, profileArtifactAdoptionMetadata: value)
        XCTAssertNil(ProfileArtifactAdoptionEnvelopeValidator.validate(begin))
        let chunk = ControllerMessage(
            type: .profileArtifactAdoptionChunk,
            profileArtifactAdoptionOperationID: value.operationID,
            profileArtifactAdoptionChunkIndex: 0,
            profileArtifactAdoptionChunkData: data
        )
        XCTAssertNil(ProfileArtifactAdoptionEnvelopeValidator.validate(chunk))
        let encoded = try ControllerWireCodec.encode(chunk, using: JSONEncoder())
        XCTAssertLessThan(encoded.count, ControllerWireCodec.maximumInboundPayloadSize)
        XCTAssertEqual(try ControllerWireCodec.decode(encoded, using: JSONDecoder()).profileArtifactAdoptionChunkData, data)
        let extraneous = ControllerMessage(
            type: .profileArtifactAdoptionCommit,
            message: "not allowed",
            profileArtifactAdoptionOperationID: value.operationID
        )
        XCTAssertEqual(ProfileArtifactAdoptionEnvelopeValidator.validate(extraneous), .invalidEnvelope)
        XCTAssertEqual(ProfileArtifactAdoptionEnvelopeValidator.validate(.init(type: .profileArtifactAdoptionChunk)), .invalidEnvelope)
    }

    func testCommittingGateMakesDuplicateBeginAndCommitExactlyOnce() {
        let value = metadata(data: Data([1, 2, 3]))
        var gate = ProfileArtifactAdoptionCommitGate()
        XCTAssertEqual(gate.decision(for: value), .proceed)
        XCTAssertTrue(gate.begin(value))
        var importStarts = 1
        for _ in 0..<10 {
            switch gate.decision(for: value) {
            case .proceed:
                importStarts += 1
            case .inProgress:
                break
            case .busy, .conflict:
                XCTFail("same operation must be recognized as in progress")
            }
            XCTAssertFalse(gate.begin(value))
        }
        let other = metadata(data: Data([9]))
        XCTAssertEqual(gate.decision(for: other), .busy)
        let conflicting = metadata(data: Data([8]), operationID: value.operationID, recordID: value.recordID)
        XCTAssertEqual(gate.decision(for: conflicting), .conflict)
        XCTAssertEqual(importStarts, 1)
        gate.finish(operationID: UUID())
        XCTAssertEqual(gate.decision(for: value), .inProgress)
        gate.finish(operationID: value.operationID)
        XCTAssertEqual(gate.decision(for: value), .proceed)
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

    func testLedgerReplayConflictPruneRestartAndExactlyOneImportDecision() throws {
        let now: Int64 = 1_000_000
        let value = metadata(data: Data([1, 2, 3]))
        let destinations = [UUID()]
        let entry = ProfileArtifactAdoptionLedgerEntry(
            metadata: value,
            status: .succeeded,
            errorCode: nil,
            destinationProfileIDs: destinations,
            completedAtMilliseconds: now
        )
        var ledger = ProfileArtifactAdoptionLedger()
        XCTAssertEqual(ledger.lookup(value, nowMilliseconds: now), .none)
        var importCount = 0
        if ledger.lookup(value, nowMilliseconds: now) == .none {
            importCount += 1
            ledger.record(entry, nowMilliseconds: now)
        }
        if case .replay(let replay) = ledger.lookup(value, nowMilliseconds: now + 1) {
            XCTAssertEqual(replay.destinationProfileIDs, destinations)
        } else { XCTFail("expected replay") }
        XCTAssertEqual(importCount, 1)

        let changed = metadata(data: Data([9]), operationID: value.operationID, recordID: value.recordID)
        XCTAssertEqual(ledger.lookup(changed, nowMilliseconds: now + 1), .conflict)
        let encoded = try JSONEncoder().encode(ledger)
        var restarted = try JSONDecoder().decode(ProfileArtifactAdoptionLedger.self, from: encoded)
        XCTAssertEqual(restarted.lookup(value, nowMilliseconds: now + 2), .replay(entry))
        restarted.prune(nowMilliseconds: now + ProfileArtifactAdoptionConstants.ledgerLifetimeMilliseconds + 1)
        XCTAssertTrue(restarted.allEntries.isEmpty)

        var bounded = ProfileArtifactAdoptionLedger()
        for offset in 0..<(ProfileArtifactAdoptionConstants.maximumLedgerEntries + 10) {
            let item = metadata(data: Data([UInt8(offset % 255)]))
            bounded.record(.init(
                metadata: item, status: .failed, errorCode: .importFailed,
                destinationProfileIDs: [], completedAtMilliseconds: now + Int64(offset)
            ), nowMilliseconds: now + Int64(offset))
        }
        XCTAssertEqual(bounded.allEntries.count, ProfileArtifactAdoptionConstants.maximumLedgerEntries)
    }

    func testPhoneTrackerAcceptsResultAndSnapshotInEitherOrderAndRejectsWrongServer() {
        let value = metadata(data: Data([1]))
        let destinations = [UUID(), UUID()]
        let result = ProfileArtifactAdoptionResult(
            metadata: value,
            serverID: serverID,
            status: .succeeded,
            destinationProfileIDs: destinations
        )
        var resultFirst = IOSBuilderArtifactAdoptionState(
            metadata: value,
            phase: .uploading(sentChunks: 1, totalChunks: 1)
        )
        XCTAssertTrue(resultFirst.acceptResult(result))
        XCTAssertEqual(resultFirst.phase, .awaitingAuthoritativeSnapshot)
        XCTAssertFalse(resultFirst.observeAuthoritativeProfiles(Set([destinations[0]])))
        XCTAssertTrue(resultFirst.observeAuthoritativeProfiles(Set(destinations)))
        if case .succeeded(let ids, _) = resultFirst.phase { XCTAssertEqual(ids, destinations) }
        else { XCTFail("expected success") }

        var snapshotFirst = IOSBuilderArtifactAdoptionState(
            metadata: value,
            phase: .uploading(sentChunks: 1, totalChunks: 1)
        )
        XCTAssertFalse(snapshotFirst.observeAuthoritativeProfiles(Set(destinations)))
        XCTAssertTrue(snapshotFirst.acceptResult(result))
        XCTAssertTrue(snapshotFirst.observeAuthoritativeProfiles(Set(destinations)))

        let wrong = ProfileArtifactAdoptionResult(
            metadata: value,
            serverID: "wrong",
            status: .succeeded,
            destinationProfileIDs: destinations
        )
        var rejected = IOSBuilderArtifactAdoptionState(metadata: value, phase: .uploading(sentChunks: 0, totalChunks: 1))
        XCTAssertFalse(rejected.acceptResult(wrong))
    }
}
