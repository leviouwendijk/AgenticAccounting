import Agentic
import AgenticPDF
import Macros
import Path
import Schema

public extension Accounting.Tools {
    /// Performs the PDF read itself; callers cannot supply a forged verification result.
    @Tool("accounting_verify_pdf_invoice_evidence")
    struct VerifyPDFInvoiceEvidence: Tool {
        private typealias Inference = Accounting.Inferences.ExtractPDFInvoice
        private typealias Verifier = PDF.Tools.VerifyTextEvidence

        @JSONSchema
        public struct Input: HashableSource {
            public let evidence: Accounting.Inferences.ExtractPDFInvoice.Input
            public let proposal: Accounting.Inferences.ExtractPDFInvoice.Output

            public init(
                evidence: Accounting.Inferences.ExtractPDFInvoice.Input,
                proposal: Accounting.Inferences.ExtractPDFInvoice.Output
            ) {
                self.evidence = evidence
                self.proposal = proposal
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            @JSONSchema
            public struct Candidate: HashableResult {
                /// The interpreted field, including normalizedValue, remains a proposal.
                public let proposal: Accounting.Inferences.ExtractPDFInvoice.Output.Candidate
                /// These quotations were checked against the current PDF source.
                public let verifiedCitations: [PDF.Tools.VerifyTextEvidence.Input.Claim]
            }

            public let sourceFingerprint: String
            public let proposedKind: Accounting.Inferences.ExtractPDFInvoice.Output.Kind
            public let candidates: [Candidate]
            public let verifiedCitationCount: Int
            public let unresolved: [String]
            public let warnings: [String]
        }

        public enum Failure: Error, Sendable {
            case no_citations
            case inconsistent_verification_result
        }

        public static let purpose = """
        Resolve proposed invoice field citations, then verify every quoted span
        against the current workspace-authorized PDF. Do not book accounting
        entries or treat normalized values, VAT treatment, document completeness,
        or commercial authenticity as verified. A failure rejects the entire
        request; batches never silently omit citations.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private struct Prepared {
            let resolution: PDFInvoiceCitationResolution
            let requests: [Verifier.Input]
        }

        private static func prepare(_ input: Input) throws -> Prepared {
            let resolution = try PDFInvoiceCitationResolution(
                evidence: input.evidence,
                proposal: input.proposal
            )
            let claims: [Verifier.Input.Claim] = resolution.candidates.flatMap { candidate in
                candidate.citations.map {
                    Verifier.Input.Claim(
                        lineID: $0.lineID,
                        lineReference: $0.lineReference,
                        quote: $0.quote,
                        startUTF16: $0.startUTF16,
                        endUTF16: $0.endUTF16
                    )
                }
            }
            guard !claims.isEmpty else { throw Failure.no_citations }

            let root = PathAccessRootIdentifier(rawValue: resolution.rootID)
            let requests: [Verifier.Input] = stride(from: 0, to: claims.count, by: 128).map { offset in
                let end = offset + min(128, claims.count - offset)
                let batch = Array(claims[offset..<end])
                return Verifier.Input(
                    rootID: root,
                    path: resolution.path,
                    expectedFingerprint: resolution.sourceFingerprint,
                    recognition: batch.contains { $0.lineReference.snapshotID == "vision" },
                    claims: batch
                )
            }
            return Prepared(resolution: resolution, requests: requests)
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            let prepared = try Self.prepare(input)
            let verifier = Verifier()
            var first: ToolPreflight?
            for request in prepared.requests {
                let checked = try await verifier.preflight(request, in: context)
                if first == nil { first = checked }
            }
            guard let first else { throw Failure.no_citations }
            return ToolPreflight(
                tool: Self.definition.identifier,
                risk: first.risk,
                summary: "Verify \(prepared.resolution.candidates.count) invoice field proposal(s) against PDF quotations",
                access: first.access,
                estimates: first.estimates,
                preview: first.preview,
                mayChangeSource: first.mayChangeSource,
                sideEffects: first.sideEffects,
                policyChecks: first.policyChecks,
                warnings: first.warnings
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            let prepared = try Self.prepare(input)
            let verifier = Verifier()
            var verified: [Verifier.Input.Claim] = []
            for request in prepared.requests {
                let result = try await verifier.call(request, in: context)
                guard result.sourceFingerprint == prepared.resolution.sourceFingerprint,
                      result.verified == request.claims else {
                    throw Failure.inconsistent_verification_result
                }
                verified.append(contentsOf: result.verified)
            }

            var nextCitation = 0
            let candidates: [Output.Candidate] = prepared.resolution.candidates.map { candidate in
                let count = candidate.citations.count
                let end = nextCitation + count
                let citations = Array(verified[nextCitation..<end])
                nextCitation = end
                return Output.Candidate(
                    proposal: candidate.proposal,
                    verifiedCitations: citations
                )
            }
            return Output(
                sourceFingerprint: prepared.resolution.sourceFingerprint,
                proposedKind: prepared.resolution.proposedKind,
                candidates: candidates,
                verifiedCitationCount: verified.count,
                unresolved: prepared.resolution.unresolved,
                warnings: prepared.resolution.warnings
            )
        }
    }
}
