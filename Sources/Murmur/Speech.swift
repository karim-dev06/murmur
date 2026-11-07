import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech recognition (macOS 26+). Nothing to install: macOS fetches the model itself.
final class AppleSpeechEngine: @unchecked Sendable {
    let name = "Apple speech"
    private let locale: Locale

    init(localeID: String) {
        locale = Locale(identifier: localeID)
    }

    func prepare() async throws {
        let wanted = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw MurmurError("Apple speech doesn't support \(wanted)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
        try WAV.data(samples).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        return try await withTimeout(seconds: 60) { [locale] in
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try await analyzer.setContext(context)
            }
            let file = try AVAudioFile(forReading: url)
            async let text = Self.collect(transcriber)
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            return (try await text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func collect(_ transcriber: SpeechTranscriber) async throws -> String {
        var out = ""
        for try await result in transcriber.results where result.isFinal {
            out += String(result.text.characters)
        }
        return out
    }

    func startLive(vocabulary: [String], onText: @escaping @Sendable (String) -> Void,
                   onSettled: (@Sendable (String) -> Void)? = nil) -> LiveTranscription {
        LiveTranscription(locale: locale, vocabulary: vocabulary, onText: onText, onSettled: onSettled)
    }

}

private func trace(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["MURMUR_DEBUG"] != nil { FileHandle.standardError.write(Data("[live] \(message())\n".utf8)) }
}

/// Transcribes while you talk, so words show up live and the text is ready the moment you let go.
final class LiveTranscription: @unchecked Sendable {
    private let chunks: AsyncStream<[Float]>.Continuation
    private let work: Task<String, Error>

    /// `onText` gets everything heard so far. `onSettled` gets each piece once it will no longer change.
    init(locale: Locale, vocabulary: [String], onText: @escaping @Sendable (String) -> Void,
         onSettled: (@Sendable (String) -> Void)? = nil) {
        // Audio arrives before the analyzer is ready. This stream holds it until then.
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        chunks = continuation
        work = Task {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try await analyzer.setContext(context)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let converter = AVAudioConverter(from: AudioRecorder.format, to: format) else {
                throw MurmurError("Live speech isn't available")
            }
            let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
            let collector = Task { () throws -> String in
                // Final pieces are settled. The newest piece keeps changing until it settles.
                var settled = ""
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        settled += text
                        onSettled?(text)
                    }
                    onText(result.isFinal ? settled : settled + text)
                }
                return settled
            }
            trace("format \(format)")
            try await analyzer.start(inputSequence: input)
            trace("started")
            for await chunk in stream {
                if let buffer = Self.buffer(chunk, to: format, with: converter) { feed.yield(AnalyzerInput(buffer: buffer)) }
            }
            feed.finish()
            trace("input finished")
            if Task.isCancelled {
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                throw CancellationError()
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            trace("finalized")
            return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Called on the audio thread.
    func append(_ chunk: [Float]) {
        chunks.yield(chunk)
    }

    func finish() async throws -> String {
        chunks.finish()
        return try await withTimeout(seconds: 15) { [work] in try await work.value }
    }

    func cancel() {
        work.cancel()
        chunks.finish()
    }

    private static func buffer(_ samples: [Float], to format: AVAudioFormat, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let source = AVAudioPCMBuffer(pcmFormat: AudioRecorder.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let ratio = format.sampleRate / AudioRecorder.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? out : nil
    }
}

enum TextFilter {
    static func tidy(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]|\((?:silence|music|blank_audio|inaudible)[^)]*\)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    /// Fixes tech words that speech recognition often gets wrong, sentence by sentence.
    static func fixTechWords(_ text: String) -> String {
        guard let sentences = try? NSRegularExpression(pattern: #"[^.!?\n]+[.!?]*"#) else { return text }
        var out = text
        let ns = text as NSString
        for match in sentences.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            out = (out as NSString).replacingCharacters(in: match.range, with: TechWords.fix(sentence: ns.substring(with: match.range)))
        }
        return out
    }

    /// Lines that start "First…", "Second…", "Third…" in order become "1.", "2.", "3.".
    /// Tidy-up usually does this itself. This catches the times it splits the lines but keeps the words.
    static func numberOrdinalLines(_ text: String) -> String {
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        var lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            var run = 0
            while i + run < lines.count, run < ordinals.count,
                  lines[i + run].range(of: "^(and )?\(ordinals[run])\\b[,:]?\\s*", options: [.regularExpression, .caseInsensitive]) != nil {
                run += 1
            }
            if run >= 2 {
                for k in 0 ..< run {
                    var line = lines[i + k].replacingOccurrences(of: "^(and )?\(ordinals[k])\\b[,:]?\\s*", with: "", options: [.regularExpression, .caseInsensitive])
                    if let first = line.first { line = first.uppercased() + line.dropFirst() }
                    lines[i + k] = "\(k + 1). " + line
                }
                i += run
            } else {
                i += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Spoken "new line" and "new paragraph" become real line breaks.
    static func applyVoiceCommands(_ text: String) -> String {
        var t = text
        for (phrase, replacement) in [("new paragraph", "\n\n"), ("new line", "\n")] {
            t = t.replacingOccurrences(of: #"[ ,.;:]*\b\#(phrase)\b[ ,.;:]*"#, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        // Capitalize the first letter after each break.
        let lines = t.components(separatedBy: "\n").map { line -> String in
            guard let first = line.first else { return line }
            return first.uppercased() + line.dropFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
