import Agentic
import AgenticPDF
import Macros
import Schema

public extension Accounting.Inferences {
    /// Proposes interpretations of ambiguous, already source-verified invoice fields.
    /// An inference result does not establish which convention is correct.
    @Inference
    struct InferInvoiceConventions {
        @JSONSchema
        public struct Option: HashableSource {
            public let convention: String
            public let value: String

            public init(convention: String, value: String) {
                self.convention = convention
                self.value = value
            }
        }

        @JSONSchema
        public struct Evidence: HashableSource {
            public let candidateIndex: Int
            public let field: ExtractPDFInvoice.Output.Field
            public let rawValue: String
            public let status: String
            public let alternatives: [Option]
            /// Citations previously resolved against the authorized PDF.
            public let citations: [PDF.Tools.VerifyTextEvidence.Input.Claim]

            public init(
                candidateIndex: Int,
                field: ExtractPDFInvoice.Output.Field,
                rawValue: String,
                status: String,
                alternatives: [Option],
                citations: [PDF.Tools.VerifyTextEvidence.Input.Claim]
            ) {
                self.candidateIndex = candidateIndex
                self.field = field
                self.rawValue = rawValue
                self.status = status
                self.alternatives = alternatives
                self.citations = citations
            }
        }

        @JSONSchema
        public struct Input: HashableSource {
            public let sourceFingerprint: String
            public let evidence: [Evidence]
            /// Observations only; these are not a universal document convention.
            public let observedConventions: [String]

            public init(normalization: PDFInvoiceFinancialNormalization) {
                sourceFingerprint = normalization.sourceFingerprint
                observedConventions = normalization.observedConventions.map(\.rawValue)
                evidence = normalization.candidates.enumerated().map { index, candidate in
                    Evidence(
                        candidateIndex: index,
                        field: candidate.source.proposal.field,
                        rawValue: candidate.source.proposal.rawValue,
                        status: candidate.status.rawValue,
                        alternatives: candidate.alternatives.map {
                            Option(convention: $0.convention.rawValue, value: $0.value)
                        },
                        citations: candidate.source.verifiedCitations
                    )
                }
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            @JSONSchema
            public struct Selection: HashableResult {
                public let candidateIndex: Int
                public let convention: String
                public let value: String
                /// Indices in Input.evidence; not fabricated evidence references.
                public let supportingCandidateIndices: [Int]
                public let rationale: String

                public init(
                    candidateIndex: Int,
                    convention: String,
                    value: String,
                    supportingCandidateIndices: [Int],
                    rationale: String
                ) {
                    self.candidateIndex = candidateIndex
                    self.convention = convention
                    self.value = value
                    self.supportingCandidateIndices = supportingCandidateIndices
                    self.rationale = rationale
                }
            }

            public let sourceFingerprint: String
            public let selections: [Selection]
            /// Every remaining ambiguous candidate must be listed here.
            public let unresolvedCandidateIndices: [Int]
            public let warnings: [String]

            public init(
                sourceFingerprint: String,
                selections: [Selection],
                unresolvedCandidateIndices: [Int],
                warnings: [String] = []
            ) {
                self.sourceFingerprint = sourceFingerprint
                self.selections = selections
                self.unresolvedCandidateIndices = unresolvedCandidateIndices
                self.warnings = warnings
            }
        }

        public static let purpose = """
        Interpret ambiguous invoice number and date notations using the supplied
        source-verified invoice candidates. Choose only an exact (convention,
        value) pair listed among the candidate's alternatives; cite other
        candidate indices carrying relevant source evidence for each selection.
        Do not assume an invoice uses one uniform convention. Mixed Dutch and
        international formats can coexist, and supplier nationality or language
        alone is not conclusive. Never invent values, citations, or indices.
        If the document does not support a choice, include that candidate index
        in unresolvedCandidateIndices. Account for every ambiguous candidate
        exactly once, either selected or unresolved. Return no selections for
        invalid or already unambiguous candidates. Results are proposals only:
        deterministic checks and, when relevant, arithmetic validation must
        follow before financial use. Do not book entries or determine VAT law.
        """
    }
}
