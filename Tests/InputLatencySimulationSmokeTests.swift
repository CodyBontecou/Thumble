import Foundation

#if !XCODEBUILD_TEST
@main
#endif
struct InputLatencySimulationSmokeTests {
    static func main() {
        testV3CompactButtonRoundTrip()
        testUUIDInputWithoutMetadataAndRejectedSlotFrames()
        testJSONInputFields()
        testPipelineCaptureFieldsRoundTrip()

        let current = ThumbleInputLatencySimulator.run(
            pattern: .hollowKnight,
            mode: .current
        )
        expect(
            current.summary.p95Milliseconds < 4,
            "current Hollow Knight p95 stays below 4 ms"
        )
        expect(
            current.summary.overSixteenMilliseconds == 0,
            "current Hollow Knight path has no frame-budget misses"
        )

        let legacyBurst = ThumbleInputLatencySimulator.run(
            pattern: .sameButtonBurst,
            mode: .legacyMainActor
        )
        let currentBurst = ThumbleInputLatencySimulator.run(
            pattern: .sameButtonBurst,
            mode: .current
        )
        expect(
            legacyBurst.summary.p95Milliseconds > currentBurst.summary.p95Milliseconds + 16,
            "legacy main-actor model exposes burst input lag"
        )

        let recovery = ThumbleInputLatencySimulator.run(
            pattern: .udpRecovery,
            mode: .current
        )
        expect(
            recovery.recoveredByMirrorFrames >= 2,
            "TCP mirror recovers dropped UDP frames"
        )
        expect(
            recovery.summary.overSixteenMilliseconds == 0,
            "UDP recovery stays within one frame"
        )
        expect(
            recovery.summary.maxMilliseconds < 4,
            "TCP mirror recovery stays below the strict action-game budget"
        )

        let recoveryBurst = ThumbleInputLatencySimulator.run(
            pattern: .udpRecoveryBurst,
            mode: .current
        )
        expect(
            recoveryBurst.summary.maxMilliseconds < 4,
            "UDP recovery burst stays below the strict action-game budget"
        )

        let heldRecovery = ThumbleInputLatencySimulator.run(
            pattern: .heldDirectionHeartbeatRecovery,
            mode: .current
        )
        expect(
            heldRecovery.heartbeatResyncFrames == 1,
            "held direction heartbeat recovery reasserts the active hold"
        )
        expect(
            heldRecovery.samples.contains {
                $0.button == .preset(3) && $0.state == .down && $0.heartbeatResync
            },
            "held direction heartbeat recovery emits a left down re-sync frame"
        )
        expect(
            heldRecovery.summary.maxMilliseconds < 4,
            "held direction heartbeat recovery stays below the strict action-game budget"
        )

        let verification = ThumbleInputLatencySimulator.verifyCurrentPath()
        expect(
            verification.passed,
            "strict latency verification passes every current-path pattern"
        )

        print("Input latency simulation smoke tests passed")
    }

    private static func testV3CompactButtonRoundTrip() {
        let generation = UInt64.max - 10
        let sequence = UInt64.max - 20
        let pressIdentifier = UInt64.max - 30
        let data = ControllerWireCodec.encodeButton(
            .preset(6),
            state: .up,
            sequenceNumber: sequence,
            pressIdentifier: pressIdentifier,
            generation: generation
        )

        expect(data.count == 56, "v3 UUID input has the fixed 56-byte layout")
        expect(data[2] == UInt8(ControllerWireCodec.currentInputProtocolVersion), "compact input has the current version byte")

        let decoded = decode(data, "v3 compact button")
        expect(decoded.type == .button, "UUID input preserves type")
        expect(decoded.button == .preset(6), "UUID input preserves identity")
        expect(decoded.state == .up, "UUID input preserves state")
        expect(decoded.inputProtocolVersion == 3, "UUID input preserves protocol version")
        expect(decoded.inputGeneration == generation, "UUID input preserves full generation")
        expect(decoded.inputSequence == sequence, "UUID input preserves full sequence")
        expect(decoded.pressIdentifier == pressIdentifier, "UUID input preserves full press identifier")
        expect(ControllerWireCodec.inputSequenceNumber(from: decoded) == sequence, "sequence helper uses explicit sequence")
        expect(ControllerWireCodec.inputPressIdentifier(from: decoded) == pressIdentifier, "press helper uses explicit identifier")
    }

    private static func testUUIDInputWithoutMetadataAndRejectedSlotFrames() {
        let message = ControllerMessage(type: .button, button: .preset(7), state: .down,
                                        timestamp: ControllerWireCodec.inputSequenceTimestamp(for: 42, pressIdentifier: 1234))
        let data = encode(message, using: JSONEncoder(), "UUID input without explicit metadata")
        expect(data.count == 56 && data[2] == 3, "all compact inputs carry UUIDs")
        let decoded = decode(data, "UUID input")
        expect(decoded.button == .preset(7), "compact input preserves UUID identity")
        expect(decoded.inputProtocolVersion == nil, "absent explicit metadata stays absent")
        expect(ControllerWireCodec.inputSequenceNumber(from: decoded) == 42, "timestamp sequence packing is preserved")
        expect(ControllerWireCodec.inputPressIdentifier(from: decoded) == 1234, "timestamp identifier packing is preserved")
        for version in [UInt8(1), UInt8(2)] {
            var obsolete = Data(repeating: 0, count: version == 1 ? 14 : 32)
            obsolete[0] = 80; obsolete[1] = 80; obsolete[2] = version; obsolete[3] = 1
            do {
                _ = try ControllerWireCodec.decode(obsolete, using: JSONDecoder())
                expect(false, "slot-index inputs must be rejected")
            } catch {}
        }
    }

