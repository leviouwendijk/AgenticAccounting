import Agentic
import Foundation
import Macros
import Math
import Schema

@JSONSchema
public struct InvoicePaymentEvidence: HashableProduct {
    public let sourceID: String
    public let sourceFingerprint: String
    public let sourceKind: String
    public let grossAmount: String
    public let currency: String
    public let reference: String?

    public init(
        sourceID: String,
        sourceFingerprint: String,
        sourceKind: String,
        grossAmount: String,
        currency: String,
        reference: String? = nil
    ) {
        self.sourceID = sourceID
        self.sourceFingerprint = sourceFingerprint
        self.sourceKind = sourceKind
        self.grossAmount = grossAmount
        self.currency = currency
        self.reference = reference
    }
}

@JSONSchema
public struct InvoicePaymentCandidate: HashableProduct {
    public let source: InvoicePaymentEvidence
    public let referenceAgrees: Bool
    public let status: String
}

public enum InvoicePaymentMatching {
    /// Candidate discovery, not proof of payment or settlement.
    public static func candidates(invoice: PDFInvoiceProcessingResult,
                                  payments: [InvoicePaymentEvidence]) -> [InvoicePaymentCandidate] {
        guard let normalization = invoice.normalization else { return [] }
        let gross = normalization.candidates.filter {
            $0.source.proposal.field == .gross_amount && $0.status == .resolved
        }
        let currencies = normalization.candidates.filter {
            $0.source.proposal.field == .currency && $0.status == .resolved
        }
        guard gross.count == 1, currencies.count == 1,
              let amount = gross[0].value.flatMap({ try? DecimalArithmetic.parse($0) }),
              let currency = currencies[0].value else { return [] }
        let number = invoice.extraction?.candidates.first(where: {
            $0.field == .invoice_number
        })?.rawValue
        return payments.compactMap { payment in
            guard let candidate = try? DecimalArithmetic.parse(payment.grossAmount),
                  candidate.magnitude == amount.magnitude,
                  payment.currency.uppercased() == currency.uppercased() else { return nil }
            let agrees = number.map {
                payment.reference?.localizedStandardContains($0) == true
            } ?? false
            return .init(
                source: payment,
                referenceAgrees: agrees,
                status: agrees ? "candidate_reference_and_amount" : "candidate_amount_only"
            )
        }
    }
}

public extension Accounting.Inferences {
    @Inference
    struct DraftInvoiceEntry {
        @JSONSchema
        public struct Input: HashableSource {
            public let invoice: PDFInvoiceProcessingResult
            public let projectContext: Accounting.Tools.EntryContext.Output
            public let candidateIDs: [Int]
            public let accountCandidates: [Accounting.Tools.FindReferences.Match]
            public let entityCandidates: [Accounting.Tools.FindReferences.Match]
            public let paymentCandidates: [InvoicePaymentCandidate]
            public let supplementaryEvidence: String
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let source: String
            public let accountReferences: [String]
            public let entityReferences: [String]
            public let rationale: String
            public let unresolved: [String]
        }

        public static let purpose = """
        Draft one .ec entry for a source-verified invoice using supplied suggested IDs,
        discovered project references and explicit supporting financial evidence.
        Distinguish invoice obligations from payment settlements. Bank and PayNL
        records are candidate matches only. Do not invent account references,
        recoverable VAT, transaction IDs, facts or missing source evidence.
        Preserve unresolved classification and tax questions. Return a complete
        draft source and all account/entity references for deterministic checking.
        """
    }
}

@JSONSchema
public struct AccountingInvoiceEntryDraft: HashableResult {
    public let invoice: PDFInvoiceProcessingResult
    public let targetPath: String
    public let paymentCandidates: [InvoicePaymentCandidate]
    public let canonicalCandidates: [Accounting.Tools.SearchTransactions.Hit]
    public let duplicateHits: [Accounting.Tools.SearchEntries.Hit]
    public let suggestedIDs: [Int]
    public let source: String?
    public let proposedAccountReferences: [String]
    public let proposedEntityReferences: [String]
    public let referenceResolution: Accounting.Tools.ResolveReferences.Output?
    public let validation: Accounting.Tools.ValidateEntryDraft.Output?
    public let issues: [String]
    public let reviewable: Bool

    public init(
        invoice: PDFInvoiceProcessingResult,
        targetPath: String,
        paymentCandidates: [InvoicePaymentCandidate] = [],
        canonicalCandidates: [Accounting.Tools.SearchTransactions.Hit] = [],
        duplicateHits: [Accounting.Tools.SearchEntries.Hit] = [],
        suggestedIDs: [Int] = [],
        source: String? = nil,
        proposedAccountReferences: [String] = [],
        proposedEntityReferences: [String] = [],
        referenceResolution: Accounting.Tools.ResolveReferences.Output? = nil,
        validation: Accounting.Tools.ValidateEntryDraft.Output? = nil,
        issues: [String] = [],
        reviewable: Bool = false
    ) {
        self.invoice = invoice
        self.targetPath = targetPath
        self.paymentCandidates = paymentCandidates
        self.canonicalCandidates = canonicalCandidates
        self.duplicateHits = duplicateHits
        self.suggestedIDs = suggestedIDs
        self.source = source
        self.proposedAccountReferences = proposedAccountReferences
        self.proposedEntityReferences = proposedEntityReferences
        self.referenceResolution = referenceResolution
        self.validation = validation
        self.issues = issues
        self.reviewable = reviewable
    }
}

