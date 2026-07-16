import Foundation

/// Minimal WordPiece tokenizer for the punctuation BERT model. Input is already
/// lowercase, space-separated words with no punctuation (exactly the GigaAM CTC
/// output), so basic tokenization is a whitespace split; each word is then
/// greedily split into the longest matching subwords, with "##" continuations.
/// Kept dependency-free on purpose — the model's vocab drives everything.
struct WordPieceTokenizer {
    private let vocab: [String: Int32]
    let unkID: Int32
    let clsID: Int32
    let sepID: Int32
    let padID: Int32
    let maxLen: Int
    private let maxWordChars = 100

    init(vocabLines: [String], meta: Meta) {
        var v: [String: Int32] = [:]
        v.reserveCapacity(vocabLines.count)
        for (i, token) in vocabLines.enumerated() where !token.isEmpty {
            // First occurrence wins (BERT vocab has unique tokens per line).
            if v[token] == nil { v[token] = Int32(i) }
        }
        vocab = v
        unkID = meta.unkID
        clsID = meta.clsID
        sepID = meta.sepID
        padID = meta.padID
        maxLen = meta.maxLen
    }

    struct Meta {
        let clsID: Int32
        let sepID: Int32
        let padID: Int32
        let unkID: Int32
        let maxLen: Int
    }

    struct Encoding {
        /// Token ids including [CLS]/[SEP], length == validCount.
        let ids: [Int32]
        /// For each token, the index of the source word it belongs to, or -1
        /// for [CLS]/[SEP]. Used to read one label per word (first subtoken).
        let wordIndex: [Int]
        let validCount: Int
    }

    /// Tokenize `words` (already lowercase, no punctuation). Truncates to fit
    /// maxLen including the two special tokens.
    func encode(words: [String]) -> Encoding {
        var ids: [Int32] = [clsID]
        var wordIndex: [Int] = [-1]
        let budget = maxLen - 1  // leave room for [SEP]

        outer: for (wi, word) in words.enumerated() {
            let pieces = wordPieces(word)
            // Keep whole words together: stop before overflowing.
            if ids.count + pieces.count > budget { break outer }
            for (pi, pieceID) in pieces.enumerated() {
                ids.append(pieceID)
                // Only the first subtoken of a word carries the word's label.
                wordIndex.append(pi == 0 ? wi : -1)
            }
        }
        ids.append(sepID)
        wordIndex.append(-1)
        return Encoding(ids: ids, wordIndex: wordIndex, validCount: ids.count)
    }

    private func wordPieces(_ word: String) -> [Int32] {
        let chars = Array(word)
        if chars.count > maxWordChars { return [unkID] }
        var result: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var matched: Int32?
            while end > start {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if let id = vocab[sub] {
                    matched = id
                    break
                }
                end -= 1
            }
            guard let id = matched else {
                // Unknown character run: the whole word is [UNK] (BERT behavior).
                return [unkID]
            }
            result.append(id)
            start = end
        }
        return result.isEmpty ? [unkID] : result
    }
}
