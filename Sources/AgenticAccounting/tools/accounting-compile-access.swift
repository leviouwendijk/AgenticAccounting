import Agentic
import AgenticIO
import Workspace

// The compiler's nested file reads remain governed by EntryCompilerProject(workspace:).
// These checks establish the expected project-level access before compilation.
enum AccountingCompileAccess {
    enum Failure: Error {
        case workspaceRequired
    }

    static func authorize(_ context: ToolContext, toolName: String) throws -> WorkspaceContext {
        guard let workspace = context.workspace else {
            throw Failure.workspaceRequired
        }
        for path in ["config", "entries", "transactions"] {
            _ = try FileToolAccess.authorize(
                workspace: workspace,
                rootID: workspace.rootIdentifier,
                path: path,
                capability: .scan,
                toolName: toolName,
                type: .directory
            )
        }
        _ = try FileToolAccess.authorize(
            workspace: workspace,
            rootID: workspace.rootIdentifier,
            path: "config/settings.ec",
            capability: .read,
            toolName: toolName,
            type: .file
        )
        return workspace
    }
}
