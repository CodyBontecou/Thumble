import AVFoundation
import Speech

// A session owns the microphone and all recognition tasks. No audio is saved.
@MainActor
final class SpeechSession {
    var emit: (([String: Any]) -> Void)?
    private var id: String?
    private var engine: AVAudioEngine?
    private var setup: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var finishModern: (() async throws -> Void)?
    private var cancelModern: (() async -> Void)?
    private var removeTap = false
    private var interruption: NSObjectProtocol?

    init() {
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                self?.event(["error": "Dictation was interrupted. Review your text or try again."])
                self?.cancel()
            }
        }
    }
    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }

    func start(id: String, locale: String, allowNetwork: Bool) {
        cancel()
        self.id = id
        event(["state": "preparing"])
        setup = Task {
            do {
                let allowed = await withCheckedContinuation { continuation in
                    AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
                }
                try check(id)
                guard allowed else { throw SpeechFailure("Microphone access is disabled. Enable it in Settings, or type your message.") }
                let locale = locale.isEmpty ? Locale.current : Locale(identifier: locale)
                if #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
                   let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                    try check(id)
                    do { try await startModern(locale: supported, id: id) }
                    catch {
                        try check(id)
                        stopAudio(); results?.cancel(); results = nil
                        if let cancelModern { await cancelModern() }
                        finishModern = nil; cancelModern = nil
                        try check(id)
                        try await startLegacy(locale: locale, allowNetwork: allowNetwork, id: id)
                    }
                } else {
                    try check(id)
                    try await startLegacy(locale: locale, allowNetwork: allowNetwork, id: id)
                }
                try check(id)
                timeout = Task { try? await Task.sleep(for: .seconds(55)); if !Task.isCancelled { self.stop() } }
            } catch is CancellationError { }
            catch { if self.id == id { event(["error": error.localizedDescription]); cancel() } }
        }
    }

    private func check(_ expected: String) throws {
        try Task.checkCancellation()
        guard id == expected else { throw CancellationError() }
    }
    private func event(_ value: [String: Any]) {
        guard let id else { return }
        emit?(value.merging(["id": id]) { _, new in new })
    }
    private func audioEngine() throws -> AVAudioEngine {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
        let engine = AVAudioEngine(); self.engine = engine
        return engine
    }
    private func startLegacy(locale: Locale, allowNetwork: Bool, id: String) async throws {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try check(id)
        guard authorization == .authorized else { throw SpeechFailure("Speech recognition access is disabled. Enable it in Settings, or type your message.") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw SpeechFailure("Speech recognition is unavailable for this language. Try typing instead.") }
        guard recognizer.supportsOnDeviceRecognition || allowNetwork else { throw SpeechFailure("This phone needs online recognition for this language. Enable online recognition below, or type your message.") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        request.contextualStrings = ["World of Warcraft", "Azeroth", "Horde", "Alliance", "raid", "healer", "tank"]
        self.request = request
        let engine = try audioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechFailure("Microphone is unavailable.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        removeTap = true
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.id == id else { return }
                if let result { self.event(["text": result.bestTranscription.formattedString]) }
                if result?.isFinal == true { self.event(["state": "done"]); self.cancel() }
                else if let error { self.event(["error": error.localizedDescription]); self.cancel() }
            }
        }
        engine.prepare(); try engine.start()
        event(["state": "listening", "engine": recognizer.supportsOnDeviceRecognition ? "Apple on-device dictation" : "Apple online dictation"])
    }

    @available(iOS 26.0, *)
    private func startModern(locale: Locale, id: String) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try check(id); event(["state": "preparing", "engine": "Downloading Apple speech model…"])
            try await download.downloadAndInstall()
        }
        try check(id)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw SpeechFailure("Speech audio format is unavailable.") }
        try check(id)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        finishModern = { continuation.finish(); try await analyzer.finalizeAndFinishThroughEndOfInput() }
        cancelModern = { continuation.finish(); await analyzer.cancelAndFinishNow() }
        results = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    try check(id)
                    let text = String(result.text.characters)
                    event(["text": finalized + text])
                    if result.isFinal { finalized += text }
                }
            } catch is CancellationError { }
            catch { if self.id == id { event(["error": error.localizedDescription]); cancel() } }
        }
        try await analyzer.start(inputSequence: stream)
        try check(id)
        let engine = try audioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let converter = AVAudioConverter(from: source, to: format) else { throw SpeechFailure("Microphone audio format is unavailable.") }
        // The tap runs serially on the audio thread. Convert and hand over an owned buffer.
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / source.sampleRate)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            if error == nil, converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        removeTap = true
        engine.prepare(); try engine.start()
        event(["state": "listening", "engine": "Apple SpeechTranscriber · on device"])
    }

    func stop() {
        guard id != nil else { return }
        timeout?.cancel(); timeout = nil
        // Stopping during a model download cancels preparation without opening the mic later.
        guard engine != nil else { event(["state": "done"]); cancel(); return }
        stopAudio(); event(["state": "finishing"])
        request?.endAudio()
        if let finishModern {
            let expected = id
            setup = Task {
                do {
                    try await finishModern()
                    await results?.value
                    if id == expected { event(["state": "done"]); cancel() }
                } catch { if id == expected { event(["error": error.localizedDescription]); cancel() } }
            }
        }
        timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { event(["error": "Recognition timed out. Review the text or try again."]); cancel() }
        }
    }
    private func stopAudio() {
        engine?.stop()
        if removeTap { engine?.inputNode.removeTap(onBus: 0); removeTap = false }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func cancel() {
        id = nil
        setup?.cancel(); setup = nil
        timeout?.cancel(); timeout = nil
        results?.cancel(); results = nil
        stopAudio(); request?.endAudio(); request = nil
        legacyTask?.cancel(); legacyTask = nil
        if let cancelModern { Task { await cancelModern() } }
        finishModern = nil; cancelModern = nil
    }
}

private struct SpeechFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
