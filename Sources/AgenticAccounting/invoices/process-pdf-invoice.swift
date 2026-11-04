import Agentic
import AgenticPDF
import AgenticIO
import Foundation
import Macros
import Path
import Schema

/// Technical line-enumeration coverage; it cannot certify invoice authenticity or completeness.
@JSONSchema
public struct PDFInvoiceCoverage: HashableProduct {
    @JSONSchema
    public struct Page: HashableProduct {
        public let index: Int
        public let nativeLines: Int
        public let recognizedLines: Int
        public let selectedMode: String
        public let retrievedLines: Int
        public let expectedLines: Int
    }

    public let sourceFingerprint: String
    public let pageCount: Int
    public let pages: [Page]
    public let metadataComplete: Bool
    public let allSelectedLinesCollected: Bool
    public let hasUnavailableText: Bool

    public init(sourceFingerprint: String, pageCount: Int, pages: [Page]) {
        self.sourceFingerprint = sourceFingerprint
        self.pageCount = pageCount
        self.pages = pages
        metadataComplete = pages.count == pageCount &&
            Set(pages.map(\.index)) == Set(0..<pageCount)
        allSelectedLinesCollected = metadataComplete && pages.allSatisfy { $0.retrievedLines == $0.expectedLines }
        hasUnavailableText = pages.contains { $0.selectedMode == "none" }
    }
}

@JSONSchema
public struct PDFInvoiceProcessingResult: HashableResult {
    public typealias Extraction = Accounting.Inferences.ExtractPDFInvoice.Output
    public typealias Verification = Accounting.Tools.VerifyPDFInvoiceEvidence.Output

    public let coverage: PDFInvoiceCoverage
    public let extraction: Extraction?
    public let verification: Verification?
    public let normalization: PDFInvoiceFinancialNormalization?
    public let conventionResolution: PDFInvoiceConventionResolution?
    public let vatBandResolution: PDFInvoiceVATBandResolution?
    public let arithmetic: PDFInvoiceArithmeticAssessment?
    public let disambiguation: PDFInvoiceArithmeticDisambiguation?
    public let unresolved: [String]

    public init(
        coverage: PDFInvoiceCoverage,
        extraction: Extraction? = nil,
        verification: Verification? = nil,
        normalization: PDFInvoiceFinancialNormalization? = nil,
        conventionResolution: PDFInvoiceConventionResolution? = nil,
        vatBandResolution: PDFInvoiceVATBandResolution? = nil,
        arithmetic: PDFInvoiceArithmeticAssessment? = nil,
        disambiguation: PDFInvoiceArithmeticDisambiguation? = nil,
        unresolved: [String] = []
    ) {
        self.coverage = coverage
        self.extraction = extraction
        self.verification = verification
        self.normalization = normalization
        self.conventionResolution = conventionResolution
        self.vatBandResolution = vatBandResolution
        self.arithmetic = arithmetic
        self.disambiguation = disambiguation
        self.unresolved = unresolved
    }
}

public extension Accounting.Programs {
    @Program
    struct ProcessPDFInvoice {
        public typealias Output = PDFInvoiceProcessingResult

        @JSONSchema
        public struct Input: HashableSource {
            public let rootID: PathAccessRootIdentifier?
            public let path: String
            public let recognition: Bool
            public let roundingScale: Int?

            public init(rootID: PathAccessRootIdentifier? = nil, path: String, recognition: Bool = false,
                        roundingScale: Int? = nil) {
                self.rootID = rootID
                self.path = path
                self.recognition = recognition
                self.roundingScale = roundingScale
            }
        }

        @InferenceSite
        public static var extraction: Site<Accounting.Inferences.ExtractPDFInvoice>
        @InferenceSite
        public static var conventions: Site<Accounting.Inferences.InferInvoiceConventions>
        @InferenceSite
        public static var vatBands: Site<Accounting.Inferences.AssociateInvoiceVATBands>

