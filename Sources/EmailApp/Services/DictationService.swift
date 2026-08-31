import Foundation
import Speech
import AVFoundation
import Observation

/// Hold-to-talk speech recognition.
///
/// On-device where the hardware supports it (`requiresOnDeviceRecognition`),
/// which keeps the audio off Apple's servers as well as working with no
/// signal. Falls back to server recognition when the locale has no on-device
/// model, since a dictation button that silently does nothing is worse than
/// one that uses the network.
@Observable
@MainActor
final class DictationService {
    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?

    /// Set synchronously, before the first await. `isRecording` only becomes
    /// true once the engine is running, and a press-and-hold gesture fires
    /// repeatedly -- so guarding on `isRecording` alone lets several starts
    /// stack up, each installing a tap on the same bus. A second tap raises an
    /// Objective-C exception that Swift cannot catch, and the app dies.
    private var isStarting = false

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    // MARK: - Permission

    /// Two separate grants: transcription and the microphone itself. iOS asks
    /// for them independently and both are required.
    func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else {
            error = "Speech recognition permission was declined."
            return false
        }

        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        if !microphone { error = "Microphone permission was declined." }
        return microphone
    }

    // MARK: - Recording

    func start() async {
        guard !isStarting, !isRecording else { return }
        isStarting = true
        defer { isStarting = false }

        guard await requestPermission() else { return }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is not available right now."
            return
        }

        // A permission prompt can take long enough for the user to let go.
        // Bail rather than starting a recording nobody is holding.
        guard !isRecording else { return }

        transcript = ""
        error = nil

        // A fresh engine each time. Reusing one across start/stop cycles is
        // where stale taps and half-torn-down graphs come from.
        let engine = AVAudioEngine()
        self.engine = engine

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)

            // Before the session is live the hardware format can come back as
            // 0Hz. installTap throws an uncatchable exception on that, so check
            // rather than let it take the process down.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                error = "The microphone is not available right now."
                teardown()
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            engine.prepare()
            try engine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, taskError in
                guard let self else { return }
                Task { @MainActor in
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if taskError != nil, self.transcript.isEmpty, self.isRecording {
                        self.error = "Nothing was heard. Try again."
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            teardown()
        }
    }

    func stop() {
        guard isRecording else {
            // Released before the engine came up: make sure nothing is left
            // half-configured for the next press.
            teardown()
            return
        }
        isRecording = false
        teardown()
    }

    /// Safe to call in any state, including a partially built one.
    private func teardown() {
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil

        request?.endAudio()
        request = nil

        task?.finish()
        task = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func reset() {
        transcript = ""
        error = nil
    }
}
