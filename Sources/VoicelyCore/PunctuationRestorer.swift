@preconcurrency import CoreML
import Foundation

/// Restores punctuation and capitalization on GigaAM Multilingual output.
protocol PunctuationRestorer: Sendable {
    /// `text` is lowercase, space-separated, no punctuation. `language` is the
    /// script-detected language (ru/en/... or nil).
    func restore(_ text: String, language: String?) async throws -> String
}

/// Turns a per-word predicted label into a cased, punctuated word. Two schemes:
/// RUPunct (prefix + named suffix) and rpunct (two-char `<punct><case>`).
enum PunctuationLabelDecoder {
    private static let ruSuffixPunct: [String: String] = [
        "O": "", "PERIOD": ".", "COMMA": ",", "QUESTION": "?", "VOSKL": "!",
        "DVOETOCHIE": ":", "PERIODCOMMA": ";", "TIRE": " —", "DEFIS": "-",
        "QUESTIONVOSKL": "?!", "MNOGOTOCHIE": "…",
    ]

    static func apply(word: String, label: String, scheme: PunctuationLabelScheme) -> String {
        switch scheme {
        case .ruPunct: return applyRU(word: word, label: label)
        case .rpunct: return applyRpunct(word: word, label: label)
        }
    }

    private static func applyRU(word: String, label: String) -> String {
        var token = word
        let suffix: String
        if label.hasPrefix("UPPER_TOTAL_") {
            token = token.uppercased()
            suffix = String(label.dropFirst("UPPER_TOTAL_".count))
        } else if label.hasPrefix("UPPER_") {
            token = token.prefix(1).uppercased() + token.dropFirst()
            suffix = String(label.dropFirst("UPPER_".count))
        } else if label.hasPrefix("LOWER_") {
            suffix = String(label.dropFirst("LOWER_".count))
        } else {
            suffix = label
        }
        return token + (ruSuffixPunct[suffix] ?? "")
    }

    /// rpunct label = two characters: [punct][case]. punct in O . ! , : ; ' - ?
    /// (O = none), case O = lowercase, U = uppercase first letter.
    private static func applyRpunct(word: String, label: String) -> String {
        guard label.count == 2 else { return word }
        let chars = Array(label)
        var token = word
        if chars[1] == "U" { token = token.prefix(1).uppercased() + token.dropFirst() }
        let punct: String
        switch chars[0] {
        case ".": punct = "."
        case "!": punct = "!"
        case ",": punct = ","
        case ":": punct = ":"
        case ";": punct = ";"
        case "'": punct = "'"
        case "-": punct = "-"
        case "?": punct = "?"
        default: punct = ""   // 'O'
        }
        return token + punct
    }

    /// Capitalize the first letter of each sentence: at text start and after a
    /// sentence-ending mark. Token models often leave the word after a period
    /// lowercase, so this cleans that up (and is the whole floor for languages
    /// without a learned model).
    static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result += ch.uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" || ch == "…" {
                    capitalizeNext = true
                }
            }
        }
        return result
    }
}

/// Rule-based floor for languages without a learned model: capitalize the first
/// letter of the text (and after sentence marks, though GigaAM emits none for
/// these languages). Non-destructive.
struct RuleBasedPunctuationRestorer: PunctuationRestorer {
    func restore(_ text: String, language: String?) async throws -> String {
        PunctuationLabelDecoder.capitalizeSentences(text)
    }
}

private struct PunctuationTokenizerMeta: Decodable {
    let clsID: Int32
    let sepID: Int32
    let padID: Int32
    let unkID: Int32
    let maxLen: Int

    private enum CodingKeys: String, CodingKey {
        case clsID = "cls_id", sepID = "sep_id", padID = "pad_id"
        case unkID = "unk_id", maxLen = "max_len"
    }
}

private struct PunctRuntime: @unchecked Sendable {
    let model: MLModel
    let tokenizer: WordPieceTokenizer
    let labels: [String]
    let scheme: PunctuationLabelScheme
    let maxLen: Int
}

/// Core ML punctuation restorer covering Russian and English via two BERT
/// token-classification models; other languages fall back to the rule floor.
/// Each language model loads lazily on first use, one restore at a time.
final class CoreMLPunctuationRestorer: @unchecked Sendable, PunctuationRestorer {
    private let baseDirectory: URL
    private let stateLock = NSLock()
    private var runtimes: [String: PunctRuntime] = [:]
    private var loading: Set<String> = []
    private let ruleBased = RuleBasedPunctuationRestorer()

