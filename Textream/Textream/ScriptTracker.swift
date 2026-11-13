//
//  ScriptTracker.swift
//  Textream
//
//  Strict word-run tracker for Word Tracking mode.
//
//  The reading position only ever advances when the speaker has said
//  consecutive words that are also consecutive in the script:
//
//  * While reading, each new word must directly follow the previously
//    matched word, both in the speech and in the script.
//  * After going off-script, nothing moves — for as long as it takes — until
//    two consecutive script words are heard at the place the speaker stopped
//    (or a little ahead of it, with stricter requirements the further ahead).
//
//  There is deliberately no character-level or single-word matching here:
//  those are what let the highlight creep forward during an ad-lib.
//

import Foundation

struct ScriptTracker {
    struct Configuration {
        /// How many already-read words before the current position may take
        /// part in a match (lets the speaker re-read the end of a sentence).
        var lookBehindWords = 12
        /// A resume this few words ahead is treated as a recognizer slip
        /// (one or two misheard words) rather than a real skip.
        var slipWords = 2
        var slipMinLetters = 5
        /// Skipping up to this many words ahead (about a sentence) needs
        /// three consecutive words — two are only enough at the exact spot.
        var nearSkipWords = 12
        /// Skipping further (up to this many words) needs a longer phrase.
        /// Beyond this distance the tracker never jumps on its own.
        var farSkipWords = 40
        var farSkipMinLetters = 12
        /// Only the most recent spoken words are examined on each update.
        var transcriptTailWords = 30
    }

    private struct Token {
        let text: String
        /// Read-progress character offset once this token has been spoken.
        let endOffset: Int
        /// Matching weight in half-words: a CJK character counts as half a
        /// word, so "two consecutive words" means four characters there.
        let weight: Int
    }

    private struct Candidate {
        let distance: Int
        let scriptEnd: Int
        let spokenEnd: Int
    }

    private enum Match {
        case none, fuzzy, exact
    }

    var configuration = Configuration()

    private var tokens: [Token] = []
    /// Index of the next script token the speaker is expected to say.
    private var nextTokenIndex = 0
    /// Number of words at the start of the current transcript that have
    /// already been used for (or passed over by) an accepted match.
    private var consumedSpokenWords = 0
    /// When set, everything currently in the transcript is ignored on the
    /// next update (used when the position changed underneath the tracker).
    private var discardsCurrentTranscript = false

    // MARK: - Setup

    init() {}

    /// - Parameter words: the display words of the script. The read-progress
    ///   offsets returned by `process` index into `words.joined(separator: " ")`.
    init(words: [String], charOffset: Int = 0) {
        setScript(words: words, charOffset: charOffset)
        consumedSpokenWords = 0
    }

    /// Replace the script (e.g. a live edit) while the transcript continues.
    mutating func setScript(words: [String], charOffset: Int) {
        tokens = Self.scriptTokens(from: words)
        nextTokenIndex = tokenIndex(forCharOffset: charOffset)
    }

    /// Move the reading position. `discardingCurrentTranscript` should be
    /// true when the transcript still contains speech from before the move.
    mutating func jump(toCharOffset charOffset: Int, discardingCurrentTranscript: Bool = false) {
        nextTokenIndex = tokenIndex(forCharOffset: charOffset)
        consumedSpokenWords = 0
        discardsCurrentTranscript = discardingCurrentTranscript
    }

    /// Call when the recognizer starts a fresh transcript.
    mutating func resetTranscript() {
        consumedSpokenWords = 0
        discardsCurrentTranscript = false
    }

    private func tokenIndex(forCharOffset charOffset: Int) -> Int {
        tokens.firstIndex(where: { $0.endOffset > charOffset }) ?? tokens.count
    }

    // MARK: - Matching

