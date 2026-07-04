// FlowLocal — microphone capture at 16 kHz mono.

import AVFoundation

final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll(keepingCapacity: true)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "FlowLocal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        return result
    }

    /// Copy of everything captured so far — for live preview while recording.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var durationSoFar: Double {
        lock.lock()
        let n = samples.count
        lock.unlock()
        return Double(n) / 16000.0
    }

    static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        let sampleRate: UInt32 = 16000
        let dataSize = UInt32(samples.count * 2)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            append(Int16(clamped * 32767.0))
        }
        return data
    }
}
