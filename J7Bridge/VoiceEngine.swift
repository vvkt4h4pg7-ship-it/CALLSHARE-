import Foundation
import AVFoundation

final class VoiceEngine: NSObject {
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private var isRunning = false
    private var converter: AVAudioConverter?
    private var useSpeaker = true
    private var muted = false

    var onAMRPacket: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?

    private let codec = AMRCodecAdapter()
    private var pcmAccumulator: [Int16] = []

    func setSpeakerDefault(_ enabled: Bool) {
        useSpeaker = enabled
        if isRunning { applySessionCategory() }
    }

    func setMuted(_ value: Bool) {
        muted = value
        onStatus?(value ? "MUTED" : "UNMUTED")
    }

    /// The session is configured and the microphone is opened only after CallKit
    /// has activated the audio session for an actual call.
    func start() {
        guard !isRunning else { return }
        do {
            applySessionCategory()
            let input = audioEngine.inputNode
            let hardwareFormat = input.inputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                throw NSError(domain: "J7Bridge.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No input audio route"])
            }

            let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 8_000,
                                       channels: 1,
                                       interleaved: true)!
            converter = AVAudioConverter(from: hardwareFormat, to: target)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
                self?.processPCM(buffer, target: target)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
            pcmAccumulator.removeAll(keepingCapacity: true)
            onStatus?("OPEN / 8k capture active")
        } catch {
            inputRemoveTapSafely()
            converter = nil
            onStatus?("ERROR \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning || audioEngine.isRunning else { return }
        inputRemoveTapSafely()
        audioEngine.stop()
        converter = nil
        pcmAccumulator.removeAll(keepingCapacity: true)
        isRunning = false
        onStatus?("CLOSED")
    }

    func receiveAMR(_ packet: Data) {
        guard !packet.isEmpty else { return }
        // The supplied Android source uses AMR-NB. The current iOS project has
        // no iOS-compatible AMR implementation, so transport reception is kept
        // here until the codec adapter is linked.
        _ = codec.decode(packet)
    }

    private func applySessionCategory() {
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if useSpeaker { options.insert(.defaultToSpeaker) }
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? audioSession.setPreferredSampleRate(8_000)
    }

    private func inputRemoveTapSafely() {
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func processPCM(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard isRunning, let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil else { return }
        emit8kFrames(output)
    }

    private func emit8kFrames(_ buffer: AVAudioPCMBuffer) {
        guard let pointer = buffer.int16ChannelData?[0] else { return }
        pcmAccumulator.append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))

        while pcmAccumulator.count >= 160 {
            let frame = Array(pcmAccumulator.prefix(160))
            pcmAccumulator.removeFirst(160)
            guard !muted else { continue }
            if let amr = codec.encode160(frame) { onAMRPacket?(amr) }
        }
    }
}

final class AMRCodecAdapter {
    func encode160(_ pcm8k: [Int16]) -> Data? {
        guard pcm8k.count == 160 else { return nil }
        return nil
    }

    func decode(_ amr: Data) -> [Int16]? {
        _ = amr
        return nil
    }
}
