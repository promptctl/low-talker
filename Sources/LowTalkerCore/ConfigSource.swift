import Foundation

/// Where the config the app runs on is read from: once at launch, then at every save.
///
/// [LAW:effects-at-boundaries] A reading is a file read, so the app is handed one of these rather
/// than reaching for the file, and a test hands it a file it saves itself.
public protocol ConfigSource: Sendable {
    /// The config as it stands now, every mode's vocabulary checked through `prompting`.
    func read(prompting: PromptEncoder) -> Result<Config, ConfigError>
    /// Every change to what the app runs on, from `running` on, as the config is saved, until the
    /// consuming task stops. A save that reads back as the last one did says nothing.
    func reloads(after running: RunningConfig, prompting: PromptEncoder) -> AsyncStream<RunningConfig>
}

/// The config file at `url`, the app's own unless a test says otherwise.
public struct ConfigFileSource: ConfigSource {
    public let url: URL

    public init(url: URL = Config.fileURL) {
        self.url = url
    }

    public func read(prompting: PromptEncoder) -> Result<Config, ConfigError> {
        Result { () throws(ConfigError) in try Config.load(url, prompting: prompting) }
    }

    public func reloads(after running: RunningConfig, prompting: PromptEncoder) -> AsyncStream<RunningConfig> {
        RunningConfig.reloads(of: url, after: running, prompting: prompting)
    }
}
