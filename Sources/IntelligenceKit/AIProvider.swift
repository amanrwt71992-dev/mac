import Foundation
import CoreKit

// MARK: - AITask

/// The things the assistant can be asked to do.
///
/// A closed taxonomy rather than a free-form string, for three reasons:
/// capabilities can be checked before a provider is invoked, results can be
/// routed to the right mutation shape, and the eval suite can be organised
/// per task instead of per prompt.
public enum AITask: String, Hashable, Sendable, CaseIterable {

    /// Rewrite the selection in a different register.
    case changeTone
    /// Tighten the selection without losing meaning.
    case shorten
    /// Add detail, examples or explanation.
    case expand
    /// Spelling, grammar and punctuation.
    case proofread
    /// Produce a summary of the selection or the document.
    case summarise
    /// Translate, preserving formatting and structure.
    case translate
    /// Write new content from an instruction.
    case compose
    /// Answer a question using the document as context.
    case question
    /// Turn prose into a table.
    case tabulate
    /// Pull action items out of meeting notes.
    case extractActions
    /// Describe an image for accessibility.
    case describeImage
    /// Generate alt text for existing images that lack it.
    case altText

    /// Whether the result is a change to the document rather than an answer
    /// shown in a panel.
    public var mutatesDocument: Bool {
        switch self {
        case .question, .summarise, .extractActions, .describeImage:
            return false
        case .changeTone, .shorten, .expand, .proofread, .translate, .compose, .tabulate, .altText:
            return true
        }
    }

    /// Whether the task can be satisfied by a model with no document context.
    ///
    /// Matters for redaction: a task that does not need the document should not
    /// be sent one, so a third-party provider receives the minimum it requires.
    public var needsDocumentContext: Bool {
        switch self {
        case .question, .summarise, .extractActions, .translate, .proofread, .tabulate, .altText, .describeImage:
            return true
        case .changeTone, .shorten, .expand, .compose:
            // These operate on the selection itself, which is already the
            // minimum context. Whole-document context is opt-in per request.
            return false
        }
    }

    /// The Apple Writing Tools result options this task maps onto.
    ///
    /// Returning `nil` means "no Writing Tools equivalent", which is the signal
    /// to use our own assistant path instead. This mapping is what lets a single
    /// menu offer Writing Tools where Apple has a trained adapter and our
    /// provider where it does not, without the user choosing.
    ///
    /// The strings are Apple's own result-option names, not ours: they are what
    /// `NSWritingToolsCoordinator` hands back, so matching on them is the only
    /// way to line a Writing Tools result up with the task that requested it.
    public var writingToolsEquivalent: String? {
        switch self {
        case .changeTone:  return "rewrite"
        case .shorten:     return "concise"
        case .proofread:   return "proofread"
        case .summarise:   return "summarize"
        case .tabulate:    return "table"
        // No trained Apple adapter exists for these. Offering "rewrite" and
        // hoping would produce a plausible-looking wrong answer, which is worse
        // than routing the task to the configured provider.
        case .expand, .translate, .compose, .question, .extractActions, .describeImage, .altText:
            return nil
        }
    }
}

// MARK: - Request and response

public struct AIRequest: Hashable, Sendable {

    public var task: AITask
    /// The text to operate on, already redacted.
    public var input: String
    /// Instruction, for `.compose` and tone changes.
    public var instruction: String?
    /// Surrounding document context, if the task needs it and the user allowed it.
    public var context: String?
    public var language: String?
    public var maximumTokens: Int
    /// `nil` lets the provider choose. Set when reproducibility matters, e.g.
    /// running an eval.
    public var seed: UInt64?

    public init(
        task: AITask,
        input: String,
        instruction: String? = nil,
        context: String? = nil,
        language: String? = nil,
        maximumTokens: Int = 2048,
        seed: UInt64? = nil
    ) {
        self.task = task
        self.input = input
        self.instruction = instruction
        self.context = context
        self.language = language
        self.maximumTokens = maximumTokens
        self.seed = seed
    }
}

