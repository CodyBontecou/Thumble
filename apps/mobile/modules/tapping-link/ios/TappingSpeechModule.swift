import ExpoModulesCore

public final class TappingSpeechModule: Module {
    private var speech: SpeechSession?
    public func definition() -> ModuleDefinition {
        Name("TappingSpeech")
        Events("speech")
        AsyncFunction("start") { (id: String, locale: String, allowNetwork: Bool) in
            MainActor.assumeIsolated {
            if self.speech == nil {
                let speech = SpeechSession()
                speech.emit = { [weak self] value in self?.sendEvent("speech", value) }
                self.speech = speech
            }
            self.speech?.start(id: id, locale: locale, allowNetwork: allowNetwork)
            }
        }.runOnQueue(.main)
        AsyncFunction("stop") { MainActor.assumeIsolated { self.speech?.stop() } }.runOnQueue(.main)
        AsyncFunction("cancel") { MainActor.assumeIsolated { self.speech?.cancel() } }.runOnQueue(.main)
        OnAppEntersBackground { Task { @MainActor in self.speech?.cancel() } }
        OnDestroy { Task { @MainActor in self.speech?.cancel(); self.speech = nil } }
    }
}