public enum InvoiceEntryPath {
    public static func isValid(_ path: String) -> Bool {
        let p = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 5, p[0] == "entries", p[1].count == 4,
              p[1].allSatisfy(\.isASCII), let year = Int(p[1]),
              (2000...2199).contains(year),
              let quarter = Int(p[2]), (1...4).contains(quarter),
              let month = Int(p[3]), (1...12).contains(month),
              (month - 1) / 3 + 1 == quarter,
              p[4].hasSuffix(".ec"), (4...100).contains(p[4].count),
              p[4].unicodeScalars.allSatisfy({ (65...90).contains($0.value) ||
                  (97...122).contains($0.value) || (48...57).contains($0.value) ||
                  $0 == "_" || $0 == "-" || $0 == "." }),
              !p[4].hasPrefix(".") else { return false }
        return true
    }
}

public enum InvoiceEntryIDInspection {
    public static func ids(in source: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*id\s*=\s*(\d+)\s*$"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return Int(source[range])
        }
    }
}

public extension Accounting.Programs {
    @Program
    struct PrepareInvoiceEntry {
        @JSONSchema
        public struct Input: HashableSource {
            public let invoice: PDFInvoiceProcessingResult
            public let targetPath: String
            public let accountQuery: String
            public let entityQuery: String
            public let suppliedEvidence: String
            public let payments: [InvoicePaymentEvidence]
            public let searchCanonicalTransactions: Bool

            public init(
                invoice: PDFInvoiceProcessingResult,
                targetPath: String,
                accountQuery: String,
                entityQuery: String,
                suppliedEvidence: String = "",
                payments: [InvoicePaymentEvidence] = [],
                searchCanonicalTransactions: Bool = false
            ) {
                self.invoice = invoice
                self.targetPath = targetPath
                self.accountQuery = accountQuery
                self.entityQuery = entityQuery
                self.suppliedEvidence = suppliedEvidence
                self.payments = payments
                self.searchCanonicalTransactions = searchCanonicalTransactions
            }
        }

        public typealias Output = AccountingInvoiceEntryDraft
        @InferenceSite public static var draft: Site<Accounting.Inferences.DraftInvoiceEntry>
        public static let purpose = """
        Prepare source-linked, validated accounting entry drafts from ProcessPDFInvoice.
        Discover and resolve real project references and optional transaction candidates.
        Read-only; never mutate the ledger or reserve identifiers.
        """
        public enum Failure: Error, Sendable {
            case invalid_target_path
            case invalid_reference_query
            case missing_invoice_number
            case invalid_candidate_limit
        }
        public init() {}