public struct AIResponse: Hashable, Sendable {

    public var text: String
    /// Per-change rationale, when the provider supplies one. Shown in the Review
    /// pane next to each tracked change.
    public var rationale: String?
    public var usage: TokenUsage?
    /// Which provider actually answered. Persisted with the revision author so
    /// the user can see, later, where a given sentence came from.
    public var providerID: String

    public init(text: String, rationale: String? = nil, usage: TokenUsage? = nil, providerID: String) {
        self.text = text
        self.rationale = rationale
        self.usage = usage
        self.providerID = providerID
    }
}

public struct TokenUsage: Hashable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

// MARK: - Provider

/// Where inference happens.
///
/// `runsOnDevice` is not a marketing flag; it drives the redaction policy and
/// the confirmation dialog. Text sent to a provider that does not run on device
/// leaves the Mac, and the user is told so before it happens — every time, not
/// once.
public protocol AIProvider: Sendable {

    /// Stable identifier, persisted in settings and in revision authors.
    var id: String { get }
    var displayName: String { get }

    /// Whether inference happens on this Mac. Apple Intelligence is `true`;
    /// every hosted API is `false`.
    var runsOnDevice: Bool { get }

    /// What this provider can actually do. A provider that cannot proofread is
    /// not offered for proofreading, rather than being offered and failing.
    var supportedTasks: Set<AITask> { get }

    /// Whether the provider is usable right now.
    func availability() -> AIProviderAvailability

    func complete(_ request: AIRequest) async throws -> AIResponse
}

public enum AIProviderAvailability: Hashable, Sendable {
    case available
    /// The on-device model is not present — Apple Silicon and a downloaded model
    /// are both required.
    case modelNotDownloaded
    /// Apple Intelligence is switched off in System Settings, or restricted by
    /// Screen Time or an MDM profile.
    case disabledBySystem
    /// No API key, or the key was rejected.
    case missingCredentials
    /// The network is unreachable.
    case offline
    /// Something else, with a message the UI can show verbatim.
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// A sentence suitable for showing in the provider picker.
    public var userMessage: String {
        switch self {
        case .available:
            return "Ready"
        case .modelNotDownloaded:
            return "The on-device model is not downloaded yet. Open System Settings → Apple Intelligence to download it."
        case .disabledBySystem:
            return "Apple Intelligence is turned off, or restricted by Screen Time or a device profile."
        case .missingCredentials:
            return "Add an API key in Settings → Assistant to use this provider."
        case .offline:
            return "No network connection."
        case .unavailable(let reason):
            return reason
        }
    }
}

public enum AIError: Error, Hashable, Sendable {
    case taskUnsupported(AITask, providerID: String)
    case providerUnavailable(AIProviderAvailability)
    /// The user declined to send text off-device.
    case consentDeclined
    /// The response could not be turned into document changes.
    case unparseableResponse
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
    /// The model itself reported a failure.
    case model(String)
}

// MARK: - Redaction

/// What may be sent to a provider that does not run on this Mac.
///
/// The default is strict: nothing that identifies a person or an organisation
/// leaves the machine unless the user has explicitly allowed it, per provider.
/// This exists because "configurable AI provider" is only a good idea if the
/// user controls what the provider sees.
public struct RedactionPolicy: Hashable, Sendable {

    public var removesPersonalNames: Bool
    public var removesEmailAddresses: Bool
    public var removesPhoneNumbers: Bool
    public var removesPostalAddresses: Bool
    public var removesOrganisationNames: Bool
    public var removesNumericValues: Bool
    public var removesDates: Bool

    /// Replace redacted spans with a placeholder rather than deleting them, so
    /// the model still sees the sentence shape.
    public var usesPlaceholders: Bool

