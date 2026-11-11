import Insertion
import Foundation

/// Sends one insert from a process that is not the suite, and prints what came of it.
///
///     insertion-probe <port name> <answerer, as PeerIdentity JSON> <text>
///     insertion-probe <text>
///
/// The first is the suite's: a port it hosts, and the answerer it plays. The second builds
/// the inserter exactly as the app does, for a probe signed as the app to send to the real
/// input method - which is how the app's own half is checked on a Mac without speaking.
///
/// The answer goes to standard output as the words the app would log - the inserted count,
/// or the error's own description - so what is asserted is what a person would read.
/// [LAW:behavior-not-structure]
let arguments = Array(CommandLine.arguments.dropFirst())
let inserter: InputMethodInserter
let text: String
if arguments.count == 1 {
    inserter = await InputMethodInserter()
    text = arguments[0]
} else if arguments.count == 3, let answerer = try? JSONDecoder().decode(PeerIdentity.self, from: Data(arguments[1].utf8)) {
    inserter = InputMethodInserter(portName: arguments[0], timeout: .seconds(20), answerer: .success(answerer))
    text = arguments[2]
} else {
    FileHandle.standardError.write(Data("""
        usage: insertion-probe <port name> <answerer, as PeerIdentity JSON> <text>
               insertion-probe <text>

        """.utf8))
    exit(2)
}
do {
    let inserted = try inserter.insert(text, into: .cursorInFront)
    print("inserted \(inserted.characters) into \(inserted.into)")
} catch {
    print("\(error)")
}
