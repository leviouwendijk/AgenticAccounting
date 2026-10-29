import Accounting
import AccountingCompiler
import Agentic
import Macros
import Schema

public extension Accounting.Tools {
    @Tool("accounting_validate_entry_draft")
    struct ValidateEntryDraft: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let source: String
            public init(source: String) { self.source = source }
        }

        @JSONSchema
        public struct Issue: HashableResult {
            public let code: String
            public let message: String
            public let entryID: Int?

            public init(code: String, message: String, entryID: Int? = nil) {
                self.code = code
                self.message = message
                self.entryID = entryID
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let valid: Bool
            public let parsedEntryCount: Int
            public let issues: [Issue]

            public init(valid: Bool, parsedEntryCount: Int, issues: [Issue]) {
                self.valid = valid
                self.parsedEntryCount = parsedEntryCount
                self.issues = issues
            }
        }

        public enum Failure: Error {
            case sourceTooLarge
        }

        public static let purpose = """
        Validate proposed .ec entry blocks in memory, before a file mutation.
        Check lexer, parser, IDs against the current ledger, actual project
        references and debit/credit balancing. Never writes or reserves IDs.
        Baseline compilation/Workspace errors are surfaced as tool errors.
        A valid result is not a guarantee of tax or bookkeeping correctness.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func validateInput(_ input: Input) throws {
            guard input.source.utf8.count <= 262_144 else {
                throw Failure.sourceTooLarge
            }
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            try Self.validateInput(input)
            let workspace = try AccountingCompileAccess.authorize(
                context, toolName: Self.identifier.rawValue
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Validate proposed accounting entries without writing files",
                access: .init(
                    targets: ["config", "entries", "transactions", "config/settings.ec"],
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.scan, .read]
                ),
                sideEffects: []
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            try Self.validateInput(input)
            let workspace = try AccountingCompileAccess.authorize(
                context, toolName: Self.identifier.rawValue
            )
            if input.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .init(valid: false, parsedEntryCount: 0,
                             issues: [.init(code: "empty", message: "No entry blocks supplied")])
            }

            // First validate the actual project. Never treat a broken baseline as a
            // successful draft validation; access failures propagate unchanged.
            let compiled = try await EntryCompileDriver.compile(
                project: EntryCompilerProject(workspace: workspace),
                setting: CompileDriveSetting(loc_trace: false),
                verbose: false
            )
            let compiler = try EntryCompiler(workspace: workspace)
            let lexed = compiler.lexDetailed(input.source, flavor: .entries)
            let lexIssues: [Issue] = lexed.diagnostics
                .filter { $0.severity == .error }
                .map { .init(code: "lexing", message: $0.message) }
            if !lexIssues.isEmpty {
                return .init(valid: false, parsedEntryCount: 0, issues: lexIssues)
            }

            let entries: [Entry]
            do {
                entries = try compiler.parseEntries(tokens: lexed.tokens)
            } catch {
                return .init(valid: false, parsedEntryCount: 0,
                             issues: [.init(code: "parsing", message: String(describing: error))])
            }
            guard !entries.isEmpty else {
                return .init(valid: false, parsedEntryCount: 0,
                             issues: [.init(code: "empty", message: "No entry blocks parsed")])
            }

            var issues: [Issue] = []
            var seen: Set<Int> = []
            let occupied = Set(compiled.entries.compactMap(\.id))
            for entry in entries {
                guard let id = entry.id else {
                    issues.append(.init(code: "missing_id", message: "Draft entry has no ID"))
                    continue
                }
                if !seen.insert(id).inserted {
                    issues.append(.init(code: "duplicate_id", message: "Duplicate draft entry ID \(id)", entryID: id))
                }
                if occupied.contains(id) {
                    issues.append(.init(code: "occupied_id", message: "Entry ID \(id) already exists", entryID: id))
                }
            }
            if !issues.isEmpty {
                return .init(valid: false, parsedEntryCount: entries.count, issues: issues)
            }

            let resolved: [ResolvedEntry]
            do {
                resolved = try entries.resolved(
                    using: compiled.entities,
                    accounts: compiled.accounts,
                    transactions: compiled.transactions,
                    settings: compiler.settings
                )
            } catch {
                return .init(valid: false, parsedEntryCount: entries.count,
                             issues: [.init(code: "resolution", message: String(describing: error))])
            }
            for entry in resolved {
                do {
                    try entry.assertBalancing()
                } catch {
                    issues.append(.init(code: "unbalanced", message: String(describing: error),
                                        entryID: entry.id))
                }
            }
            return .init(valid: issues.isEmpty, parsedEntryCount: entries.count, issues: issues)
        }
    }
}
