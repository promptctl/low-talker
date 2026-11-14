/// How a request for one step's grant ended, which says where the person is left.
///
/// [LAW:types-are-the-program] Only a dialog answered before the request returned took the
/// front away, so only `answered` takes it back; the arm that sends the person to System
/// Settings cannot also pull the setup window over it.
public enum SetUpRequest: Equatable, Sendable {
    /// macOS showed its dialog and it was answered. Answering hands the front to the app
    /// that had it before this one, so the setup window takes it back, unless the person closed
    /// it meanwhile.
    case answered
    /// The request went through and took nothing from the front: macOS had nothing left
    /// to ask, or its dialog may still be up when the request returns, as the input
    /// method's may (`InstalledInputMethod.switchOn`).
    case made
    /// Nothing was asked, for the reason shown on the step.
    case failed(String)
    /// macOS will not ask again, and the switch is in System Settings, which opens with
    /// the reason shown on the step behind it.
    case sentToSystemSettings(String)
}
