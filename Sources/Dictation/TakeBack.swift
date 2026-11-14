import LowTalkerCore

/// What a cancelled press's inserts put before the caret, and what taking its own words back
/// leaves there, fed each insert that landed in the order the field holds its words: the held
/// runs it carried, then the press's new words.
///
/// [LAW:one-source-of-truth] `replacing` is the field's own text from the press's first word to the
/// caret, earlier dictation an insert carried between its words included, so the one request the
/// input method proves against the field is what the field holds, not a join of the press's words
/// alone. Earlier dictation ahead of its first word is not between anything taken back, so it
/// stays out of `replacing` and is left where it was delivered.
struct TakeBack: Sendable, Equatable {
    /// The text immediately before the caret that the take-back replaces.
    private(set) var replacing = ""
    /// The earlier dictation inside `replacing`, which the take-back puts back in its place.
    private(set) var leaving = ""
    /// The press's own words that landed.
    private(set) var words = 0
    /// Earlier dictation its inserts carried into the field: delivered, not the press's, so it stays.
    private(set) var earlierWords = 0

    /// An insert of `press`'s landed `carried` at the cursor, the hold's runs and who said each,
    /// then `words`, the press's new ones.
    mutating func landed(carrying carried: Held.Part?, then words: Transcript, of press: any Held.Owner) {
        for run in carried?.runs ?? [] { landed(Transcript(words: run.words), own: run.said(by: press)) }
        landed(words, own: true)
    }

    private mutating func landed(_ text: Transcript, own: Bool) {
        if own { words += text.words.count } else { earlierWords += text.words.count }
        // Until the press's own text is in the field, nothing it carried sits between its words.
        guard own || !replacing.isEmpty else { return }
        replacing += text.text
        if !own { leaving += text.text }
    }
}
