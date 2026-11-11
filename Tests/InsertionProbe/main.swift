import Insertion
import Foundation

/// Sends one insert from a process that is not the suite, and prints what came of it.
///
///     insertion-probe <port name> <answerer, as PeerIdentity JSON> <text>
///
/// The port is one the suite hosts, and the answerer is the one it plays.
///
/// The answer goes to standard output as the words the app would log - the inserted count,
/// or the error's own description - so what is asserted is what a person would read.
/// [LAW:behavior-not-structure]
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let answerer = try? JSONDecoder().decode(PeerIdentity.self, from: Data(arguments[1].utf8)) else {
    FileHandle.standardError.write(Data("""
        usage: insertion-probe <port name> <answerer, as PeerIdentity JSON> <text>

        """.utf8))
    exit(2)
}
let inserter = InputMethodInserter(portName: arguments[0], timeout: .seconds(20), answerer: .success(answerer))
do {
    let inserted = try inserter.insert(arguments[2], into: .cursorInFront)
    print("inserted \(inserted.characters) into \(inserted.into)")
} catch {
    print("\(error)")
}