    public init(
        removesPersonalNames: Bool = true,
        removesEmailAddresses: Bool = true,
        removesPhoneNumbers: Bool = true,
        removesPostalAddresses: Bool = true,
        removesOrganisationNames: Bool = false,
        removesNumericValues: Bool = false,
        removesDates: Bool = false,
        usesPlaceholders: Bool = true
    ) {
        self.removesPersonalNames = removesPersonalNames
        self.removesEmailAddresses = removesEmailAddresses
        self.removesPhoneNumbers = removesPhoneNumbers
        self.removesPostalAddresses = removesPostalAddresses
        self.removesOrganisationNames = removesOrganisationNames
        self.removesNumericValues = removesNumericValues
        self.removesDates = removesDates
        self.usesPlaceholders = usesPlaceholders
    }

    /// The policy applied to on-device providers: nothing is redacted, because
    /// nothing leaves the Mac.
    public static let none = RedactionPolicy(
        removesPersonalNames: false,
        removesEmailAddresses: false,
        removesPhoneNumbers: false,
        removesPostalAddresses: false,
        removesOrganisationNames: false,
        removesNumericValues: false,
        removesDates: false,
        usesPlaceholders: false
    )

    /// The policy applied to any hosted provider by default.
    public static let strict = RedactionPolicy()

    public var redactsAnything: Bool { self != .none }
}

// MARK: - Turning a response into document changes

/// Converts assistant output into a `DocumentMutation`.
///
/// The output is always tracked changes when the assistant made them, with the
/// provider named as the author. That is not a preference and not a default the
/// user can turn off: an edit the user cannot see before accepting it is an edit
/// the user cannot trust, and "the AI silently rewrote my document" is the
/// failure mode this whole design exists to prevent.
public enum AssistantMutationBuilder {

    /// Builds a replacement mutation for a range of text within one paragraph.
    ///
    /// Produces a deletion of the original and an insertion of the replacement,
    /// so the Review pane shows both and each can be accepted or rejected on its
    /// own. Replacing a paragraph wholesale would be one atomic change the user
    /// has to take or leave entirely.
    public static func replaceText(
        in paragraphID: NodeID,
        characterRange: Range<Int>,
        originalText: String,
        with replacement: String,
        author: MutationAuthor,
        revisionID: Int32,
        date: Date
    ) -> DocumentMutation {
        let deletion = RevisionMark(
            id: revisionID,
            author: author.revisionAuthor,
            date: date,
            kind: .deletion
        )
        let insertion = RevisionMark(
            id: revisionID + 1,
            author: author.revisionAuthor,
            date: date,
            kind: .insertion
        )

        // Insert first, then mark the original deleted. Deleting first would
        // shift the offsets the insertion depends on.
        //
        // `markTextDeleted`, not `deleteText`: the original text has to stay in
        // the document so the user can reject the change and get it back. A
        // proposal that removes the text it is proposing to replace is not a
        // proposal, it is an edit with extra steps.
        var operations: [MutationOp] = [
            .insertText(
                paragraph: paragraphID,
                characterOffset: characterRange.lowerBound,
                text: replacement,
                properties: .empty,
                revision: insertion
            ),
            .markTextDeleted(
                paragraph: paragraphID,
                characterOffset: characterRange.lowerBound + replacement.count,
                length: originalText.count,
                revision: deletion
            ),
        ]
        // `revisionAuthor` already reads "Assistant (provider)"; prefixing it
        // again would show the user "Assistant (Assistant (provider))".
        operations.append(.annotate(rationale: author.revisionAuthor))

        return DocumentMutation(operations: operations, author: author)
    }

    /// Builds a mutation that inserts new paragraphs after an anchor block.
    public static func insertParagraphs(
        after blockID: NodeID,
        sectionIndex: Int,
        blockIndex: Int,
        paragraphs: [Paragraph],
        author: MutationAuthor,
        rationale: String?
    ) -> DocumentMutation {
        var operations: [MutationOp] = [
            .insertBlocks(sectionIndex: sectionIndex, blockIndex: blockIndex + 1, blocks: paragraphs.map { .paragraph($0) })
        ]
        if let rationale {
            operations.append(.annotate(rationale: rationale))
        }
        return DocumentMutation(operations: operations, author: author)
    }
}