    /// Feed the full transcript of the current recognition task.
    /// - Returns: the new read-progress character offset if the speaker
    ///   advanced through the script, otherwise nil (position holds).
    mutating func process(transcript: String) -> Int? {
        let spoken = Self.spokenTokens(from: transcript)

        if discardsCurrentTranscript {
            discardsCurrentTranscript = false
            consumedSpokenWords = spoken.count
            return nil
        }
        if spoken.count < consumedSpokenWords - 2 {
            // The recognizer dropped the earlier part of the transcript
            // (it does this after a long pause): everything left is new.
            consumedSpokenWords = 0
        } else {
            // A revision merged a word or two.
            consumedSpokenWords = min(consumedSpokenWords, spoken.count)
        }

        guard !spoken.isEmpty, nextTokenIndex < tokens.count else { return nil }

        if tokens.count == 1 {
            // A one-word script has no pair to wait for.
            guard spoken[consumedSpokenWords...].contains(tokens[0].text) else { return nil }
            nextTokenIndex = 1
            consumedSpokenWords = spoken.count
            return tokens[0].endOffset
        }

        var advanced = false
        while nextTokenIndex < tokens.count,
              let candidate = bestCandidate(in: spoken) {
            nextTokenIndex = candidate.scriptEnd + 1
            consumedSpokenWords = candidate.spokenEnd + 1
            advanced = true
        }
        return advanced ? tokens[nextTokenIndex - 1].endOffset : nil
    }

    /// Finds the best run of consecutive spoken words that matches
    /// consecutive script words and legitimately moves the position forward.
    private func bestCandidate(in spoken: [String]) -> Candidate? {
        let position = nextTokenIndex
        let windowStart = max(0, position - configuration.lookBehindWords)
        let windowEnd = min(tokens.count, position + configuration.farSkipWords + 8)
        let width = windowEnd - windowStart
        guard width > 0 else { return nil }

        let tailStart = max(0, spoken.count - configuration.transcriptTailWords)
        // previous[k] / current[k]: length of the matching run that ends at
        // the previous / current spoken word and script token windowStart + k.
        var previous = [Int](repeating: 0, count: width)
        var current = [Int](repeating: 0, count: width)
        var best: Candidate?

        for spokenIndex in tailStart..<spoken.count {
            let word = spoken[spokenIndex]
            for k in 0..<width {
                let scriptIndex = windowStart + k
                if Self.match(script: tokens[scriptIndex].text, spoken: word) == .none {
                    current[k] = 0
                    continue
                }
                let runLength = (k > 0 ? previous[k - 1] : 0) + 1
                current[k] = runLength

                guard runLength >= 2,
                      scriptIndex >= position,
                      spokenIndex >= consumedSpokenWords,
                      let distance = acceptedDistance(
                        spoken: spoken,
                        spokenEnd: spokenIndex,
                        scriptEnd: scriptIndex,
                        runLength: runLength
                      ) else { continue }

                let candidate = Candidate(distance: distance, scriptEnd: scriptIndex, spokenEnd: spokenIndex)
                if let existing = best {
                    let isBetter = (candidate.distance, -candidate.scriptEnd, -candidate.spokenEnd)
                        < (existing.distance, -existing.scriptEnd, -existing.spokenEnd)
                    if isBetter { best = candidate }
                } else {
                    best = candidate
                }
            }
            swap(&previous, &current)
        }
        return best
    }

