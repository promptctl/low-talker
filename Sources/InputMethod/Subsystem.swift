import Foundation

/// The subsystem this process logs under: its own bundle's, so `log show` finds every line the
/// input method writes under one name.
nonisolated let subsystem = Bundle.main.bundleIdentifier ?? "lowtalker-inputmethod"
