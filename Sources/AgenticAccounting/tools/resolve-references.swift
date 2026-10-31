import Accounting
import Agentic
import Foundation
import Macros
import Schema

public extension Accounting.Tools {
    @Tool("accounting_resolve_references")
    struct ResolveReferences: Tool {
        @JSONSchema
        public struct Reference: HashableSource {
            public let kind: String
            public let reference: String

            public init(kind: String, reference: String) {
                self.kind = kind
                self.reference = reference
            }
        }

        @JSONSchema
        public struct Input: HashableSource {
            public let references: [Reference]
            public init(references: [Reference]) { self.references = references }
        }

        @JSONSchema
        public struct Result: HashableResult {
            public let kind: String
            public let input: String
            public let status: String
            public let canonicalReference: String?
            public let label: String?
            public let postable: Bool?
            public let candidates: [String]
            public let message: String?

            public init(
                kind: String, input: String, status: String,
                canonicalReference: String? = nil, label: String? = nil,
                postable: Bool? = nil, candidates: [String] = [], message: String? = nil
            ) {
                self.kind = kind
                self.input = input
                self.status = status
                self.canonicalReference = canonicalReference
                self.label = label
                self.postable = postable
                self.candidates = candidates
                self.message = message
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let results: [Result]
            public init(results: [Result]) { self.results = results }
        }

        public enum Failure: Error {
            case invalidCount
            case invalidKind
            case invalidReference
        }

        public static let purpose = """
        Batch-check references against the active AccountStore and EntityStore.
        Use Accounting's actual resolvers; report nonpostable and ambiguous
        references without guessing. Return results in input order.
        Project loading, permission and ownership failures propagate.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func validate(_ input: Input) throws -> (accounts: Bool, entities: Bool) {
            guard (1...50).contains(input.references.count) else { throw Failure.invalidCount }
            for reference in input.references {
                guard reference.kind == "account" || reference.kind == "entity" else {
                    throw Failure.invalidKind
                }
                guard !reference.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      reference.reference.utf8.count <= 256 else {
                    throw Failure.invalidReference
                }
            }
            return (
                input.references.contains { $0.kind == "account" },
                input.references.contains { $0.kind == "entity" }
            )
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
                summary: "Resolve proposed accounting references without compiling entries",
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
            let results = input.references.map { reference -> Result in
                let text = reference.reference.trimmingCharacters(in: .whitespacesAndNewlines)
                if reference.kind == "account", let accounts = catalog.accounts {
                    let ref: AccountRef
                    if text.contains(".") {
                        ref = .path(text.components(separatedBy: "."))
                    } else if text.allSatisfy(\.isNumber) {
                        ref = .code(text)
                    } else {
                        ref = .identifier(text)
                    }
                    do {
                        let node = try accounts.resolve(ref, at: nil)
                        return .init(
                            kind: reference.kind, input: text,
                            status: node.postable ? "resolved" : "non_postable",
                            canonicalReference: node.codes.code,
                            label: node.labels.short, postable: node.postable
                        )
                    } catch let error as AccountStoreError {
                        let status: String
                        switch error {
                        case .notFound: status = "not_found"
                        default: status = "invalid"
                        }
                        return .init(kind: reference.kind, input: text,
                                     status: status, message: error.description)
                    } catch {
                        return .init(kind: reference.kind, input: text,
                                     status: "invalid", message: String(describing: error))
                    }
                }
                if reference.kind == "entity", let entities = catalog.entities {
                    do {
                        let parts = text.components(separatedBy: ".")
                        guard (1...3).contains(parts.count), !parts.contains("") else {
                            return .init(kind: reference.kind, input: text,
                                         status: "invalid", message: "Expected 1–3 entity path segments")
                        }
                        let alias = try EntityAlias.parse(parts[parts.count - 1])
                        let ref = EntityRef(
                            class: parts.count > 1 ? parts[0] : nil,
                            family: parts.count == 3 ? parts[1] : nil,
                            alias: alias
                        )
                        let entity = try entities.resolve(ref, at: nil)
                        return .init(
                            kind: reference.kind, input: text, status: "resolved",
                            canonicalReference: entity.key.identifier(displaying: .fullchain),
                            label: entity.effectiveDisplayName ?? entity.key.alias.string
                        )
                    } catch let error as EntityStoreError {
                        switch error {
                        case .notFound:
                            return .init(kind: reference.kind, input: text,
                                         status: "not_found", message: error.description)
                        case .ambiguousAlias(_, let candidates, _):
                            return .init(kind: reference.kind, input: text,
                                         status: "ambiguous", candidates: candidates.sorted(),
                                         message: error.description)
                        default:
                            return .init(kind: reference.kind, input: text,
                                         status: "invalid", message: error.description)
                        }
                    } catch {
                        return .init(kind: reference.kind, input: text,
                                     status: "invalid", message: String(describing: error))
                    }
                }
                return .init(kind: reference.kind, input: text,
                             status: "invalid", message: "Reference store unavailable")
            }
            return .init(results: results)
        }
    }
}
