import Accounting
import AccountingCompiler
import Agentic
import AgenticIO
import Macros
import Schema
import Workspace

public extension Accounting.Tools {
    @Tool("accounting_inspect_placeholders")
    struct InspectPlaceholders: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let maximumFindings: Int
            public init(maximumFindings: Int = 100) {
                self.maximumFindings = maximumFindings
            }
        }

        @JSONSchema
        public struct Finding: HashableResult {
            public let entryID: Int?
            public let entryIndex: Int
            public let lineIndex: Int
            public let entityAlias: String
            public let kind: String?
            public let detection: String
            public let location: String?
            public let entryLocation: String?

            public init(entryID: Int?, entryIndex: Int, lineIndex: Int,
                        entityAlias: String, kind: String?, detection: String,
                        location: String?, entryLocation: String?) {
                self.entryID = entryID
                self.entryIndex = entryIndex
                self.lineIndex = lineIndex
                self.entityAlias = entityAlias
                self.kind = kind
                self.detection = detection
                self.location = location
                self.entryLocation = entryLocation
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let entryCount: Int
            public let affectedEntryCount: Int
            public let totalOccurrences: Int
            public let findings: [Finding]
            public let truncated: Bool

            public init(entryCount: Int, affectedEntryCount: Int,
                        totalOccurrences: Int, findings: [Finding], truncated: Bool) {
                self.entryCount = entryCount
                self.affectedEntryCount = affectedEntryCount
                self.totalOccurrences = totalOccurrences
                self.findings = findings
                self.truncated = truncated
            }
        }

        public enum Failure: Error {
            case workspaceRequired
            case invalidLimit
        }

        public static let purpose = """
        Inspect placeholder entity references in the active accounting project's
        parsed entries, without compiling or resolving the ledger. Read-only.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func authorize(_ input: Input, in context: ToolContext) throws {
            guard (1...500).contains(input.maximumFindings) else { throw Failure.invalidLimit }
            guard let workspace = context.workspace else { throw Failure.workspaceRequired }
            _ = try FileToolAccess.authorize(
                workspace: workspace,
                rootID: workspace.rootIdentifier,
                path: "entries", capability: .scan,
                toolName: Self.identifier.rawValue, type: .directory
            )
            _ = try FileToolAccess.authorize(
                workspace: workspace,
                rootID: workspace.rootIdentifier,
                path: "config/settings.ec", capability: .read,
                toolName: Self.identifier.rawValue, type: .file
            )
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            try Self.authorize(input, in: context)
            guard let workspace = context.workspace else { throw Failure.workspaceRequired }
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Inspect accounting entry placeholders without compilation",
                access: .init(
                    targets: ["entries", "config/settings.ec"],
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.scan, .read]
                ),
                sideEffects: []
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            try Self.authorize(input, in: context)
            guard let workspace = context.workspace else { throw Failure.workspaceRequired }
            let project = EntryCompilerProject(workspace: workspace)
            let settings = try EntryCompilerSettingsLoader.load(from: project, trace: false)
            let report = try await EntryPlaceholderInspector.inspect(
                project: project, settings: settings
            )
            let findings = report.findings.prefix(input.maximumFindings).map { finding in
                Finding(
                    entryID: finding.entryID,
                    entryIndex: finding.entryIndex,
                    lineIndex: finding.lineIndex,
                    entityAlias: finding.entityAlias,
                    kind: finding.kind?.rawValue,
                    detection: finding.detection.rawValue,
                    location: finding.location?.description,
                    entryLocation: finding.entryLocation?.description
                )
            }
            return Output(
                entryCount: report.entryCount,
                affectedEntryCount: report.affectedEntryCount,
                totalOccurrences: report.totalOccurrences,
                findings: findings,
                truncated: report.totalOccurrences > findings.count
            )
        }
    }
}
