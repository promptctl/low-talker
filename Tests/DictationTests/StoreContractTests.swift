import Dictation
import DictationFakes
import Foundation
import Testing

/// Each store's contract, against its fake and against the file the app keeps it in, over a
/// directory of the test's own. [LAW:one-source-of-truth] The fakes every loop test stands on
/// keep what the files keep.
@MainActor
final class StoreContractTests {
    /// Each test's own, removed when it ends.
    let directory = FileManager.default.temporaryDirectory.appending(path: "store-contract-\(UUID())")

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    static let fakeHeld = HeldStoreContract {
        let store = FakeHeldStore()
        return HeldStoreContract.Subject(
            store: store,
            spoil: { store.spoil(HeldUnreadable(why: "torn", kept: .movedTo("aside"))) },
            obstruct: { store.failing = .lost(why: "in the way") }
        )
    }

    /// `HeldFile` in the test's directory.
    var heldFile: HeldStoreContract {
        HeldStoreContract { [directory] in
            let file = HeldFile(url: directory.appending(path: "held.json"))
            return HeldStoreContract.Subject(
                store: file,
                spoil: { try Data("not json".utf8).write(to: file.url) },
                // A directory where the file goes: the atomic rename cannot replace it, and removal can.
                obstruct: {
                    try FileManager.default.removeItem(at: file.url)
                    try FileManager.default.createDirectory(at: file.url.appending(path: "in-the-way"), withIntermediateDirectories: true)
                }
            )
        }
    }

    static let fakeUnheard = UnheardStoreContract {
        let store = FakeUnheardStore()
        return UnheardStoreContract.Subject(store: store, damage: { store.damage($0.id) })
    }

    /// `UnheardFiles` in the test's directory.
    var unheardFiles: UnheardStoreContract {
        UnheardStoreContract { [directory] in
            UnheardStoreContract.Subject(store: UnheardFiles(directory: directory), damage: { entry in
                try Data([1, 2, 3]).write(to: directory.appending(path: entry.id))
            })
        }
    }

    @Test(arguments: HeldStoreContract.Statement.allCases)
    func theFakeHeldStoreKeepsTheStatement(_ statement: HeldStoreContract.Statement) throws {
        #expect(try Self.fakeHeld.disagreements(with: statement) == [])
    }

    @Test(arguments: HeldStoreContract.Statement.allCases)
    func theHeldFileKeepsTheStatement(_ statement: HeldStoreContract.Statement) throws {
        #expect(try heldFile.disagreements(with: statement) == [])
    }

    @Test(arguments: UnheardStoreContract.Statement.allCases)
    func theFakeUnheardStoreKeepsTheStatement(_ statement: UnheardStoreContract.Statement) throws {
        #expect(try Self.fakeUnheard.disagreements(with: statement) == [])
    }

    @Test(arguments: UnheardStoreContract.Statement.allCases)
    func theUnheardFilesKeepTheStatement(_ statement: UnheardStoreContract.Statement) throws {
        #expect(try unheardFiles.disagreements(with: statement) == [])
    }
}
