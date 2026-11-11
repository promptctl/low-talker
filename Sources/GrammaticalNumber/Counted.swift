/// A count told with what it counts in the number the count takes: `counted(1, "word", "words")`
/// is "1 word", and 0 or 2 are "0 words" and "2 words". `one` and `many` may run on past the noun,
/// so a verb agrees with the count as well: `counted(n, "word is held", "words are held")`.
///
/// [LAW:one-type-per-behavior] Every count a person reads, in a warning or in the log, is told
/// through this, so none reads "1 words".
public func counted(_ count: Int, _ one: String, _ many: String) -> String {
    "\(count) \(count == 1 ? one : many)"
}
