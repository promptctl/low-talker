import LowTalkerCore

/// What a cancelled press's inserts put before the caret, and what taking its own words back
/// leaves there, fed each insert that landed in the order the field holds them: the text as it
/// landed, then the held runs it carried and the press's new words.
///
/// [LAW:one-source-of-truth] `replacing` is the field's own text, as the input method answered it
/// landed, from the first insert holding the press's own words to the caret. An insert is taken
/// back whole: the input method fitted it to the field, so where one run ends inside it is not
/// known here. The earlier dictation those inserts carried is `leaving`, as it was sent, and the
/// input method fits it again to the text around the words it replaces. An insert ahead of the
/// press's first word holds nothing to take back, so it stays where it was delivered.
struct TakeBack: Sendable, Equatable {
    /// The text immediately before the caret that the take-back replaces.
    private(set) var replacing = ""
    /// The earlier dictation inside `replacing`, which the take-back puts back in its place.
    private(set) var leaving = ""
    /// The press's own words that landed.
    private(set) var words = 0
    /// Earlier dictation its inserts carried into the field: delivered, not the press's, so it stays.
    private(set) var earlierWords = 0

    /// An insert of `press`'s that landed as `landed`: `carried`, the hold's runs and who said
    /// each, then `words`, the press's new ones.
    mutating func landed(_ landed: String, carrying carried: Held.Part?, then words: Transcript, of press: any Held.Owner) {
        let runs = carried?.runs ?? []
        let own = runs.filter { $0.said(by: press) }.map { Transcript(words: $0.words) } + [words]
        let earlier = runs.filter { !$0.said(by: press) }.map { Transcript(words: $0.words) }
        self.words += own.map(\.words.count).reduce(0, +)
        earlierWords += earlier.map(\.words.count).reduce(0, +)
        // Until the press's own text is in the field, nothing it carried sits between its words.
        guard !replacing.isEmpty || own.contains(where: { !$0.text.isEmpty }) else { return }
        replacing += landed
        leaving += earlier.map(\.text).joined()
    }
}
