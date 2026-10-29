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
            public let rationale: String
            public let unresolved: [String]

            public init(
                proposedAccount: String?,
                proposedEntity: String?,
                vatBasis: String?,
                rationale: String,
                unresolved: [String]
            ) {
                self.proposedAccount = proposedAccount
                self.proposedEntity = proposedEntity
                self.vatBasis = vatBasis
                self.rationale = rationale
                self.unresolved = unresolved
            }
        }

        public static let purpose = """
        Interpret one supplied financial source record against supplied
        accounting project evidence. Propose references only where supported.
        State uncertainty explicitly. Does not mutate project records.
        """
    }
}
