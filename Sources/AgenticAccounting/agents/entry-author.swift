import Agentic
import AgenticIO
import AgenticMath
import AgenticStandard
import Schema

public extension Accounting.Agents {
    @Agent
    enum EntryAuthor {
        public typealias Input = String
        public typealias Output = String

        public static let purpose = """
        Author accounting .ec entries from raw supplied records using
        project context, domain interpretation and governed file mutations.
        """

        public static let instructions: Instructions = [
            .instruction(Accounting.Instructions.SourceInterpretation.definition),
            .instruction(Accounting.Instructions.EvidenceAssessment.definition),
            .instruction(Accounting.Instructions.EntryAuthoring.definition)
        ]

        public static let capabilities = AgentCapabilities(
            available: .init(
                domains: [
                    Accounting.self,
                    SystemIO.self,
                    Math.self,
                    Standard.self
                ]
            ),
            visible: .init(
                tools: .init(
                    members: [
                        Accounting.Tools.NextEntryIDs.self,
                        Accounting.Tools.UsedEntryIDs.self,
                        Accounting.Tools.InspectPlaceholders.self,
                        Accounting.Tools.CompileEntries.self,
                        Accounting.Tools.ValidateEntryDraft.self,
                        Accounting.Tools.EntryContext.self,
                        Accounting.Tools.FindReferences.self,
                        Accounting.Tools.SearchEntries.self,
                        Accounting.Tools.ReadEntries.self,
                        Accounting.Tools.SearchTransactions.self,
                        Accounting.Tools.ReadTransactions.self,
                        Accounting.Tools.SearchEntities.self,
                        Accounting.Tools.ReadEntities.self,
                        Accounting.Tools.SearchAccounts.self,
                        Accounting.Tools.ReadAccounts.self,
                        Accounting.Tools.ResolveReferences.self,
                        SystemIO.Tools.SearchSources.self,
                        SystemIO.Tools.SearchFilepaths.self,
                        SystemIO.Tools.ReadFile.self,
                        SystemIO.Tools.MutateFiles.self,
                        Math.Tools.Calculate.self,
                        Math.Tools.AllocateNumbers.self,
                        Math.Tools.AggregateNumbers.self,
                        Standard.Tools.ClarifyWithUser.self
                    ]
                ),
                inferences: .init(
                    members: [
                        Accounting.Inferences.InterpretSourceRecord.self
                    ]
                )
            )
        )
    }
}
