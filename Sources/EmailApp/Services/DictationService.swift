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
    private let engine = AVAudioEngine()

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    // MARK: - Permission

    /// Two separate grants: transcription and the microphone itself. Both are
    /// required, and iOS asks for them independently.
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
        guard !isRecording else { return }
        guard await requestPermission() else { return }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is not available right now."
            return
        }

        transcript = ""
        error = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            let input = engine.inputNode
            // The tap must use the hardware's own format; a mismatch throws at
            // installTap rather than failing quietly.
            let format = input.outputFormat(forBus: 0)
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
                    if taskError != nil && self.transcript.isEmpty {
                        self.error = "Nothing was heard. Try again."
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        guard isRecording || engine.isRunning else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()

        request = nil
        task = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func reset() {
        transcript = ""
        error = nil
    }
}