    /// Decides whether a matching run may move the position.
    /// - Returns: how many unread script words the move skips, or nil if the
    ///   run is not strong enough evidence.
    private func acceptedDistance(
        spoken: [String],
        spokenEnd: Int,
        scriptEnd: Int,
        runLength: Int
    ) -> Int? {
        let position = nextTokenIndex
        let spokenStart = spokenEnd - runLength + 1
        let scriptStart = scriptEnd - runLength + 1
        let newLength = spokenEnd - max(spokenStart, consumedSpokenWords) + 1

        if newLength == 1 {
            // Continuation: one new word directly after speech that was
            // already matched, and directly after the script words that
            // speech was matched to.
            let diagonalDrift = (spokenEnd - scriptEnd) - (consumedSpokenWords - position)
            return scriptStart < position && abs(diagonalDrift) <= 1 ? 0 : nil
        }

        // Resume: two or more new consecutive words.
        let newScriptStart = scriptEnd - newLength + 1
        let newSpokenStart = spokenEnd - newLength + 1
        var weight = 0
        var letters = 0
        var hasExactMatch = false
        for offset in 0..<newLength {
            let token = tokens[newScriptStart + offset]
            weight += token.weight
            letters += token.text.count
            if Self.match(script: token.text, spoken: spoken[newSpokenStart + offset]) == .exact {
                hasExactMatch = true
            }
        }
        // "Two consecutive words", at least one of them heard exactly.
        guard weight >= 4, hasExactMatch else { return nil }

        let distance = max(0, newScriptStart - position)
        let config = configuration
        let accepted: Bool
        if distance == 0 {
            accepted = true
        } else if distance <= config.slipWords {
            accepted = weight >= 6 || letters >= config.slipMinLetters
        } else if distance <= config.nearSkipWords {
            accepted = weight >= 6
        } else if distance <= config.farSkipWords {
            accepted = weight >= 8 || (weight >= 6 && letters >= config.farSkipMinLetters)
        } else {
            accepted = false
        }
        return accepted ? distance : nil
    }

    private static func match(script: String, spoken: String) -> Match {
        if script == spoken { return .exact }
        let scriptCount = script.count
        let spokenCount = spoken.count
        let shorter = min(scriptCount, spokenCount)
        let difference = abs(scriptCount - spokenCount)
        // Short words must be heard exactly: fuzzy matches on "the", "and",
        // "for"… are the main source of false advances.
        guard shorter >= 4 else { return .none }
        // Inflections and partial hypotheses: "walk" / "walking".
        if difference <= 3 && (script.hasPrefix(spoken) || spoken.hasPrefix(script)) {
            return .fuzzy
        }
        let allowed = shorter >= 8 ? 2 : 1
        guard difference <= allowed else { return .none }
        return editDistance(script, spoken) <= allowed ? .fuzzy : .none
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = a[i - 1] == b[j - 1] ? diagonal : min(diagonal, above, row[j - 1]) + 1
                diagonal = above
            }
        }
        return row[b.count]
    }

    // MARK: - Tokenizing

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12",
    ]

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}"]

    /// Splits one display word into normalized matchable pieces
    /// ("state-of-the-art" → state, of, the, art; "don't" → dont).
    /// `end` is the number of characters of `word` covered once the piece
    /// (and the separator after it) has been spoken.
    private static func pieces(of word: String) -> [(text: String, end: Int)] {
        var result: [(text: String, end: Int)] = []
        var buffer = ""
        var index = 0
        for character in word {
            index += 1
            if character.isLetter || character.isNumber {
                buffer.append(character)
            } else if !apostrophes.contains(character), !buffer.isEmpty {
                result.append((normalize(buffer), index))
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            result.append((normalize(buffer), index))
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return numberWords[folded] ?? folded
    }

    private static func isSingleCJKCharacter(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return scalar.isCJK
    }

    private static func scriptTokens(from words: [String]) -> [Token] {
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)
        var result: [Token] = []
        var wordStart = 0
        for (wordIndex, word) in words.enumerated() {
            let wordLength = word.count
            let isLastWord = wordIndex == words.count - 1
            if !annotationFlags[wordIndex] {
                let wordPieces = pieces(of: word)
                for (pieceIndex, piece) in wordPieces.enumerated() {
                    let isLastPiece = pieceIndex == wordPieces.count - 1
                    // Finishing a word also consumes the space after it, so
                    // the highlight lands on the start of the next word.
                    let end = isLastPiece
                        ? wordStart + wordLength + (isLastWord ? 0 : 1)
                        : wordStart + piece.end
                    result.append(Token(
                        text: piece.text,
                        endOffset: end,
                        weight: isSingleCJKCharacter(piece.text) ? 1 : 2
                    ))
                }
            }
            wordStart += wordLength + 1
        }
        return result
    }

    private static func spokenTokens(from transcript: String) -> [String] {
        splitTextIntoWords(transcript).flatMap { word in pieces(of: word).map { $0.text } }
    }
}
