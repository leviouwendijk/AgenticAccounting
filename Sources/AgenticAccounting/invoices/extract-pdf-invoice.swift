import Agentic
import AgenticPDF
import Macros
import Schema

public extension Accounting.Inferences {
    /// Proposes invoice fields from PDF evidence; it does not verify or book them.
    @Inference
    struct ExtractPDFInvoice {
        @JSONSchema
        public struct Input: HashableSource {
            public let sourceFingerprint: String
            public let lines: [PDFLineEvidence]
            @Schema(required: false)
            public let context: String?

            public init(
                sourceFingerprint: String,
                lines: [PDFLineEvidence],
                context: String? = nil
            ) {
                self.sourceFingerprint = sourceFingerprint
                self.lines = lines
                self.context = context
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            @JSONSchema
            public enum Kind: String, Sendable, Codable, Hashable {
                case invoice
                case credit_note
                case other
                case undetermined
            }

            @JSONSchema
            public enum Field: String, Sendable, Codable, Hashable {
                case supplier_name
                case supplier_tax_id
                case supplier_iban
                case customer_name
                case customer_tax_id
                case invoice_number
                case invoice_date
                case due_date
                case currency
                case net_amount
                case vat_base
                case vat_rate
                case vat_amount
                case vat_total
                case gross_amount
                case payment_reference
            }

            @JSONSchema
            public struct Citation: HashableResult {
                public let lineID: String
                public let quote: String

                public init(lineID: String, quote: String) {
                    self.lineID = lineID
                    self.quote = quote
                }
            }

            @JSONSchema
            public struct Candidate: HashableResult {
                public let field: Field
                public let rawValue: String
                public let normalizedValue: String?
                public let citations: [Citation]
                public let explanation: String?

                public init(
                    field: Field,
                    rawValue: String,
                    normalizedValue: String? = nil,
                    citations: [Citation],
                    explanation: String? = nil
                ) {
                    self.field = field
                    self.rawValue = rawValue
                    self.normalizedValue = normalizedValue
                    self.citations = citations
                    self.explanation = explanation
                }
            }

            public let kind: Kind
            public let candidates: [Candidate]
            public let unresolved: [String]
            public let warnings: [String]

            public init(
                kind: Kind,
                candidates: [Candidate],
                unresolved: [String],
                warnings: [String]
            ) {
                self.kind = kind
                self.candidates = candidates
                self.unresolved = unresolved
                self.warnings = warnings
            }
        }

        public static let purpose = """
        Extract proposed invoice or credit-note fields from supplied PDF line
        observations. Every candidate must carry one or more citations naming
        exact input line IDs and verbatim substrings of those lines. Raw values
        must be copied from source evidence; put interpreted dates, money values,
        or identifiers only in normalizedValue. Do not invent citations, invoice
        fields, VAT rates, vendors, or missing pages. Multiple VAT rates and
        line items must not be silently collapsed into a single assertion.
        Treat OCR and native extraction as independent observations rather than
        additive transactions. The supplied lines can be a partial document:
        never assert completeness from this inference. Return unresolved cases,
        including ambiguous totals, missing invoices, or contradictory fields.
        This inference only proposes facts. Citations require deterministic
        resolution against authorized, source-bound PDF evidence; no claim is
        reconciled, booked, or tax-verified by this output.
        """
    }
}