        public static let purpose = """
        Read and enumerate an authorized PDF, infer invoice fields, verify quotations against current
        PDF bytes, normalize source values and conditionally assess notation and VAT associations.
        All computations are read-only and findings preserve uncertainty; no accounting entries are posted.
        """

        public enum Failure: Error, Sendable {
            case empty_document
            case inconsistent_document
            case inconsistent_page(Int)
            case nonprogressing_pagination
            case duplicate_evidence(String)
            case inconsistent_line_count(Int)
        }

        public init() {}

        public func run(_ input: Input, in context: ProgramContext) async throws -> Output {
            typealias Document = PDF.Tools.ReadDocument
            typealias Page = PDF.Tools.InspectPage

            var pageOffset = 0
            var allSummaries: [Document.Output.PageSummary] = []
            var sourceFingerprint: String?
            var pageCount: Int?
            repeat {
                let document: Document.Output = try await context.invoke(
                    Document.definition.identifier,
                    input: Document.Input(rootID: input.rootID, path: input.path,
                                          recognition: input.recognition, offset: pageOffset, limit: 64,
                                          expectedFingerprint: sourceFingerprint),
                    as: Document.Output.self
                )
                if let sourceFingerprint, sourceFingerprint != document.sourceFingerprint {
                    throw Failure.inconsistent_document
                }
                if let pageCount, pageCount != document.pageCount { throw Failure.inconsistent_document }
                sourceFingerprint = document.sourceFingerprint
                pageCount = document.pageCount
                guard !document.pages.isEmpty || document.pageCount == 0 else {
                    throw Failure.nonprogressing_pagination
                }
                guard document.pages.enumerated().allSatisfy({ offset, item in
                    item.index == pageOffset + offset
                }) else { throw Failure.inconsistent_document }
                allSummaries.append(contentsOf: document.pages)
                if let next = document.nextOffset {
                    guard next == pageOffset + document.pages.count, next > pageOffset else {
                        throw Failure.nonprogressing_pagination
                    }
                    pageOffset = next
                } else { break }
            } while true
            guard let sourceFingerprint, let pageCount, pageCount > 0 else { throw Failure.empty_document }
            guard allSummaries.count == pageCount else { throw Failure.inconsistent_document }

            var coveragePages: [PDFInvoiceCoverage.Page] = []
            var lines: [PDFLineEvidence] = []
            var seenLineIDs = Set<String>()
            for summary in allSummaries {
                let useNative = summary.nativeLines > 0
                let useRecognition = !useNative && input.recognition && summary.recognizedLines > 0
                let mode = useNative ? "native" : (useRecognition ? "recognition" : "none")
                let expected = useNative ? summary.nativeLines : (useRecognition ? summary.recognizedLines : 0)
                var received = 0
                if expected > 0 {
                    var lineOffset = 0
                    repeat {
                        let page: Page.Output = try await context.invoke(
                            Page.definition.identifier,
                            input: Page.Input(rootID: input.rootID, path: input.path,
                                              pageIndex: summary.index, recognition: input.recognition,
                                              evidence: useNative ? .native : .recognition,
                                              offset: lineOffset, limit: 100,
                                              expectedFingerprint: sourceFingerprint),
                            as: Page.Output.self
                        )
                        guard page.sourceFingerprint == sourceFingerprint,
                              page.pageIndex == summary.index, page.totalLines == expected else {
                            throw Failure.inconsistent_page(summary.index)
                        }
                        for line in page.lines {
                            guard seenLineIDs.insert(line.id).inserted else {
                                throw Failure.duplicate_evidence(line.id)
                            }
                            guard line.reference?.sourceFingerprint == sourceFingerprint,
                                  line.reference?.pageIndex == summary.index else {
                                throw Failure.inconsistent_page(summary.index)
                            }
                            lines.append(line)
                        }
                        received += page.lines.count
                        if let next = page.nextOffset {
                            guard next == lineOffset + page.lines.count, next > lineOffset,
                                  next <= expected else { throw Failure.nonprogressing_pagination }
                            lineOffset = next
                        } else { break }
                    } while true
                }
                guard received == expected else { throw Failure.inconsistent_line_count(summary.index) }
                coveragePages.append(.init(index: summary.index, nativeLines: summary.nativeLines,
                                           recognizedLines: summary.recognizedLines, selectedMode: mode,
                                           retrievedLines: received, expectedLines: expected))
            }
            let coverage = PDFInvoiceCoverage(sourceFingerprint: sourceFingerprint, pageCount: pageCount,
                                              pages: coveragePages)
            guard !lines.isEmpty else {
                return Output(coverage: coverage, unresolved: ["No usable PDF text was extracted"])
            }

            let evidence = Accounting.Inferences.ExtractPDFInvoice.Input(
                sourceFingerprint: sourceFingerprint, lines: lines,
                context: "Source enumeration coverage is technical only; never assume authentic or complete invoice"
            )
            let proposal = try await context.infer(Self.extraction, input: evidence)
            guard !proposal.candidates.isEmpty else {
                return Output(coverage: coverage, extraction: proposal,
                              unresolved: proposal.unresolved + ["No source-cited invoice fields proposed"])
            }
            let verified: Accounting.Tools.VerifyPDFInvoiceEvidence.Output = try await context.invoke(
                Accounting.Tools.VerifyPDFInvoiceEvidence.definition.identifier,
                input: Accounting.Tools.VerifyPDFInvoiceEvidence.Input(evidence: evidence, proposal: proposal),
                as: Accounting.Tools.VerifyPDFInvoiceEvidence.Output.self
            )
            guard verified.sourceFingerprint == sourceFingerprint else { throw Failure.inconsistent_document }
            let normalized = PDFInvoiceFinancialNormalization(source: verified)

            var conventions: PDFInvoiceConventionResolution?
            if normalized.candidates.contains(where: { $0.status == .ambiguous }) {
                let inferenceInput = Accounting.Inferences.InferInvoiceConventions.Input(normalization: normalized)
                let inferred = try await context.infer(Self.conventions, input: inferenceInput)
                conventions = try PDFInvoiceConventionResolution(
                    normalization: normalized, input: inferenceInput, proposal: inferred
                )
            }

            var resolvedBands: PDFInvoiceVATBandResolution?
            let fields = Set(normalized.candidates.map { $0.source.proposal.field })
            if fields.contains(.vat_base) && fields.contains(.vat_rate) && fields.contains(.vat_amount) {
                let inferenceInput = Accounting.Inferences.AssociateInvoiceVATBands.Input(normalization: normalized)
                let proposed = try await context.infer(Self.vatBands, input: inferenceInput)
                resolvedBands = try PDFInvoiceVATBandResolution(
                    normalization: normalized, input: inferenceInput, proposal: proposed
                )
            }
            let bands = resolvedBands?.proposedBands ?? []
            let complete = resolvedBands?.proposal.claimedCompleteBandSet ?? false
            let arithmetic = try PDFInvoiceArithmeticAssessment(
                normalization: normalized, proposedBands: bands,
                claimedCompleteBandSet: complete, roundingScale: input.roundingScale
            )
            let disambiguation = try PDFInvoiceArithmeticDisambiguation(
                normalization: normalized, proposedBands: bands,
                claimedCompleteBandSet: complete, roundingScale: input.roundingScale
            )
            var unresolved = proposal.unresolved
            if coverage.hasUnavailableText { unresolved.append("One or more pages had no usable text") }
            if !coverage.allSelectedLinesCollected { unresolved.append("Page text enumeration incomplete") }
            if disambiguation.status == .bounded { unresolved.append("Numeric alternative search exceeded bound") }
            if !normalized.conflictingFields.isEmpty { unresolved.append("Conflicting invoice field candidates") }
            return Output(coverage: coverage, extraction: proposal, verification: verified,
                          normalization: normalized, conventionResolution: conventions,
                          vatBandResolution: resolvedBands, arithmetic: arithmetic,
                          disambiguation: disambiguation, unresolved: unresolved)
        }
    }
}
