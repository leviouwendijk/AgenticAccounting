import Agentic
import AgenticPDF
import Foundation
import Macros
import Schema

public extension Accounting.Inferences {
    @Inference
    struct AssociateInvoiceVATBands {
        @JSONSchema
        public struct Evidence: HashableSource {
            public let index: Int
            public let field: ExtractPDFInvoice.Output.Field
            public let rawValue: String
            public let normalizedAlternatives: [String]
            public let citations: [PDF.Tools.VerifyTextEvidence.Input.Claim]

            public init(index: Int, candidate: PDFInvoiceFinancialNormalization.Candidate) {
                self.index = index
                field = candidate.source.proposal.field
                rawValue = candidate.source.proposal.rawValue
                normalizedAlternatives = candidate.alternatives.map(\.value)
                citations = candidate.source.verifiedCitations
            }
        }

        @JSONSchema
        public struct Input: HashableSource {
            public let sourceFingerprint: String
            public let evidence: [Evidence]

            public init(normalization: PDFInvoiceFinancialNormalization) {
                sourceFingerprint = normalization.sourceFingerprint
                evidence = normalization.candidates.enumerated().map { Evidence(index: $0.offset, candidate: $0.element) }
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            @JSONSchema
            public struct Band: HashableResult {
                public let baseIndex: Int
                public let rateIndex: Int
                public let amountIndex: Int
                public let rationale: String

                public init(baseIndex: Int, rateIndex: Int, amountIndex: Int, rationale: String) {
                    self.baseIndex = baseIndex
                    self.rateIndex = rateIndex
                    self.amountIndex = amountIndex
                    self.rationale = rationale
                }
            }

            public let sourceFingerprint: String
            public let bands: [Band]
            public let unassignedBaseIndices: [Int]
            public let unassignedAmountIndices: [Int]
            public let claimedCompleteBandSet: Bool
            public let warnings: [String]

            public init(
                sourceFingerprint: String,
                bands: [Band],
                unassignedBaseIndices: [Int],
                unassignedAmountIndices: [Int],
                claimedCompleteBandSet: Bool,
                warnings: [String] = []
            ) {
                self.sourceFingerprint = sourceFingerprint
                self.bands = bands
                self.unassignedBaseIndices = unassignedBaseIndices
                self.unassignedAmountIndices = unassignedAmountIndices
                self.claimedCompleteBandSet = claimedCompleteBandSet
                self.warnings = warnings
            }
        }

        public static let purpose = """
        Propose VAT base/rate/amount associations only from indexed, source-verified invoice candidates.
        Identify each base and amount exactly once, either in a proposed band or unassigned.
        A rate may be shared across bands. Never group on field order alone, invent indices,
        or treat arithmetic agreement as proof of association. Mark a complete band set only
        when the observed document provides a reason to believe every band is represented;
        this remains a proposal, not proof of source completeness or tax treatment.
        """
    }
}

@JSONSchema
public struct PDFInvoiceVATBandResolution: HashableProduct {
    public typealias Normalization = PDFInvoiceFinancialNormalization
    public typealias Inference = Accounting.Inferences.AssociateInvoiceVATBands

    public enum Failure: Error, Sendable, Equatable {
        case input_mismatch
        case source_mismatch
        case invalid_index(Int)
        case incorrect_field(Int)
        case duplicate_assignment(Int)
        case missing_disposition(Int)
        case empty_rationale(Int)
        case incomplete_claim
    }

    public let normalization: Normalization
    public let proposal: Inference.Output
    public let proposedBands: [PDFInvoiceArithmeticAssessment.VATBand]

    public init(normalization: Normalization, input: Inference.Input, proposal: Inference.Output) throws {
        guard input == .init(normalization: normalization) else { throw Failure.input_mismatch }
        guard proposal.sourceFingerprint == normalization.sourceFingerprint else { throw Failure.source_mismatch }

        func check(_ index: Int, _ field: Normalization.Field) throws {
            guard normalization.candidates.indices.contains(index) else { throw Failure.invalid_index(index) }
            guard normalization.candidates[index].source.proposal.field == field,
                  !normalization.candidates[index].source.verifiedCitations.isEmpty else {
                throw Failure.incorrect_field(index)
            }
        }
        var usedBase = Set<Int>()
        var usedAmount = Set<Int>()
        var bands: [PDFInvoiceArithmeticAssessment.VATBand] = []
        for (offset, band) in proposal.bands.enumerated() {
            try check(band.baseIndex, .vat_base)
            try check(band.rateIndex, .vat_rate)
            try check(band.amountIndex, .vat_amount)
            guard !band.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.empty_rationale(offset)
            }
            guard usedBase.insert(band.baseIndex).inserted else { throw Failure.duplicate_assignment(band.baseIndex) }
            guard usedAmount.insert(band.amountIndex).inserted else { throw Failure.duplicate_assignment(band.amountIndex) }
            bands.append(.init(baseIndex: band.baseIndex, rateIndex: band.rateIndex, amountIndex: band.amountIndex))
        }
        for index in proposal.unassignedBaseIndices {
            try check(index, .vat_base)
            guard usedBase.insert(index).inserted else { throw Failure.duplicate_assignment(index) }
        }
        for index in proposal.unassignedAmountIndices {
            try check(index, .vat_amount)
            guard usedAmount.insert(index).inserted else { throw Failure.duplicate_assignment(index) }
        }
        for index in normalization.candidates.indices {
            switch normalization.candidates[index].source.proposal.field {
            case .vat_base where !usedBase.contains(index): throw Failure.missing_disposition(index)
            case .vat_amount where !usedAmount.contains(index): throw Failure.missing_disposition(index)
            default: break
            }
        }
        if proposal.claimedCompleteBandSet &&
            (!proposal.unassignedBaseIndices.isEmpty || !proposal.unassignedAmountIndices.isEmpty || bands.isEmpty) {
            throw Failure.incomplete_claim
        }
        self.normalization = normalization
        self.proposal = proposal
        proposedBands = bands
    }
}
