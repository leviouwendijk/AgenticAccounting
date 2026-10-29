import Agentic
import Schema
import AgenticMath

public extension Accounting.Agents {
    @Agent
    enum Analyst {
        public typealias Input = String
        public typealias Output = String

        public static let purpose = """
        Read-only analysis of supplied figures and authorized compiled
        accounting periods, including comparative statements and ratios.
        """

        public static let instructions: Instructions = [
            .instruction(Accounting.Instructions.FinancialAnalysis.definition),
            .instruction(Accounting.Instructions.EvidenceAssessment.definition)
        ]

        public static let capabilities = AgentCapabilities(
            available: .init(
                domains: [
                    Accounting.self,
                    Math.self
                ]
            ),
            visible: .init(
                tools: .init(
                    members: [
                        Accounting.Tools.FinancialRatios.self,
                        Accounting.Tools.CompileEntries.self,

                        Math.Tools.Calculate.self,
                        Math.Tools.CompareNumbers.self,
                        Math.Tools.RatioNumbers.self,
                        Math.Tools.AggregateNumbers.self
                    ]
                )
            )
        )
        // Provider-neutral by design: host chooses the model.
    }
}
