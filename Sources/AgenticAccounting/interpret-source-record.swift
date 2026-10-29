import Agentic
import Macros
import Schema

public extension Accounting.Inferences {
    @Inference
    struct InterpretSourceRecord {
        @JSONSchema
        public struct Input: HashableSource {
            public let rawRecord: String
            public let projectEvidence: String

            public init(rawRecord: String, projectEvidence: String) {
                self.rawRecord = rawRecord
                self.projectEvidence = projectEvidence
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let proposedAccount: String?
            public let proposedEntity: String?
            public let vatBasis: String?
            /// Other plausible existing account codes, not additional postings.
            public let alternativeAccounts: [String]
            /// Verifiable observations from supplied records or project evidence.
            public let supportingEvidence: [String]
            public let rationale: String
            public let unresolved: [String]

            public init(
                proposedAccount: String?,
                proposedEntity: String?,
                vatBasis: String?,
                rationale: String,
                unresolved: [String],
                alternativeAccounts: [String] = [],
                supportingEvidence: [String] = []
            ) {
                self.proposedAccount = proposedAccount
                self.proposedEntity = proposedEntity
                self.vatBasis = vatBasis
                self.alternativeAccounts = alternativeAccounts
                self.supportingEvidence = supportingEvidence
                self.rationale = rationale
                self.unresolved = unresolved
            }
        }

        public static let purpose = """
        Interpret one supplied financial source record against supplied
        accounting project evidence. Identify the economic event, distinguish
        payment from invoice and expense from asset, and propose only supported
        existing account and entity references. Give alternative account codes,
        concrete supporting evidence, VAT basis only when evidenced, and
        unresolved questions. Never invent project references or source facts.
        An interpretation is not a verified booking or tax determination.
        Does not mutate project records.
        """
    }
}
