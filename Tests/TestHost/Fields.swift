import AppKit
import WebKit

/// A field on the host's window, whatever draws it: it acts on a command and says what it holds
/// once the command has taken effect, and pushes a reading on every change, whatever made it.
protocol HostedField: AnyObject {
    var view: NSView { get }
    /// Ready once its page has loaded; at once for a field AppKit draws.
    func load() async
    func perform(_ act: Command.Act) async -> Reading
}

/// An NSTextView: the field TextEdit and Notes show.
final class TextViewField: HostedField {
    private let textView = NSTextView(frame: .zero)
    private let field: Field
    var view: NSView { textView }

    init(_ field: Field) {
        self.field = field
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            NotificationCenter.default.addObserver(forName: name, object: textView, queue: .main) { [unowned self] _ in
                MainActor.assumeIsolated { Events.field(reading(), answering: nil) }
            }
        }
    }

    func load() async {}

    func perform(_ act: Command.Act) async -> Reading {
        switch act {
        // `Command.parse` gives a text view no maxLength.
        case let .hold(text, selection, _):
            textView.window?.makeFirstResponder(textView)
            textView.string = text
            textView.setSelectedRange(selection)
        case .read: break
        }
        return reading()
    }

    private func reading() -> Reading {
        Reading(field: field, text: textView.string, selection: textView.selectedRange(), maxLength: nil,
                focused: textView.window?.firstResponder === textView)
    }
}

/// A page holding one element, `<textarea>` or `<input>`, which fills it: the fields Safari
/// shows. Each has a web view of its own, so focusing one never moves another.
final class WebField: NSObject, HostedField, WKNavigationDelegate, WKScriptMessageHandler {
    private let field: Field
    private let element: String
    private let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?
    var view: NSView { webView }

    /// The page's own account of its element, which every reading is built from: the text, the
    /// selection as `selectionStart` and `selectionEnd` count it, in UTF-16 units as NSRange does,
    /// and the element's `maxLength`, which is -1 when it has none.
    private static let script = """
        const f = document.getElementById('f');
        function state() {
            return {text: f.value, start: f.selectionStart, end: f.selectionEnd, maxLength: f.maxLength < 0 ? null : f.maxLength,
                    focused: document.activeElement === f};
        }
        f.addEventListener('input', () => webkit.messageHandlers.host.postMessage(state()));
        document.addEventListener('selectionchange', () => webkit.messageHandlers.host.postMessage(state()), true);
        """

    init(_ field: Field, element: String) {
        self.field = field
        self.element = element
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "host")
        webView.navigationDelegate = self
    }

    func load() async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            let style = "html,body{margin:0;height:100%}#f{box-sizing:border-box;width:100%;height:100%;font:14px -apple-system}"
            webView.loadHTMLString("<!doctype html><style>\(style)</style>\(element)<script>\(Self.script)</script>", baseURL: nil)
        }
    }

    nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    // A page fails before it commits, after, or with the process that draws it: each leaves the
    // field gone, and the host says so rather than wait on it. [LAW:no-silent-failure]
    nonisolated func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { Events.fail("the page of \(field.rawValue) did not load: \(error)") }
    }

    nonisolated func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { Events.fail("the page of \(field.rawValue) did not load: \(error)") }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_: WKWebView) {
        MainActor.assumeIsolated { Events.fail("the web content process of \(field.rawValue) ended") }
    }

    nonisolated func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { Events.field(reading(message.body), answering: nil) }
    }

    func perform(_ act: Command.Act) async -> Reading {
        switch act {
        case let .hold(text, selection, maxLength):
            webView.window?.makeFirstResponder(webView)
            return await run("""
                f.focus();
                if (maxLength === null) { f.removeAttribute('maxlength'); } else { f.maxLength = maxLength; }
                f.value = text;
                f.setSelectionRange(start, start + length);
                return state();
                """, ["text": text, "start": selection.location, "length": selection.length, "maxLength": maxLength ?? NSNull()])
        case .read:
            return await run("return state();", [:])
        }
    }

    /// Runs `body` in the page, where `state` is defined, and reads the state it returns.
    private func run(_ body: String, _ arguments: [String: Any]) async -> Reading {
        do {
            return reading(try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page))
        } catch {
            Events.fail("a command on \(field.rawValue) failed in its page: \(error)")
        }
    }

    /// A reading out of the page's `state`, focused only while the page's element has focus and
    /// the web view is the window's first responder, or holds it inside.
    private func reading(_ state: Any?) -> Reading {
        guard let state = state as? [String: Any], let text = state["text"] as? String,
              let start = state["start"] as? Int, let end = state["end"] as? Int, let focused = state["focused"] as? Bool,
              let maxLength = state["maxLength"], maxLength is NSNull || maxLength is Int
        else { Events.fail("the page of \(field.rawValue) answered \(String(describing: state)), which is no state") }
        let responder = webView.window?.firstResponder as? NSView
        return Reading(field: field, text: text, selection: NSRange(location: start, length: end - start), maxLength: maxLength as? Int,
                       focused: focused && responder?.isDescendant(of: webView) == true)
    }
}
