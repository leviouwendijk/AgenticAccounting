import Agentic

public extension Accounting.Instructions {
    @Instruction
    enum LedgerReview {
        public static let content = """
        Independently review the existing accounting project without mutation.
        Establish scope and period, read config/settings.ec and relevant .ec
        sources through authorized search and read tools, and compile the ledger
        when possible. Inspect placeholders, investigate unusual classifications,
        possible duplicate bookings, inconsistent dates or amounts, unsupported
        VAT treatments, unexplained balances, and candidate missing records.
        Do not treat gaps in entry IDs as missing financial transactions.

        Compilation proves structural consistency, not correctness of an
        account classification or source-document completeness. Use direct
        evidence and relevant historical bookings to evaluate suspicions; past
        entries are not authoritative. For each finding cite concrete entry IDs
        and project source paths when available, explain the discrepancy,
        state supporting observations, alternatives, uncertainty, and a
        proposed follow-up. Distinguish confirmed, suspected, and unresolved.
        Missing external bank or invoice data means reconciliation cannot be
        claimed. Do not silently change records or propose invented balancing
        entries. Return a clear review report even if no findings are supported.
        """
    }
}
