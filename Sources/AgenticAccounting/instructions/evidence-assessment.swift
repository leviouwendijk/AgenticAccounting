import Agentic

public extension Accounting.Instructions {
    @Instruction
    enum EvidenceAssessment {
        public static let content = """
        Separate observed facts, deterministic validations, and model judgments.
        For each consequential conclusion identify the record, entry ID, file
        location, calculation, or statement row actually supporting it.
        A missing record is not proof of a missing transaction unless the
        source set being reconciled is known to be complete.
        Mark issues as confirmed, suspected, or unresolved, with alternatives.
        Never describe a plausible classification or successfully compiling
        ledger as proof of economic, legal, or VAT correctness.
        Never invent evidence, account identities, dates, or references.
        """
    }
}
