import Agentic
import AgenticIO
import AgenticMath
import Schema

public extension Accounting.Agents {
    @Agent
    enum LedgerReviewer {
        public typealias Input = String
        public typealias Output = String

        public static let purpose = """
        Independent read-only review of an accounting project for evidence-backed
        discrepancies, suspicious bookings, unresolved records, and follow-ups.
        """

        public static let instructions: Instructions = [
            .instruction(Accounting.Instructions.LedgerReview.definition),
            .instruction(Accounting.Instructions.EvidenceAssessment.definition),
            .instruction(Accounting.Instructions.SourceInterpretation.definition)
        ]

        // Identical explicit allowlists for available and visible: no whole-domain
        // capability grant that could later expose a mutating IO tool.
        private static let reviewScope = AgentCapabilityScope(
            tools: .init(members: [
                Accounting.Tools.CompileEntries.self,
                Accounting.Tools.InspectPlaceholders.self,
                Accounting.Tools.UsedEntryIDs.self,
                SystemIO.Tools.SearchSources.self,
                SystemIO.Tools.SearchFilepaths.self,
                SystemIO.Tools.ReadFile.self,
                Math.Tools.Calculate.self,
                Math.Tools.CompareNumbers.self,
                Math.Tools.AggregateNumbers.self
            ]),
            inferences: .init(members: [
                Accounting.Inferences.InterpretSourceRecord.self
            ])
        )

        public static let capabilities = AgentCapabilities(
            available: reviewScope,
            visible: reviewScope
        )
    }
}
