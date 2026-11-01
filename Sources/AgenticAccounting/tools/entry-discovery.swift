import Accounting
import Agentic
import Foundation
import Macros
import Primitives
import Schema
import Search

public extension Accounting.Tools {
    @Tool("accounting_search_entries")
    struct SearchEntries: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let ids: Discovery.IDs?
            public let text: String?
            public let accounts: [String]?
            public let entities: [String]?
            public let groups: [String]?
            public let transactionIDs: [Int]?
            public let period: Discovery.Period?
            public let page: Discovery.Page?

            public init(
                ids: Discovery.IDs? = nil,
                text: String? = nil,
                accounts: [String] = [],
                entities: [String] = [],
                groups: [String] = [],
                transactionIDs: [Int] = [],
                period: Discovery.Period? = nil,
                page: Discovery.Page = .init()
            ) {
                self.ids = ids
                self.text = text
                self.accounts = accounts
                self.entities = entities
                self.groups = groups
                self.transactionIDs = transactionIDs
                self.period = period
                self.page = page
            }
        }

        @JSONSchema
        public struct Hit: HashableResult {
            public let id: Int
            public let details: String?
            public let location: String?
            public let score: Int

            public init(
                id: Int,
                details: String?,
                location: String?,
                score: Int
            ) {
                self.id = id
                self.details = details
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
        Search source-parsed accounting entries by ID selection, text, referenced
        account/entity, selection group, transaction ID and accounting period.
        Filters combine with AND; choices within each filter combine with OR.
        Returns source locations and bounded hits; no ledger compilation or mutation.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            let base = try AccountingDiscoverySupport.preflight(
                context: context,
                identifier: Self.identifier.rawValue,
                definition: Self.definition,
                directory: "entries",
                summary: "Search accounting entries"
            )
            guard input.entities?.isEmpty == false else {
                return base
            }
            let workspace = try AccountingReferenceCatalog.authorize(
                context,
                toolName: Self.identifier.rawValue,
                accounts: false,
                entities: true
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Search accounting entries",
                access: .init(
                    targets: ["config/settings.ec", "entries", "config/entities"],
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
            let loaded = try AccountingDiscoverySupport.entries(
                context,
                toolName: Self.identifier.rawValue
            )
            let records = loaded.records.filter { $0.id != nil }.sorted {
                ($0.id ?? Int.max, $0.location?.description ?? "")
                    < ($1.id ?? Int.max, $1.location?.description ?? "")
            }
            let entityStore: EntityStore?
            if input.entities?.isEmpty == false {
                let catalog = try AccountingReferenceCatalog.load(
                    context,
                    toolName: Self.identifier.rawValue,
                    accounts: false,
                    entities: true
                )
                entityStore = catalog.entities
            } else {
                entityStore = nil
            }

            var predicates: [StructuredPredicate] = []
            if let ids = try AccountingDiscoverySupport.rangePredicate(input.ids) {
                predicates.append(ids)
            }
            if let text = AccountingDiscoverySupport.filterText(
                input.text,
                fields: ["details", "metadata"]
            ) {
                predicates.append(text)
            }
            if let accounts = AccountingDiscoverySupport.exactText(
                input.accounts ?? [],
                field: "account"
            ) {
                predicates.append(accounts)
            }
            if let entities = AccountingDiscoverySupport.exactText(
                input.entities ?? [],
                field: "entity"
            ) {
                predicates.append(entities)
            }
            if let groups = AccountingDiscoverySupport.exactText(
                EntrySelect.normalizedUniqueGroups(input.groups ?? []),
                field: "group"
            ) {
                predicates.append(groups)
            }
            if let transactionIDs = input.transactionIDs, !transactionIDs.isEmpty {
                predicates.append(
                    .oneOf(
                        field: "transaction_id",
                        values: transactionIDs.map { .integer(Int64($0)) }
                    )
                )
            }
            if let period = try AccountingDiscoverySupport.periodPredicate(
                input.period,
                timeZone: loaded.settings.entry.defaultTimezone
            ) {
                predicates.append(period)
            }

            let fields: [[String: [StructuredValue]]] = records.map { entry in
                var fields: [String: [StructuredValue]] = [:]
                if let id = entry.id {
                    fields["id"] = [.integer(Int64(id))]
                }
                if let date = entry.resolvedPostingDate(using: loaded.settings) {
                    fields["date"] = [.date(date)]
                }
                AccountingDiscoverySupport.append(
                    entry.details,
                    field: "details",
                    to: &fields
                )
                for line in entry.lines {
                    let account: String
                    switch line.account {
                    case .code(let code), .identifier(let code):
                        account = code
                    case .path(let path):
                        account = path.joined(separator: ".")
                    }
                    AccountingDiscoverySupport.append(
                        account,
                        field: "account",
                        to: &fields
                    )
                    AccountingDiscoverySupport.append(
                        line.entity.printable,
                        field: "entity",
                        to: &fields
                    )
                    if let resolved = try? entityStore?.resolve(
                        line.entity,
                        at: entry.location
                    ) {
                        AccountingDiscoverySupport.append(
                            resolved.key.identifier(displaying: .fullchain),
                            field: "entity",
                            to: &fields
                        )
                    }
                }
                for group in entry.select?.groups ?? [] {
                    AccountingDiscoverySupport.append(
                        EntrySelect.normalizeGroup(group),
                        field: "group",
                        to: &fields
                    )
                }
                for id in entry.transactionReferences {
                    fields["transaction_id", default: []].append(.integer(Int64(id)))
                }
                for (key, value) in entry.metadata {
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
                    .init("id", kind: .integer),
                    .init("date", kind: .date),
                    .init("details", kind: .text),
                    .init("metadata", kind: .text, multiple: true),
                    .init("account", kind: .text, multiple: true),
                    .init("entity", kind: .text, multiple: true),
                    .init("group", kind: .text, multiple: true),
                    .init("transaction_id", kind: .integer, multiple: true)
                ],
                ordering: [.field("id", ascending: true)],
                page: input.page ?? .init()
            )
            return .init(
                searchedCount: result.searchedCount,
                matchedCount: result.matchedCount,
                hits: result.hits.compactMap { hit in
                    let entry = records[hit.id]
                    guard let id = entry.id else {
                        return nil
                    }
                    return Hit(
                        id: id,
                        details: entry.details,
                        location: entry.location?.description,
                        score: hit.score
                    )
                },
                nextOffset: result.nextOffset
            )
        }
    }

    @Tool("accounting_read_entries")
    struct ReadEntries: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let ids: Discovery.IDs

            public init(
                ids: Discovery.IDs
            ) {
                self.ids = ids
            }
        }

        @JSONSchema
        public struct Record: HashableResult {
            public let id: Int
            public let location: String?
            public let value: JSONValue
            public let postingAmounts: [String]

            public init(
                id: Int,
                location: String?,
                value: JSONValue,
                postingAmounts: [String]
            ) {
                self.id = id
                self.location = location
                self.value = value
                self.postingAmounts = postingAmounts
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let records: [Record]
            public let missingIDs: [Int]
            public let ambiguousIDs: [Int]

            public init(
                records: [Record],
                missingIDs: [Int],
                ambiguousIDs: [Int]
            ) {
                self.records = records
                self.missingIDs = missingIDs
                self.ambiguousIDs = ambiguousIDs
            }
        }

        public static let purpose = """
        Read complete source-parsed entries by explicit IDs or bounded inclusive ID
        range. Return existing entries even when other IDs are missing. Duplicate
        Collisions between source entries with the same ID are ambiguous; repeated
        requested IDs are deduplicated. Decimal posting amounts are separately
        preserved as exact strings alongside the native structured record value.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            _ = try AccountingDiscoverySupport.identifiers(input.ids)
            return try AccountingDiscoverySupport.preflight(
                context: context,
                identifier: Self.identifier.rawValue,
                definition: Self.definition,
                directory: "entries",
                summary: "Read accounting entries"
            )
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            let ids = try AccountingDiscoverySupport.identifiers(input.ids)
            let loaded = try AccountingDiscoverySupport.entries(
                context,
                toolName: Self.identifier.rawValue
            )
            var byID: [Int: [Entry]] = [:]
            for entry in loaded.records {
                if let id = entry.id {
                    byID[id, default: []].append(entry)
                }
            }

            var records: [Record] = []
            var missing: [Int] = []
            var ambiguous: [Int] = []

            for id in ids {
                switch byID[id]?.count ?? 0 {
                case 0:
                    missing.append(id)
                case 1:
                    if let entry = byID[id]?.first {
                        records.append(
                            .init(
                                id: id,
                                location: entry.location?.description,
                                value: try JSONCoding.default.value(entry),
                                postingAmounts: entry.lines.map {
                                    NSDecimalNumber(decimal: $0.amount).stringValue
                                }
                            )
                        )
                    }
                default:
                    ambiguous.append(id)
                }
            }
            return .init(
                records: records,
                missingIDs: missing,
                ambiguousIDs: ambiguous
            )
        }
    }
}