    private static func testJSONInputFields() {
        let encoder = JSONEncoder()
        let elementID = UUID(uuidString: "729B071A-B5BB-4A91-B2A7-F644C61E5920")!
        let element = ControllerMessage(
            type: .elementInput,
            elementID: elementID,
            elementPart: .joystickLeft,
            state: .down,
            inputProtocolVersion: 3,
            inputGeneration: 91,
            inputSequence: UInt64.max - 1,
            pressIdentifier: UInt64.max
        )
        let elementData = encode(element, using: encoder, "UUID element input")
        expect(elementData.count == 56 && elementData[2] == 3, "UUID element input uses compact v3")
        let decodedElement = decode(elementData, "JSON element input")
        expect(decodedElement.elementID == elementID, "JSON element input preserves element ID")
        expect(decodedElement.elementPart == .joystickLeft, "JSON element input preserves element part")
        expect(decodedElement.inputGeneration == 91, "JSON element input preserves generation")
        expect(decodedElement.inputSequence == UInt64.max - 1, "JSON element input preserves full sequence")
        expect(decodedElement.pressIdentifier == UInt64.max, "JSON element input preserves full press identifier")

        let release = ControllerMessage(
            type: .releaseAll,
            inputProtocolVersion: 3,
            inputGeneration: 92,
            inputSequence: UInt64.max,
            pressIdentifier: UInt64.max - 2
        )
        let releaseData = encode(release, using: encoder, "JSON release-all")
        expect(releaseData.first == 0x7B, "release-all with input metadata uses JSON instead of lossy compact encoding")
        let decodedRelease = decode(releaseData, "JSON release-all")
        expect(decodedRelease.inputProtocolVersion == 3, "JSON release-all preserves protocol version")
        expect(decodedRelease.inputGeneration == 92, "JSON release-all preserves generation")
        expect(decodedRelease.inputSequence == UInt64.max, "JSON release-all preserves full sequence")
        expect(decodedRelease.pressIdentifier == UInt64.max - 2, "JSON release-all preserves full press identifier")

        let legacyJSON = Data(#"{"type":"button","button":"jump","state":"down","timestamp":1}"#.utf8)
        do {
            _ = try ControllerWireCodec.decode(legacyJSON, using: JSONDecoder())
            expect(false, "named JSON input must be rejected")
        } catch {}
    }

    private static func testPipelineCaptureFieldsRoundTrip() {
        let event = ThumbleCaptureEvent(
            schemaVersion: 3,
            kind: "input_pipeline",
            source: "iPhone UDP",
            messageType: .elementInput,
            inputGeneration: 77,
            inputSequence: 88,
            decodeLatencyMS: 0.125,
            receiveToProcessedMS: 1.75,
            reorderWaitMS: 0.5,
            processingToCompletionMS: 1.125,
            bindingLookupMS: 0.025,
            outputInjectionMS: 0.75,
            postInjectionMS: 0.2,
            outputDeferred: false
        )
        do {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(ThumbleCaptureEvent.self, from: data)
            expect(decoded.inputGeneration == 77, "pipeline capture preserves generation")
            expect(decoded.inputSequence == 88, "pipeline capture preserves input sequence")
            expect(decoded.decodeLatencyMS == 0.125, "pipeline capture preserves decode timing")
            expect(decoded.receiveToProcessedMS == 1.75, "pipeline capture preserves processing timing")
            expect(decoded.reorderWaitMS == 0.5, "pipeline capture preserves reorder timing")
            expect(decoded.processingToCompletionMS == 1.125, "pipeline capture preserves input processing timing")
            expect(decoded.bindingLookupMS == 0.025, "pipeline capture preserves binding lookup timing")
            expect(decoded.outputInjectionMS == 0.75, "pipeline capture preserves output injection timing")
            expect(decoded.postInjectionMS == 0.2, "pipeline capture preserves post-injection timing")
            expect(decoded.outputDeferred == false, "pipeline capture preserves deferred-output state")

            let legacyData = Data(#"{"schemaVersion":2,"recordedAt":1,"kind":"input_pipeline","decodeLatencyMS":0.1}"#.utf8)
            let legacy = try JSONDecoder().decode(ThumbleCaptureEvent.self, from: legacyData)
            expect(legacy.outputInjectionMS == nil, "legacy pipeline capture remains decodable without output stages")
            expect(legacy.outputDeferred == nil, "legacy pipeline capture has no deferred-output state")
        } catch {
            fputs("InputLatencySimulationSmokeTests failed: pipeline capture round trip: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func encode(
        _ message: ControllerMessage,
        using encoder: JSONEncoder,
        _ description: String
    ) -> Data {
        do {
            return try ControllerWireCodec.encode(message, using: encoder)
        } catch {
            fputs("InputLatencySimulationSmokeTests failed to encode \(description): \(error)\n", stderr)
            exit(1)
        }
    }

    private static func decode(_ data: Data, _ description: String) -> ControllerMessage {
        do {
            return try ControllerWireCodec.decode(data, using: JSONDecoder())
        } catch {
            fputs("InputLatencySimulationSmokeTests failed to decode \(description): \(error)\n", stderr)
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("InputLatencySimulationSmokeTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
