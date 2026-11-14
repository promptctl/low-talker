@testable import model_tool
import LowTalkerCore
import ModelInstall
import Testing

@Suite struct SourceOptionsTests {
    /// One flag names every kind of source, so the text alone decides: models at commits are
    /// revisions on the hub, and a directory whose name looks like a host, or like a bare
    /// revision, is still a directory.
    @Test(arguments: [
        ("https://github.com/o/r/releases/download/models-1/", "published"),
        ("http://127.0.0.1:8000", "published"),
        ("/tmp/store", "store"),
        ("relative/store", "store"),
        ("huggingface.co", "store"),
        ("base.en@\(String(repeating: "a", count: 40))-\(String(repeating: "b", count: 40))", "huggingFace"),
        ("base.en@\(String(repeating: "a", count: 40))-\(String(repeating: "b", count: 40))+parakeet-tdt-0.6b-v3@\(String(repeating: "c", count: 40))", "huggingFace"),
        ("\(String(repeating: "a", count: 40))-\(String(repeating: "b", count: 40))", "store"),
        (String(repeating: "a", count: 40), "store"),
    ])
    func fromNamesTheKindOfSourceByItsText(argument: String, kind: String) {
        let parsed: String? = switch ModelSource(argument: argument) {
        case .published: "published"
        case .store: "store"
        case .huggingFace(_?): "huggingFace"
        case .huggingFace(nil), nil: nil
        }
        #expect(parsed == kind)
    }
}
