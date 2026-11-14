import Foundation
import LowTalkerCore

/// One cell of the bench table: its column's name and its value as printed.
public struct BenchCell: Hashable, Sendable {
    public let name: String
    public let value: String
}

/// One row of the bench table, a model, fixture, delivery and serving: every number to three
/// places, every duration in seconds. The same row is a line on stdout, a row in the window
/// and an event in the log. [LAW:one-source-of-truth]
public struct BenchRow: Hashable, Sendable {
    public let cells: [BenchCell]
    /// The fixture, delivery and serving, what the engine heard on the last hold and the word
    /// error rate it scored: where a rate gets explained. Fixture speech, never anything a
    /// person dictated.
    public let narration: String

    public init(model: Model, load: Duration, result: LatencyReport.FixtureResult) {
        let wer = result.wordErrorRate
        cells = [
            ("model", model.description),
            ("fixture", result.name),
            // Still spelled `delivery`, the name every recorded run was taken under, so a
            // reading stays comparable to the ones before it.
            ("delivery", result.arrival.rawValue),
            ("serving", result.serving.rawValue),
            ("audio_s", fixed(result.audio, places: 3)),
            ("load_s", load.seconds),
            ("first_s", result.first.keyUpToTranscript.seconds),
            ("median_s", result.medianKeyUpToTranscript.seconds),
            ("partial_s", result.medianHoldToFirstText.seconds),
            ("wer", fixed(wer.rate, places: 3)),
            ("substituted", String(wer.substitutions)),
            ("dropped", String(wer.deletions)),
            ("added", String(wer.insertions)),
            ("reference_words", String(wer.referenceCount)),
            ("served_cancelled", String(result.served.cancelled)),
            ("served_deferred", String(result.served.deferred)),
            ("served_changed", String(result.served.changed)),
        ].map(BenchCell.init)
        narration = "\(result.name) \(result.arrival.rawValue) \(result.serving.rawValue): heard \"\(result.transcript.text)\", \(wer)"
    }

    /// The row as a line of the tab-separated table.
    public var line: String { cells.map(\.value).joined(separator: "\t") }

    /// The table's header, which is the first row's names, so a column cannot be titled one
    /// thing and filled with another. [LAW:one-source-of-truth]
    public var header: String { cells.map(\.name).joined(separator: "\t") }

    /// The row as one log event's fields, `name=value` apart by spaces.
    public var fields: String { cells.map { "\($0.name)=\($0.value)" }.joined(separator: " ") }

    /// Rows as the tab-separated table stdout prints: the header, then a line each.
    public static func table(_ rows: [BenchRow]) -> String {
        ((rows.first.map { [$0.header] } ?? []) + rows.map(\.line)).joined(separator: "\n")
    }
}

/// [LAW:one-source-of-truth] Every number the bench writes comes through here, pinned to a
/// locale no machine setting can change, so tables diff across machines.
public func fixed(_ value: Double, places: Int) -> String {
    value.formatted(.number.precision(.fractionLength(places)).locale(Locale(identifier: "en_US_POSIX")))
}

extension Duration {
    /// Seconds to the millisecond, the resolution a latency table needs.
    public var seconds: String {
        fixed(Double(components.seconds) + Double(components.attoseconds) / 1e18, places: 3)
    }
}
