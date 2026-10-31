import Accounting
import Agentic
import Foundation
import Macros
import Schema
import Search

public extension Accounting.Tools {
    @Tool("accounting_find_references")
    struct FindReferences: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let query: String
            public let kind: String
            public let limit: Int
            public let includeNonPostable: Bool

            public init(
                query: String,
                kind: String = "both",
                limit: Int = 8,
                includeNonPostable: Bool = false
            ) {
                self.query = query
                self.kind = kind
                self.limit = limit
                self.includeNonPostable = includeNonPostable
            }
        }

        @JSONSchema
        public struct Match: HashableResult {
            public let kind: String
            public let reference: String
            public let label: String
            public let postable: Bool?
            public let score: Int

            public init(kind: String, reference: String, label: String, postable: Bool?, score: Int) {
                self.kind = kind
                self.reference = reference
                self.label = label
                self.postable = postable
                self.score = score
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let matches: [Match]
            public let searchedCount: Int
            public let truncated: Bool

            public init(matches: [Match], searchedCount: Int, truncated: Bool) {
                self.matches = matches
                self.searchedCount = searchedCount
                self.truncated = truncated
            }
        }

        public enum Failure: Error {
            case invalidQuery
            case invalidKind
            case invalidLimit
        }

        public static let purpose = """
        Search project-declared accounts and entities by code, alias, or label.
        Returns bounded ranked candidates, not proof of valid resolution.
        Follow with accounting_resolve_references before drafting.
        Does not compile accounting entries.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func validate(_ input: Input) throws -> (accounts: Bool, entities: Bool) {
            guard !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  input.query.utf8.count <= 256 else { throw Failure.invalidQuery }
            guard (1...30).contains(input.limit) else { throw Failure.invalidLimit }
            switch input.kind {
            case "account": return (true, false)
            case "entity": return (false, true)
            case "both": return (true, true)
            default: throw Failure.invalidKind
            }
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            let kinds = try Self.validate(input)
            let workspace = try AccountingReferenceCatalog.authorize(
                context, toolName: Self.identifier.rawValue,
                accounts: kinds.accounts, entities: kinds.entities
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Search declared accounting references without compiling entries",
                access: .init(
                    targets: AccountingReferenceCatalog.targets(
                        accounts: kinds.accounts, entities: kinds.entities
                    ),
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.read, .scan]
                ),
                sideEffects: []
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            let kinds = try Self.validate(input)
            let catalog = try AccountingReferenceCatalog.load(
                context, toolName: Self.identifier.rawValue,
                accounts: kinds.accounts, entities: kinds.entities
            )
            var records: [Match] = []
            if let accounts = catalog.accounts {
                for node in accounts.all where input.includeNonPostable || node.postable {
                    records.append(.init(
                        kind: "account", reference: node.codes.code,
                        label: node.labels.short + " " + node.labels.long,
                        postable: node.postable, score: 0
                    ))
                }
            }
            if let entities = catalog.entities {
                for def in entities.byFull.values {
                    records.append(.init(
                        kind: "entity",
                        reference: def.key.identifier(displaying: .fullchain),
                        label: def.effectiveDisplayName ?? def.key.alias.string,
                        postable: nil, score: 0
                    ))
                }
            }
            records.sort {
                ($0.kind, $0.reference) < ($1.kind, $1.reference)
            }
            let corpus = SearchCorpus(documents: records.enumerated().map { index, record in
                SearchDocument(
                    id: index,
                    text: "\(record.reference) \(record.label)"
                )
            })
            let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let contains = TextSearch.search(
                query, in: corpus,
                options: .init(strategy: .contains, maximumResults: input.limit)
            )
            let result = contains.hits.isEmpty
                ? TextSearch.search(
                    query, in: corpus,
                    options: .init(strategy: .fuzzy, maximumResults: input.limit)
                )
                : contains
            let matches = result.hits.map { hit -> Match in
                let record = records[hit.documentID]
                return .init(
                    kind: record.kind, reference: record.reference, label: record.label,
                    postable: record.postable, score: hit.score.value
                )
            }
            return .init(
                matches: matches,
                searchedCount: result.searchedDocumentCount,
                truncated: result.truncated
            )
        }
    }
}
