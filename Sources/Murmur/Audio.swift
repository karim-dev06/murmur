import AVFoundation

/// Records the default microphone as 16 kHz mono floats, the format both speech engines want.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Called on the audio thread with the loudness of each small chunk.
    var onLevel: ((Float) -> Void)?
    /// Called on the audio thread with each small chunk of 16 kHz samples.
    var onChunk: (([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []

    func start() throws {
        // A fresh engine each time picks up whatever microphone is current (AirPods, external mic).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw MurmurError("No microphone found") }
        guard let converter = AVAudioConverter(from: inFormat, to: Self.format) else { throw MurmurError("Microphone format not supported") }
        converter.downmix = true

        lock.withLock { samples.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self, let chunk = AudioConvert.convert(buffer, with: converter, endOfStream: false) else { return }
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
            self.onLevel?(AudioCheck.rms(chunk[...]))
            self.onChunk?(chunk)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return lock.withLock {
            let out = samples
            samples = []
            return out
        }
    }
}

enum AudioConvert {
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, endOfStream: Bool) -> [Float]? {
        let ratio = AudioRecorder.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioRecorder.format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MurmurError("Could not read \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: AudioRecorder.format) else {
            throw MurmurError("Audio format not supported")
        }
        converter.downmix = true
        return convert(buffer, with: converter, endOfStream: true) ?? []
    }
}

enum AudioCheck {
    static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for x in s { sum += x * x }
        return (sum / Float(s.count)).squareRoot()
    }

    /// True when the clip is long enough and somewhere gets louder than room noise.
    static func hasSpeech(_ samples: [Float]) -> Bool {
        let window = Int(AudioRecorder.sampleRate * 0.05)
        guard samples.count >= Int(AudioRecorder.sampleRate * 0.3) else { return false }
        var start = 0
        while start + window <= samples.count {
            if rms(samples[start ..< start + window]) > 0.004 { return true }
            start += window
        }
        return false
    }
}

enum WAV {
    static func data(_ samples: [Float], sampleRate: Int = Int(AudioRecorder.sampleRate)) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let size = UInt32(samples.count * 2)
        d.append("RIFF"); u32(36 + size); d.append("WAVE")
        d.append("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data"); u32(size)
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
