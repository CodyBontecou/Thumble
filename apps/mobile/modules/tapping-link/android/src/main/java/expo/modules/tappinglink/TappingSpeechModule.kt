package expo.modules.tappinglink

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer as PlatformRecognizer
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.*
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.functions.Queues
import kotlinx.coroutines.*
import java.util.Locale

class TappingSpeechModule : Module() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val handler = Handler(Looper.getMainLooper())
  private var id: String? = null
  private var job: Job? = null
  private var timeout: Job? = null
  private var modern: SpeechRecognizer? = null
  private var platform: PlatformRecognizer? = null
  private var listening = false

  override fun definition() = ModuleDefinition {
    Name("TappingSpeech")
    Events("speech")
    AsyncFunction("start") { sessionId: String, language: String, allowNetwork: Boolean -> start(sessionId, language, allowNetwork) }.runOnQueue(Queues.MAIN)
    AsyncFunction("stop") { stop() }.runOnQueue(Queues.MAIN)
    AsyncFunction("cancel") { cancel() }.runOnQueue(Queues.MAIN)
    OnActivityEntersBackground { handler.post { cancel() } }
    OnDestroy { handler.post { cancel(); scope.cancel() } }
  }
  private fun event(value: Map<String, Any>) { id?.let { sendEvent("speech", value + ("id" to it)) } }
  private fun start(sessionId: String, language: String, allowNetwork: Boolean) {
    cancel()
    id = sessionId
    val context = appContext.reactContext ?: run { fail("App is unavailable."); return }
    if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      fail("Microphone access is disabled. Enable it in Settings, or type your message."); return
    }
    val locale = if (language.isEmpty()) Locale.getDefault() else Locale.forLanguageTag(language)
    event(mapOf("state" to "preparing"))
    job = scope.launch {
      try {
        // The advanced model is optional: unsupported phones/languages use the platform API.
        val client = SpeechRecognition.getClient(speechRecognizerOptions {
          this.locale = locale
          preferredMode = SpeechRecognizerOptions.Mode.MODE_ADVANCED
        })
        modern = client
        val status = client.checkStatus()
        ensureActive()
        if (status == FeatureStatus.DOWNLOADABLE) {
          event(mapOf("state" to "preparing", "engine" to "Downloading Android speech model…"))
          client.download().collect { if (it is DownloadStatus.DownloadFailed) throw IllegalStateException("Speech model download failed.") }
        }
        ensureActive()
        if (client.checkStatus() != FeatureStatus.AVAILABLE) {
          client.close(); modern = null
          startPlatform(locale, allowNetwork, sessionId)
          return@launch
        }
        listening = true
        event(mapOf("state" to "listening", "engine" to "Android advanced speech · on device"))
        armTimeout()
        var finalized = ""
        client.startRecognition(speechRecognizerRequest { audioSource = AudioSource.fromMic() }).collect { response ->
          ensureActive()
          if (id != sessionId) return@collect
          when (response) {
            is SpeechRecognizerResponse.PartialTextResponse -> event(mapOf("text" to finalized + response.text))
            is SpeechRecognizerResponse.FinalTextResponse -> { finalized += response.text; event(mapOf("text" to finalized)) }
            is SpeechRecognizerResponse.ErrorResponse -> throw response.e
            is SpeechRecognizerResponse.CompletedResponse -> { }
          }
        }
        if (id == sessionId) { event(mapOf("state" to "done")); cancel() }
      } catch (_: CancellationException) { }
      catch (error: Exception) {
        modern?.close(); modern = null
        if (id == sessionId) {
          if (listening) fail(error.message ?: "Speech recognition failed. Try again or type your message.")
          else startPlatform(locale, allowNetwork, sessionId)
        }
      }
    }
  }
  private fun startPlatform(locale: Locale, allowNetwork: Boolean, sessionId: String, forceOnline: Boolean = false) {
    val context = appContext.reactContext ?: return
    val onDevice = !forceOnline && Build.VERSION.SDK_INT >= 31 && PlatformRecognizer.isOnDeviceRecognitionAvailable(context)
    if (!onDevice && !allowNetwork) { fail("This phone needs online recognition. Enable online recognition below, or type your message."); return }
    if (!onDevice && !PlatformRecognizer.isRecognitionAvailable(context)) { fail("No speech service is installed. Try typing your message."); return }
    try {
      val recognizer = if (onDevice) PlatformRecognizer.createOnDeviceSpeechRecognizer(context) else PlatformRecognizer.createSpeechRecognizer(context)
      platform = recognizer
      recognizer.setRecognitionListener(object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) { if (id == sessionId) { listening = true; event(mapOf("state" to "listening", "engine" to if (onDevice) "Android on-device dictation" else "Android online dictation")); armTimeout() } }
        override fun onBeginningOfSpeech() { }
        override fun onRmsChanged(rmsdB: Float) { }
        override fun onBufferReceived(buffer: ByteArray?) { }
        override fun onEndOfSpeech() { if (id == sessionId) { event(mapOf("state" to "finishing")); armFinishTimeout() } }
        override fun onError(error: Int) {
          if (id != sessionId) return
          if (onDevice && allowNetwork && error in listOf(PlatformRecognizer.ERROR_LANGUAGE_UNAVAILABLE, PlatformRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED)) {
            // Explicit online opt-in permits the system provider to supply an unsupported locale.
            platform?.destroy(); platform = null
            startPlatform(locale, true, sessionId, forceOnline = true)
          } else fail(when (error) {
            PlatformRecognizer.ERROR_NO_MATCH, PlatformRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was recognized. Try again or type your message."
            PlatformRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone access is disabled. Enable it in Settings."
            PlatformRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Download this language in your phone’s speech settings, or enable online recognition."
            PlatformRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "This speech service does not support your language. Try typing instead."
            PlatformRecognizer.ERROR_NETWORK, PlatformRecognizer.ERROR_NETWORK_TIMEOUT -> "Online recognition could not connect. Try again or type your message."
            else -> "Speech recognition failed ($error). Try again or type your message."
          })
        }
        override fun onResults(results: Bundle?) { if (id == sessionId) { results?.getStringArrayList(PlatformRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { event(mapOf("text" to it)) }; event(mapOf("state" to "done")); cancel() } }
        override fun onPartialResults(results: Bundle?) { if (id == sessionId) results?.getStringArrayList(PlatformRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { event(mapOf("text" to it)) } }
        override fun onEvent(eventType: Int, params: Bundle?) { }
      })
      recognizer.startListening(intent(locale, !allowNetwork))
      armFinishTimeout(15_000)
    } catch (error: Exception) { fail(error.message ?: "Speech recognition is unavailable.") }
  }
  private fun intent(locale: Locale, offline: Boolean) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
    putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.toLanguageTag())
    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, offline)
    if (Build.VERSION.SDK_INT >= 33) putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_LATENCY)
  }
  private fun armTimeout() { timeout?.cancel(); timeout = scope.launch { delay(55_000); stop() } }
  private fun armFinishTimeout(ms: Long = 5_000) { timeout?.cancel(); timeout = scope.launch { delay(ms); fail("Recognition timed out. Review the text or try again.") } }
  private fun stop() {
    if (id == null) return
    if (!listening && platform == null) { event(mapOf("state" to "done")); cancel(); return }
    event(mapOf("state" to "finishing")); armFinishTimeout()
    platform?.stopListening()
    val expected = id
    modern?.let { client -> scope.launch { try { client.stopRecognition() } catch (error: Exception) { if (id == expected) fail(error.message ?: "Could not finish recognition.") } } }
  }
  private fun fail(message: String) { event(mapOf("error" to message)); cancel() }
  private fun cancel() {
    id = null; listening = false
    timeout?.cancel(); timeout = null
    job?.cancel(); job = null
    platform?.cancel(); platform?.destroy(); platform = null
    modern?.close(); modern = null
  }
}