        public func run(_ input: Input, in context: ProgramContext) async throws -> Output {
            guard InvoiceEntryPath.isValid(input.targetPath) else { throw Failure.invalid_target_path }
            guard !input.accountQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !input.entityQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalid_reference_query
            }
            let invoice = input.invoice
            let payments = InvoicePaymentMatching.candidates(invoice: invoice, payments: input.payments)
            var issues = invoice.unresolved
            if !invoice.coverage.allSelectedLinesCollected || invoice.coverage.hasUnavailableText {
                issues.append("PDF text coverage incomplete")
            }
            guard invoice.verification != nil, invoice.normalization != nil,
                  invoice.extraction?.kind == .invoice, issues.isEmpty else {
                return .init(
                    invoice: invoice,
                    targetPath: input.targetPath,
                    paymentCandidates: payments,
                    issues: issues + ["Invoice source evidence unresolved"]
                )
            }
            guard let number = invoice.extraction?.candidates.first(where: {
                $0.field == .invoice_number
            })?.rawValue, !number.isEmpty else { throw Failure.missing_invoice_number }
            let duplicates: Accounting.Tools.SearchEntries.Output = try await context.invoke(
                Accounting.Tools.SearchEntries.definition.identifier,
                input: Accounting.Tools.SearchEntries.Input(text: number, page: .init(limit: 30)),
                as: Accounting.Tools.SearchEntries.Output.self
            )
            if duplicates.matchedCount > 0 {
                return .init(
                    invoice: invoice,
                    targetPath: input.targetPath,
                    paymentCandidates: payments,
                    duplicateHits: duplicates.hits,
                    issues: ["Potential duplicate invoice in ledger"]
                )
            }
            let project: Accounting.Tools.EntryContext.Output = try await context.invoke(
                Accounting.Tools.EntryContext.definition.identifier,
                input: Accounting.Tools.EntryContext.Input(),
                as: Accounting.Tools.EntryContext.Output.self
            )
            let suggested: Accounting.Tools.NextEntryIDs.Output = try await context.invoke(
                Accounting.Tools.NextEntryIDs.definition.identifier,
                input: Accounting.Tools.NextEntryIDs.Input(count: 8),
                as: Accounting.Tools.NextEntryIDs.Output.self
            )
            let accounts: Accounting.Tools.FindReferences.Output = try await context.invoke(
                Accounting.Tools.FindReferences.definition.identifier,
                input: Accounting.Tools.FindReferences.Input(
                    query: input.accountQuery,
                    kind: "account",
                    limit: 15
                ),
                as: Accounting.Tools.FindReferences.Output.self
            )
            let entities: Accounting.Tools.FindReferences.Output = try await context.invoke(
                Accounting.Tools.FindReferences.definition.identifier,
                input: Accounting.Tools.FindReferences.Input(
                    query: input.entityQuery,
                    kind: "entity",
                    limit: 15
                ),
                as: Accounting.Tools.FindReferences.Output.self
            )
            var canonical: [Accounting.Tools.SearchTransactions.Hit] = []
            if input.searchCanonicalTransactions {
                let amounts = invoice.normalization?.candidates.filter {
                    $0.source.proposal.field == .gross_amount && $0.status == .resolved
                } ?? []
                let currencies = invoice.normalization?.candidates.filter {
                    $0.source.proposal.field == .currency && $0.status == .resolved
                } ?? []
                if amounts.count == 1, currencies.count == 1,
                   let amount = amounts[0].value, let currency = currencies[0].value {
                    var offset = 0
                    repeat {
                        let page: Accounting.Tools.SearchTransactions.Output = try await context.invoke(
                            Accounting.Tools.SearchTransactions.definition.identifier,
                            input: Accounting.Tools.SearchTransactions.Input(
                                currency: currency,
                                amount: .init(lower: amount, upper: amount),
                                page: .init(limit: 30, offset: offset)
                            ), as: Accounting.Tools.SearchTransactions.Output.self
                        )
                        canonical.append(contentsOf: page.hits)
                        guard let next = page.nextOffset else { break }
                        guard next > offset, canonical.count < 300 else {
                            throw Failure.invalid_candidate_limit
                        }
                        offset = next
                    } while true
                } else {
                    issues.append("No unambiguous gross amount/currency for transaction matching")
                }
            }
            let proposal = try await context.infer(
                Self.draft,
                input: Accounting.Inferences.DraftInvoiceEntry.Input(
                    invoice: invoice,
                    projectContext: project,
                    candidateIDs: suggested.ids,
                    accountCandidates: accounts.matches,
                    entityCandidates: entities.matches,
                    paymentCandidates: payments,
                    supplementaryEvidence: input.suppliedEvidence
                )
            )
            issues.append(contentsOf: proposal.unresolved)
            guard !proposal.accountReferences.isEmpty, !proposal.entityReferences.isEmpty,
                  proposal.accountReferences.count + proposal.entityReferences.count <= 50 else {
                return .init(
                    invoice: invoice,
                    targetPath: input.targetPath,
                    paymentCandidates: payments,
                    canonicalCandidates: canonical,
                    suggestedIDs: suggested.ids,
                    source: proposal.source,
                    issues: issues + ["Missing or excessive references"]
                )
            }
            let refs = proposal.accountReferences.map {
                Accounting.Tools.ResolveReferences.Reference(kind: "account", reference: $0)
            } + proposal.entityReferences.map {
                Accounting.Tools.ResolveReferences.Reference(kind: "entity", reference: $0)
            }
            let resolved: Accounting.Tools.ResolveReferences.Output = try await context.invoke(
                Accounting.Tools.ResolveReferences.definition.identifier,
                input: Accounting.Tools.ResolveReferences.Input(references: refs),
                as: Accounting.Tools.ResolveReferences.Output.self
            )
            if resolved.results.contains(where: { $0.status != "resolved" }) {
                issues.append("Account/entity reference unresolved")
            }
            let validation: Accounting.Tools.ValidateEntryDraft.Output = try await context.invoke(
                Accounting.Tools.ValidateEntryDraft.definition.identifier,
                input: Accounting.Tools.ValidateEntryDraft.Input(source: proposal.source),
                as: Accounting.Tools.ValidateEntryDraft.Output.self
            )
            let entryIDs = try InvoiceEntryIDInspection.ids(in: proposal.source)
            if !validation.valid || validation.parsedEntryCount != 1 ||
               entryIDs.count != 1 || !suggested.ids.contains(entryIDs[0]) ||
               !proposal.source.contains(number) {
                issues.append("Draft failed project validation, ID or source-reference check")
            }
            return .init(
                invoice: invoice,
                targetPath: input.targetPath,
                paymentCandidates: payments,
                canonicalCandidates: canonical,
                duplicateHits: duplicates.hits,
                suggestedIDs: suggested.ids,
                source: proposal.source,
                proposedAccountReferences: proposal.accountReferences,
                proposedEntityReferences: proposal.entityReferences,
                referenceResolution: resolved,
                validation: validation,
                issues: issues,
                reviewable: issues.isEmpty
            )
        }
    }
}
