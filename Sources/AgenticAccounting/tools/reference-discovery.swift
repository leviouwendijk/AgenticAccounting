import Accounting
import Agentic
import Foundation
import Macros
import Primitives
import Schema
import Search

public extension Accounting.Tools {
    @Tool("accounting_search_entities")
    struct SearchEntities: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let text: String?
            public let references: [String]?
            public let page: Discovery.Page?

            public init(
                text: String? = nil,
                references: [String] = [],
                page: Discovery.Page = .init()
            ) {
                self.text = text
                self.references = references
                self.page = page
            }
        }

        @JSONSchema
        public struct Hit: HashableResult {
            public let reference: String
            public let alias: String
            public let label: String
            public let location: String?
            public let score: Int

            public init(
                reference: String,
                alias: String,
                label: String,
                location: String?,
                score: Int
            ) {
                self.reference = reference
                self.alias = alias
                self.label = label
                self.location = location
                self.score = score
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let searchedCount: Int
            public let matchedCount: Int
            public let hits: [Hit]
            public let nextOffset: Int?

            public init(
                searchedCount: Int,
                matchedCount: Int,
                hits: [Hit],
                nextOffset: Int?
            ) {
                self.searchedCount = searchedCount
                self.matchedCount = matchedCount
                self.hits = hits
                self.nextOffset = nextOffset
            }
        }

        public static let purpose = """
        Search declared accounting entities by textual details, full-chain
        identifier or alias. No fallback silently resolves ambiguous aliases.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            let workspace = try AccountingReferenceCatalog.authorize(
                context,
                toolName: Self.identifier.rawValue,
                accounts: false,
                entities: true
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Search declared entities",
                access: .init(
                    targets: AccountingReferenceCatalog.targets(
                        accounts: false,
                        entities: true
                    ),
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.read, .scan]
                ),
                sideEffects: []
            )
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            let catalog = try AccountingReferenceCatalog.load(
                context,
                toolName: Self.identifier.rawValue,
                accounts: false,
                entities: true
            )
            let definitions = (catalog.entities?.byFull.values.map { $0 } ?? [])
                .sorted {
                    $0.key.identifier(displaying: .fullchain)
                        < $1.key.identifier(displaying: .fullchain)
                }
            var predicates: [StructuredPredicate] = []
            if let text = AccountingDiscoverySupport.filterText(
                input.text,
                fields: ["reference", "alias", "label", "details", "metadata"]
            ) {
                predicates.append(text)
            }
            if let references = input.references, !references.isEmpty {
                predicates.append(
                    .any([
                        .oneOf(
                            field: "reference",
                            values: references.map { .text($0) }
                        ),
                        .oneOf(
                            field: "alias",
                            values: references.map { .text($0) }
                        )
                    ])
                )
            }
            let fields: [[String: [StructuredValue]]] = definitions.map { definition in
                var fields: [String: [StructuredValue]] = [
                    "reference": [.text(definition.key.identifier(displaying: .fullchain))],
                    "alias": [.text(definition.key.alias.string)]
                ]
                AccountingDiscoverySupport.append(
                    definition.effectiveDisplayName,
                    field: "label",
                    to: &fields
                )
                AccountingDiscoverySupport.append(
                    definition.effectiveDetails,
                    field: "details",
                    to: &fields
                )
                for (key, value) in definition.metadata {
                    AccountingDiscoverySupport.append(
                        "\(key)=\(value)",
                        field: "metadata",
                        to: &fields
                    )
                }
                return fields
            }
            let result = try AccountingDiscoverySupport.search(
                fields: fields,
                predicates: predicates,
                schema: [
                    .init("reference", kind: .text),
                    .init("alias", kind: .text),
                    .init("label", kind: .text),
                    .init("details", kind: .text),
                    .init("metadata", kind: .text, multiple: true)
                ],
                ordering: [.field("reference", ascending: true)],
                page: input.page ?? .init()
            )
            return .init(
                searchedCount: result.searchedCount,
                matchedCount: result.matchedCount,
                hits: result.hits.map { hit in
                    let definition = definitions[hit.id]
                    return Hit(
                        reference: definition.key.identifier(displaying: .fullchain),
                        alias: definition.key.alias.string,
                        label: definition.effectiveDisplayName ?? definition.key.alias.string,
                        location: definition.location?.description,
                        score: hit.score
                    )
                },
                nextOffset: result.nextOffset
            )
        }
    }

    @Tool("accounting_read_entities")
    struct ReadEntities: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let references: [String]

            public init(
                references: [String]
            ) {
                self.references = references
            }
        }

        @JSONSchema
        public struct Record: HashableResult {
            public let reference: String
            public let location: String?
            public let value: JSONValue

            public init(
                reference: String,
                location: String?,
                value: JSONValue
            ) {
                self.reference = reference
                self.location = location
                self.value = value
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let records: [Record]
            public let missingReferences: [String]
            public let ambiguousReferences: [String]

            public init(
                records: [Record],
                missingReferences: [String],
                ambiguousReferences: [String]
            ) {
                self.records = records
                self.missingReferences = missingReferences
                self.ambiguousReferences = ambiguousReferences
            }
        }

        public enum Failure: Error {
            case invalidReferences
        }

        public static let purpose = """
        Retrieve full canonical entity declarations by full-chain reference or
        alias, with explicit missing and ambiguous results and no silent guessing.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            try Self.validate(input)
            let workspace = try AccountingReferenceCatalog.authorize(
                context,
                toolName: Self.identifier.rawValue,
                accounts: false,
                entities: true
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Read declared entities",
                access: .init(
                    targets: AccountingReferenceCatalog.targets(
                        accounts: false,
                        entities: true
                    ),
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.read, .scan]
                ),
                sideEffects: []
            )
        }

        private static func validate(_ input: Input) throws {
            guard !input.references.isEmpty,
                  input.references.count <= 100,
                  input.references.allSatisfy({ !$0.isEmpty }) else {
                throw Failure.invalidReferences
            }
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            try Self.validate(input)
            let catalog = try AccountingReferenceCatalog.load(
                context,
                toolName: Self.identifier.rawValue,
                accounts: false,
                entities: true
            )
            let definitions = catalog.entities?.byFull.values.map { $0 } ?? []
            var byReference: [String: [EntityDef]] = [:]
            for definition in definitions {
                let full = definition.key.identifier(displaying: .fullchain)
                byReference[full, default: []].append(definition)
                let alias = definition.key.alias.string
                if alias != full {
                    byReference[alias, default: []].append(definition)
                }
            }
            var records: [Record] = []
            var missing: [String] = []
            var ambiguous: [String] = []
            for reference in input.references {
                let matches = byReference[reference] ?? []
                switch matches.count {
                case 0:
                    missing.append(reference)
                case 1:
                    let definition = matches[0]
                    records.append(
                        .init(
                            reference: definition.key.identifier(displaying: .fullchain),
                            location: definition.location?.description,
                            value: try JSONCoding.default.value(definition)
                        )
                    )
                default:
                    ambiguous.append(reference)
                }
            }
            return .init(
                records: records,
                missingReferences: missing,
                ambiguousReferences: ambiguous
            )
        }
    }

    @Tool("accounting_search_accounts")
    struct SearchAccounts: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let text: String?
            public let ids: Discovery.IDs?
            public let references: [String]?
            public let postable: Bool?
            public let page: Discovery.Page?

            public init(
                text: String? = nil,
                ids: Discovery.IDs? = nil,
                references: [String] = [],
                postable: Bool? = nil,
                page: Discovery.Page = .init()
            ) {
                self.text = text
                self.ids = ids
                self.references = references
                self.postable = postable
                self.page = page
            }
        }

        @JSONSchema
        public struct Hit: HashableResult {
            public let id: Int
            public let code: String
            public let label: String
            public let postable: Bool
            public let score: Int

            public init(
                id: Int,
                code: String,
                label: String,
                postable: Bool,
                score: Int
            ) {
                self.id = id
                self.code = code
                self.label = label
                self.postable = postable
                self.score = score
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let searchedCount: Int
            public let matchedCount: Int
            public let hits: [Hit]
            public let nextOffset: Int?

            public init(
                searchedCount: Int,
                matchedCount: Int,
                hits: [Hit],
                nextOffset: Int?
            ) {
                self.searchedCount = searchedCount
                self.matchedCount = matchedCount
                self.hits = hits
                self.nextOffset = nextOffset
            }
        }

        public static let purpose = """
        Search the active account chart by numeric ID range, code, labels,
        or postability using typed structured predicates.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            let workspace = try AccountingReferenceCatalog.authorize(
                context,
                toolName: Self.identifier.rawValue,
                accounts: true,
                entities: false
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Search active chart accounts",
                access: .init(
                    targets: AccountingReferenceCatalog.targets(
                        accounts: true,
                        entities: false
                    ),
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.read, .scan]
                ),
                sideEffects: []
            )
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            let catalog = try AccountingReferenceCatalog.load(
                context,
                toolName: Self.identifier.rawValue,
                accounts: true,
                entities: false
            )
            let accounts = (catalog.accounts?.all ?? []).sorted { $0.id < $1.id }
            var predicates: [StructuredPredicate] = []
            if let ids = try AccountingDiscoverySupport.rangePredicate(input.ids) {
                predicates.append(ids)
            }
            if let text = AccountingDiscoverySupport.filterText(
                input.text,
                fields: ["code", "short_label", "long_label"]
            ) {
                predicates.append(text)
            }
            if let references = AccountingDiscoverySupport.exactText(
                input.references ?? [],
                field: "code"
            ) {
                predicates.append(references)
            }
            if let postable = input.postable {
                predicates.append(
                    .equal(field: "postable", value: .boolean(postable))
                )
            }
            let fields: [[String: [StructuredValue]]] = accounts.map { account in
                [
                    "id": [.integer(Int64(account.id))],
                    "code": [.text(account.codes.code)],
                    "short_label": [.text(account.labels.short)],
                    "long_label": [.text(account.labels.long)],
                    "postable": [.boolean(account.postable)]
                ]
            }
            let result = try AccountingDiscoverySupport.search(
                fields: fields,
                predicates: predicates,
                schema: [
                    .init("id", kind: .integer),
                    .init("code", kind: .text),
                    .init("short_label", kind: .text),
                    .init("long_label", kind: .text),
                    .init("postable", kind: .boolean)
                ],
                ordering: [.field("id", ascending: true)],
                page: input.page ?? .init()
            )
            return .init(
                searchedCount: result.searchedCount,
                matchedCount: result.matchedCount,
                hits: result.hits.map { hit in
                    let account = accounts[hit.id]
                    return Hit(
                        id: account.id,
                        code: account.codes.code,
                        label: account.labels.short,
                        postable: account.postable,
                        score: hit.score
                    )
                },
                nextOffset: result.nextOffset
            )
        }
    }

    @Tool("accounting_read_accounts")
    struct ReadAccounts: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let ids: Discovery.IDs?
            public let references: [String]

            public init(
                ids: Discovery.IDs? = nil,
                references: [String] = []
            ) {
                self.ids = ids
                self.references = references
            }
        }

        @JSONSchema
        public struct Record: HashableResult {
            public let id: Int
            public let code: String
            public let value: JSONValue

            public init(
                id: Int,
                code: String,
                value: JSONValue
            ) {
                self.id = id
                self.code = code
                self.value = value
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let records: [Record]
            public let missingIDs: [Int]
            public let missingReferences: [String]

            public init(
                records: [Record],
                missingIDs: [Int],
                missingReferences: [String]
            ) {
                self.records = records
                self.missingIDs = missingIDs
                self.missingReferences = missingReferences
            }
        }

        public enum Failure: Error {
            case invalidSelection
        }

        public static let purpose = """
        Read canonical chart nodes by numeric ID(s) or exact RGS code(s).
        Return all found nodes with explicit missing identifiers, deduplicated.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            _ = try Self.validate(input)
            let workspace = try AccountingReferenceCatalog.authorize(
                context,
                toolName: Self.identifier.rawValue,
                accounts: true,
                entities: false
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Read active chart accounts",
                access: .init(
                    targets: AccountingReferenceCatalog.targets(
                        accounts: true,
                        entities: false
                    ),
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.read, .scan]
                ),
                sideEffects: []
            )
        }

        private static func validate(_ input: Input) throws -> [Int] {
            guard input.references.count <= 100,
                  input.references.allSatisfy({ !$0.isEmpty }) else {
                throw Failure.invalidSelection
            }
            let ids = try input.ids.map {
                try AccountingDiscoverySupport.identifiers($0)
            } ?? []
            guard !ids.isEmpty || !input.references.isEmpty,
                  ids.count + input.references.count <= 100 else {
                throw Failure.invalidSelection
            }
            return ids
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            let ids = try Self.validate(input)
            let catalog = try AccountingReferenceCatalog.load(
                context,
                toolName: Self.identifier.rawValue,
                accounts: true,
                entities: false
            )
            let accounts = catalog.accounts?.all ?? []
            let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            let byCode = Dictionary(uniqueKeysWithValues: accounts.map { ($0.codes.code, $0) })
            var selected: [RGSNode] = []
            var seen: Set<Int> = []
            var missingIDs: [Int] = []
            var missingReferences: [String] = []
            for id in ids {
                guard let account = byID[id] else {
                    missingIDs.append(id)
                    continue
                }
                if seen.insert(account.id).inserted {
                    selected.append(account)
                }
            }
            for reference in input.references {
                guard let account = byCode[reference] else {
                    missingReferences.append(reference)
                    continue
                }
                if seen.insert(account.id).inserted {
                    selected.append(account)
                }
            }
            let records = try selected.map { account in
                Record(
                    id: account.id,
                    code: account.codes.code,
                    value: try JSONCoding.default.value(account)
                )
            }
            return .init(
                records: records,
                missingIDs: missingIDs,
                missingReferences: missingReferences
            )
        }
    }
}
