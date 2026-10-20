// Apple's built-in sound classifier (SoundAnalysis version1) over each wav named, for fetch-data:
// a header row `file\tstart\t<every label it knows>`, then one row per 1 s window at 0.5 s hop
// with each label's confidence in the header's order. What counts as a sneeze or a voice is
// fetch-data's to decide. A wav that yields no window stops the run, since its absence would
// read as "no sneeze".
import CoreMedia
import Foundation
import SoundAnalysis

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("sound-classes: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let labels = try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications

final class Rows: NSObject, SNResultsObserving {
    let file: String
    var lines: [String] = []
    init(_ file: String) { self.file = file }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        let r = result as! SNClassificationResult
        let scores = labels.map { String(format: "%.3f", r.classification(forIdentifier: $0)!.confidence) }
        lines.append(([file, String(format: "%.2f", r.timeRange.start.seconds)] + scores).joined(separator: "\t"))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) { fail("\(file): \(error)") }
}

print((["file", "start"] + labels).joined(separator: "\t"))
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
    request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
    request.overlapFactor = 0.5
    let rows = Rows(url.lastPathComponent)
    let analyzer = try SNAudioFileAnalyzer(url: url)
    try analyzer.add(request, withObserver: rows)
    analyzer.analyze()
    if rows.lines.isEmpty { fail("\(path) gave no window") }
    print(rows.lines.joined(separator: "\n"))
}
