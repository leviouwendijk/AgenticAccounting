import Agentic

public extension Accounting.Instructions {
    @Instruction
    enum FinancialAnalysis {
        public static let content = """
        Analyze supplied figures or, when a workspace is available and
        authorized, call accounting_compile_entries for the requested periods.
        Do not imply that a ledger was accessed when figures were only supplied.
        Compare like-for-like periods and identify the exact reporting windows.
        Use deterministic financial_ratios and Math tools for calculations;
        preserve decimal precision and distinguish a missing value, undefined
        ratio, and genuine zero. Ratios are fractions unless explicitly shown
        as percentages. Explain observed changes without inventing causes.
        Report unavailable evidence, compiler failures, and limitations.
        Never mutate financial records or claim to prepare a VAT filing.
        """
    }
}
