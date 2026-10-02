import Foundation
import CoreKit

// MARK: - ProviderCatalogue

/// The providers compiled into this build.
///
/// Compiled in, not downloaded: there is no first-party server, no account and
/// no catalogue service, so the list of providers is a property of the binary.
/// That is a deliberate consequence of the "your Mac, your keys" position — a
/// provider list fetched from us would be a list we could change without the
/// user noticing.
public enum ProviderCatalogue {

    /// Apple Intelligence, plus any provider the user has configured.
    ///
    /// Unconfigured third-party providers are still listed, reporting
    /// `.missingCredentials`, so the settings UI can show what is available
    /// rather than what happens to be set up.
    public static let builtIn: [any AIProvider] = [
        AppleIntelligenceProvider(),
        OpenAICompatibleProvider(
            id: "openai",
            displayName: "OpenAI-compatible endpoint",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model: "gpt-4o"
        ),
        OpenAICompatibleProvider(
            id: "anthropic",
            displayName: "Anthropic",
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            model: "claude-sonnet-4-5"
        ),
        OpenAICompatibleProvider(
            id: "ollama",
            displayName: "Ollama (local)",
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "llama3.1",
            runsOnDevice: true
        ),
    ]

    public static func provider(id: String) -> (any AIProvider)? {
        builtIn.first { $0.id == id }
    }

    /// Every provider that runs on this Mac.
    public static var onDevice: [any AIProvider] {
        builtIn.filter { $0.runsOnDevice }
    }
}

// MARK: - AppleIntelligenceProvider

/// Apple Intelligence, via the Foundation Models framework.
///
/// On macOS 27 the framework exposes a `LanguageModel` protocol, so Apple's
/// on-device model and a third-party model can back the same session type. This
/// provider uses the on-device one; `runsOnDevice` is `true`, which is what
/// switches the redaction policy off — nothing leaves the Mac, so there is
/// nothing to redact.
public struct AppleIntelligenceProvider: AIProvider {

    public var id: String { "apple-intelligence" }
    public var displayName: String { "Apple Intelligence" }
    public var runsOnDevice: Bool { true }

    public var supportedTasks: Set<AITask> {
        // Everything except the tasks that need a model we do not have locally.
        // Image description is included: on macOS 27 Vision's OCR and image
        // understanding are callable by the on-device model as tools.
        Set(AITask.allCases)
    }

    public init() {}

    public func availability() -> AIProviderAvailability {
        #if canImport(FoundationModels)
        // The real check is `SystemLanguageModel.default.availability`, which
        // reports whether the adapter is downloaded, whether Apple Intelligence
        // is enabled, and whether a device profile restricts it. Wiring that up
        // is M3; until then this provider reports honestly that it is not
        // connected rather than pretending to work.
        return .unavailable(reason: "Apple Intelligence support is not wired up yet (planned for M3).")
        #else
        return .unavailable(reason: "Foundation Models is only available on Apple platforms.")
        #endif
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        throw AIError.providerUnavailable(availability())
    }
}

// MARK: - OpenAICompatibleProvider

/// Any provider speaking the OpenAI chat-completions wire format.
///
/// One implementation covering OpenAI, Anthropic's compatibility endpoint,
/// Groq, Together, OpenRouter and a local Ollama, because they all speak the
/// same shape and the differences are the base URL, the model name and the
/// header the key goes in. Writing five near-identical providers would be five
/// places to get TLS or key handling wrong.
///
/// **Keys live in the Keychain**, never in a preferences file and never in the
/// document. `apiKey` is injected at construction by whoever owns the Keychain
/// item; the provider itself has no idea where it came from and cannot write it
/// back.
public struct OpenAICompatibleProvider: AIProvider {

    public var id: String
    public var displayName: String
    public var baseURL: URL
    public var model: String

    /// Ollama and anything else bound to loopback counts as on-device: the text
    /// does not leave the Mac even though it does leave the process.
    public var runsOnDevice: Bool

    /// The API key, injected from the Keychain. `nil` means "not configured".
    public var apiKey: String?

    /// Which header carries the key. Anthropic uses `x-api-key` plus a version
    /// header; most others use `Authorization: Bearer`.
    public var authenticationScheme: AuthenticationScheme

    public enum AuthenticationScheme: Hashable, Sendable {
        case bearer
        case anthropic(version: String)
        case custom(header: String, prefix: String)
    }

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        model: String,
        runsOnDevice: Bool = false,
        apiKey: String? = nil,
        authenticationScheme: AuthenticationScheme? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.runsOnDevice = runsOnDevice
        self.apiKey = apiKey
        self.authenticationScheme = authenticationScheme ?? (id == "anthropic"
            ? .anthropic(version: "2023-06-01")
            : .bearer)
    }

    public var supportedTasks: Set<AITask> {
        // A general-purpose chat model can attempt anything. Capability
        // *quality* is a separate question, answered by the eval suite rather
        // than by this set.
        Set(AITask.allCases)
    }

    public func availability() -> AIProviderAvailability {
        guard apiKey?.isEmpty == false else { return .missingCredentials }
        return .available
    }

    /// The endpoint a request would be sent to.
    ///
    /// Exposed so the settings UI can show the user exactly where their text
    /// would go — a full URL, not a provider name. "OpenAI" is a company;
    /// `https://api.openai.com/v1/chat/completions` is a destination.
    public var completionEndpoint: URL {
        baseURL.appendingPathComponent("chat/completions")
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        guard availability().isAvailable else {
            throw AIError.providerUnavailable(availability())
        }
        // The transport is M3 work. It has to be written carefully — TLS
        // pinning policy, no key in logs, no key in crash reports, a timeout,
        // and a cancellation path that actually cancels — and doing that badly
        // is worse than not doing it yet.
        throw AIError.transport("HTTP transport is not implemented yet (planned for M3).")
    }
}

// MARK: - UnavailableProvider

/// A provider that exists in configuration but cannot run.
///
/// Used when a user's saved configuration names something this build does not
/// know, so that the setting survives an upgrade instead of being silently
/// discarded — losing a user's configuration is worse than showing an error.
public struct UnavailableProvider: AIProvider {

    public var id: String
    public var displayName: String
    public var reason: String

    public init(id: String, displayName: String, reason: String) {
        self.id = id
        self.displayName = displayName
        self.reason = reason
    }

    public var runsOnDevice: Bool { false }
    public var supportedTasks: Set<AITask> { [] }

    public func availability() -> AIProviderAvailability { .unavailable(reason: reason) }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        throw AIError.providerUnavailable(availability())
    }
}
