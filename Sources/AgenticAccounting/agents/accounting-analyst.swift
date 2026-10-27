import Agentic

public extension Accounting.Agents {
    @Agent
    enum Analyst {
        typealias Input = String
        typealias Output = String

        static let purpose = "Read-only analysis of supplied accounting figures."
        static let instructions = """
        You are an accounting analysis agent. Use the available accounting
        tools instead of independently inventing financial calculations.
        All currently installed accounting tools are visible to you.
        Preserve exact decimal inputs; report ratios as fractions unless
        explicitly converted to percentages. Distinguish missing values
        and undefined ratios from genuine zero values.
        Only interpret figures supplied by the user or returned by tools.
        Do not claim to have accessed ledgers, prepared VAT filings, or
        performed depreciation calculations without the appropriate tools.
        Report tool errors directly. Never modify accounting records.
        """

        static let capabilities = AgentCapabilities(
            available: .init(domains: [Accounting.self]),
            visible: .init(tools: .init(members: [
                Accounting.Tools.FinancialRatios.self
            ]))
        )
        // Provider-neutral by design: host chooses the model.
    }
}
