import Insertion
import Foundation

/// Sends one insert from a process that is not the suite, and prints what came of it.
///
///     insertion-probe <port name> <answerer, as PeerIdentity JSON> <build, as Build JSON> <text>
///     insertion-probe <build, as Build JSON> <text>
///
/// The first is the suite's: a port it hosts, and the answerer it plays. The second builds
/// the inserter exactly as the app does, for a probe signed as the app to send to the real
/// input method - which is how the app's own half is checked on a Mac without speaking.
/// The probe has no bundle to read a build off, so it is told the build it plays: the app's,
/// `{"number":"<CFBundleVersion>","revision":"<LTSourceRevision>"}` off its Info.plist.
///
/// The answer goes to standard output as the words the app would log - the inserted count,
/// or the error's own description - so what is asserted is what a person would read.
/// [LAW:behavior-not-structure]
let arguments = Array(CommandLine.arguments.dropFirst())
func build(_ json: String) -> Build? { try? JSONDecoder().decode(Build.self, from: Data(json.utf8)) }
let inserter: InputMethodInserter
let text: String
if arguments.count == 2, let build = build(arguments[0]) {
    inserter = InputMethodInserter(build: build)
    text = arguments[1]
} else if arguments.count == 4, let answerer = try? JSONDecoder().decode(PeerIdentity.self, from: Data(arguments[1].utf8)), let build = build(arguments[2]) {
    inserter = InputMethodInserter(portName: arguments[0], timeout: .seconds(20), answerer: .success(answerer), build: build)
    text = arguments[3]
} else {
    FileHandle.standardError.write(Data("""
        usage: insertion-probe <port name> <answerer, as PeerIdentity JSON> <build, as Build JSON> <text>
               insertion-probe <build, as Build JSON> <text>

        """.utf8))
    exit(2)
}
do {
    let inserted = try inserter.insert(text, into: .cursorInFront)
    print("inserted \(inserted.characters) into \(inserted.into)")
} catch {
    print("\(error)")
}