    private enum Constants {
        static let computeUnits: MLComputeUnits = .cpuAndGPU
    }

    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/voicely/models")
    }

    func restore(_ text: String, language: String?) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard let source = PunctuationCatalog.source(for: language) else {
            return try await ruleBased.restore(trimmed, language: language)
        }
        let runtime: PunctRuntime
        do {
            runtime = try await loadIfNeeded(source)
        } catch {
            return try await ruleBased.restore(trimmed, language: language)
        }
        do {
            return try applyModel(runtime, to: trimmed)
        } catch {
            return try await ruleBased.restore(trimmed, language: language)
        }
    }

    private func applyModel(_ runtime: PunctRuntime, to text: String) throws -> String {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return text }
        let enc = runtime.tokenizer.encode(words: words)

        let maxLen = runtime.maxLen
        let ids = try GigaAMDSP.makeInt32Array(shape: [1, maxLen], values: padded(enc.ids, to: maxLen))
        var maskValues = [Int32](repeating: 0, count: maxLen)
        for i in 0..<min(enc.validCount, maxLen) { maskValues[i] = 1 }
        let mask = try GigaAMDSP.makeInt32Array(shape: [1, maxLen], values: maskValues)
        let types = try GigaAMDSP.makeInt32Array(shape: [1, maxLen], values: [Int32](repeating: 0, count: maxLen))

        let out = try runtime.model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": ids,
            "attention_mask": mask,
            "token_type_ids": types,
        ]))
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue else {
            throw TranscriberError.whisperKitFailed("punctuation model output missing")
        }

        let numLabels = runtime.labels.count
        var pieces: [String] = []
        pieces.reserveCapacity(words.count)
        for wi in words.indices {
            guard let tokenPos = enc.wordIndex.firstIndex(of: wi), tokenPos < maxLen else {
                pieces.append(words[wi]); continue
            }
            var best = 0
            var bestVal = -Float.infinity
            for l in 0..<numLabels {
                let v = logits.float(at: [0, tokenPos, l])
                if v > bestVal { bestVal = v; best = l }
            }
            pieces.append(PunctuationLabelDecoder.apply(word: words[wi], label: runtime.labels[best], scheme: runtime.scheme))
        }
        return PunctuationLabelDecoder.capitalizeSentences(pieces.joined(separator: " "))
    }

    private func padded(_ values: [Int32], to length: Int) -> [Int32] {
        if values.count >= length { return Array(values.prefix(length)) }
        return values + [Int32](repeating: 0, count: length - values.count)
    }

    // MARK: - Loading

    private func loadIfNeeded(_ source: PunctuationModelSource) async throws -> PunctRuntime {
        if let r = stateLock.withLock({ runtimes[source.language] }) { return r }
        let becameLoader = stateLock.withLock { () -> Bool in
            guard runtimes[source.language] == nil, !loading.contains(source.language) else { return false }
            loading.insert(source.language)
            return true
        }
        if becameLoader {
            do {
                let loaded = try await Self.load(source, baseDirectory: baseDirectory)
                stateLock.withLock { runtimes[source.language] = loaded; _ = loading.remove(source.language) }
                return loaded
            } catch {
                stateLock.withLock { _ = loading.remove(source.language) }
                throw error
            }
        }
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let r = stateLock.withLock({ runtimes[source.language] }) { return r }
            if !stateLock.withLock({ loading.contains(source.language) }) { break }
        }
        return try await loadIfNeeded(source)
    }

    private static func load(_ source: PunctuationModelSource, baseDirectory: URL) async throws -> PunctRuntime {
        try GigaAMPlatformReadiness.requireSupported()
        let root = baseDirectory.appendingPathComponent(source.directoryName)
        let sourceRoot = root.appendingPathComponent("source")
        let compiledRoot = root.appendingPathComponent("compiled")
        let fileSystem = FoundationGigaAMAssetFileSystem()
        try fileSystem.createPrivateDirectory(at: root)
        try fileSystem.createPrivateDirectory(at: sourceRoot)
        try fileSystem.createPrivateDirectory(at: compiledRoot)

        let downloader = GigaAMAssetDownloader(
            assets: source.assets,
            revision: source.revision,
            fileSystem: fileSystem,
            resolveURL: { source.resolveURL(for: $0) }
        )
        _ = try await downloader.ensureAssets(in: sourceRoot, additionalRequiredBytes: source.totalExpectedByteCount)
        try GigaAMSecureStorage.hardenTree(at: sourceRoot)

        let decoder = JSONDecoder()
        let labels = try decoder.decode([String].self, from: Data(contentsOf: sourceRoot.appendingPathComponent("labels.json")))
        let meta = try decoder.decode(PunctuationTokenizerMeta.self, from: Data(contentsOf: sourceRoot.appendingPathComponent("tokenizer_meta.json")))
        let vocabText = try String(contentsOf: sourceRoot.appendingPathComponent("vocab.txt"), encoding: .utf8)
        let vocabLines = vocabText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let tokenizer = WordPieceTokenizer(
            vocabLines: vocabLines,
            meta: .init(clsID: meta.clsID, sepID: meta.sepID, padID: meta.padID, unkID: meta.unkID, maxLen: meta.maxLen)
        )

        let compiledURL = compiledRoot.appendingPathComponent(source.compiledName)
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            let tmp = try await MLModel.compileModel(at: sourceRoot.appendingPathComponent(source.packageName))
            if FileManager.default.fileExists(atPath: compiledURL.path) {
                try? FileManager.default.removeItem(at: compiledURL)
            }
            try FileManager.default.moveItem(at: tmp, to: compiledURL)
        }
        let config = MLModelConfiguration()
        config.computeUnits = Constants.computeUnits
        let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)

        return PunctRuntime(model: mlModel, tokenizer: tokenizer, labels: labels, scheme: source.scheme, maxLen: meta.maxLen)
    }
}
