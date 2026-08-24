import Foundation
import PKContracts
import PositronicKit
import SwiftData
import Testing
@testable import YakamozCore

@Suite("PersistenceAdapters")
struct PersistenceAdapterTests {
    private func makeStores() throws -> YakamozStores {
        let schema = Schema([
            ConversationModel.self,
            MessageModel.self,
            TurnInspectionModel.self,
            PersonaModel.self,
            WorkspaceModel.self,
            TimelineModel.self,
            WorkspaceReferenceModel.self,
            ToolReferenceModel.self,
            AgentInstanceModel.self,
            AgentTemplateModel.self,
            RequestOriginModel.self,
        ])
        let container = try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
        return YakamozStores(modelContainer: container)
    }

    // MARK: - Messages

    @Test("Round-trips messages ordered by timestamp")
    func messagesRoundTrip() async throws {
        let stores = try makeStores()
        let messageStore: any ThreadMessageStoreProtocol = stores.messages
        let timelineId = UUID()

        let first = ThreadMessage(
            threadID: timelineId,
            role: .user,
            content: "Hello",
            timestamp: Date(timeIntervalSince1970: 1000)
        )
        let second = ThreadMessage(
            threadID: timelineId,
            role: .assistant,
            content: "Hi there",
            timestamp: Date(timeIntervalSince1970: 2000)
        )

        try await messageStore.saveMessage(second)
        try await messageStore.saveMessage(first)

        let fetched = try await messageStore.fetchMessages(for: timelineId)
        #expect(fetched.map(\.content) == ["Hello", "Hi there"])

        try await messageStore.deleteMessages(for: timelineId)
        let afterDelete = try await messageStore.fetchMessages(for: timelineId)
        #expect(afterDelete.isEmpty)
    }

    @Test("Prunes old messages excluding recent ones, supports dry run")
    func messagePruning() async throws {
        let stores = try makeStores()
        let messageStore: any ThreadMessageStoreProtocol = stores.messages
        let timelineId = UUID()

        let old = ThreadMessage(
            threadID: timelineId,
            role: .user,
            content: "Old",
            timestamp: Date().addingTimeInterval(-1_000_000)
        )
        let recent = ThreadMessage(
            threadID: timelineId,
            role: .user,
            content: "Recent",
            timestamp: Date()
        )
        try await messageStore.saveMessage(old)
        try await messageStore.saveMessage(recent)

        let dryRunCount = try await messageStore.pruneMessages(olderThan: 500_000, dryRun: true)
        #expect(dryRunCount == 1)
        let stillThere = try await messageStore.fetchMessages(for: timelineId)
        #expect(stillThere.count == 2)

        let prunedCount = try await messageStore.pruneMessages(olderThan: 500_000, dryRun: false)
        #expect(prunedCount == 1)
        let remaining = try await messageStore.fetchMessages(for: timelineId)
        #expect(remaining.map(\.content) == ["Recent"])
    }

    @Test("Fetches turn snapshots for a timeline")
    func messageSnapshots() async throws {
        let stores = try makeStores()
        let messageStore: any ThreadMessageStoreProtocol = stores.messages
        let timelineId = UUID()

        let snapshot = TurnSnapshot(
            threadID: timelineId,
            modelName: "gpt-test",
            modelRoundIndex: 0,
            maxModelRounds: 5
        )
        let snapshotData = try JSONEncoder().encode(snapshot)

        let message = ThreadMessage(
            threadID: timelineId,
            role: .assistant,
            content: "Response",
            snapshotData: snapshotData
        )
        try await messageStore.saveMessage(message)

        let snapshots = try await messageStore.fetchSnapshots(for: timelineId)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.modelName == "gpt-test")
    }

    // MARK: - Timelines

    @Test("Round-trips timelines including workspace attachment ids")
    func timelinesRoundTrip() async throws {
        let stores = try makeStores()
        let timelineStore: any ThreadPersistenceProtocol = stores.timelines

        let workspaceId = UUID()
        var timeline = Thread(
            title: "Test Timeline",
            attachedWorkspaceIDs: [workspaceId]
        )

        try await timelineStore.saveThread(timeline)

        let fetched = try await timelineStore.fetchThread(id: timeline.id)
        #expect(fetched?.title == "Test Timeline")
        #expect(fetched?.attachedWorkspaceIDs == [workspaceId])

        timeline.isArchived = true
        try await timelineStore.saveThread(timeline)

        let allExcludingArchived = try await timelineStore.fetchAllThreads(includeArchived: false)
        #expect(allExcludingArchived.isEmpty)

        let allIncludingArchived = try await timelineStore.fetchAllThreads(includeArchived: true)
        #expect(allIncludingArchived.map(\.id) == [timeline.id])

        try await timelineStore.deleteThread(id: timeline.id)
        let afterDelete = try await timelineStore.fetchThread(id: timeline.id)
        #expect(afterDelete == nil)
    }

    @Test("Prunes old timelines excluding specified ids")
    func timelinePruning() async throws {
        let stores = try makeStores()
        let timelineStore: any ThreadPersistenceProtocol = stores.timelines

        let oldTimeline = Thread(
            title: "Old",
            createdAt: Date().addingTimeInterval(-1_000_000),
            updatedAt: Date().addingTimeInterval(-1_000_000)
        )
        let excludedOldTimeline = Thread(
            title: "ExcludedOld",
            createdAt: Date().addingTimeInterval(-1_000_000),
            updatedAt: Date().addingTimeInterval(-1_000_000)
        )
        try await timelineStore.saveThread(oldTimeline)
        try await timelineStore.saveThread(excludedOldTimeline)

        let prunedCount = try await timelineStore.pruneThreads(
            olderThan: 500_000,
            excluding: [excludedOldTimeline.id],
            dryRun: false
        )
        #expect(prunedCount == 1)

        let remaining = try await timelineStore.fetchAllThreads(includeArchived: true)
        #expect(remaining.map(\.id) == [excludedOldTimeline.id])
    }

    // MARK: - Workspaces

    @Test("Round-trips workspaces with tools")
    func workspacesRoundTrip() async throws {
        let stores = try makeStores()
        let workspaceStore: any WorkspaceStore = stores.workspaces

        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "pk-runtime", path: "/timelines/abc"),
            location: .runtime,
            tools: [.known(id: "shell")],
            rootPath: "/tmp/workspace"
        )

        try await workspaceStore.saveWorkspace(workspace)

        let fetchedWithTools = try await workspaceStore.fetchWorkspace(id: workspace.id, includeTools: true)
        #expect(fetchedWithTools?.rootPath == "/tmp/workspace")
        #expect(fetchedWithTools?.tools.map(\.toolID) == ["shell"])

        let fetchedWithoutTools = try await workspaceStore.fetchWorkspace(id: workspace.id, includeTools: false)
        #expect(fetchedWithoutTools?.tools.isEmpty == true)

        let all = try await workspaceStore.fetchAllWorkspaces()
        #expect(all.map(\.id) == [workspace.id])

        try await workspaceStore.deleteWorkspace(id: workspace.id)
        let afterDelete = try await workspaceStore.fetchWorkspace(id: workspace.id, includeTools: true)
        #expect(afterDelete == nil)
    }

    // MARK: - Tools

    @Test("Adds, syncs, and looks up known and custom tool references")
    func toolsRoundTrip() async throws {
        let stores = try makeStores()
        let toolStore: any ToolPersistenceProtocol = stores.tools

        let workspaceId = UUID()
        try await toolStore.addToolToWorkspace(workspaceId: workspaceId, tool: .known(id: "shell"))

        let customDefinition = WorkspaceToolDefinition(
            id: "custom-tool",
            name: "Custom Tool",
            description: "A custom tool"
        )
        try await toolStore.addToolToWorkspace(workspaceId: workspaceId, tool: .custom(customDefinition))

        let fetched = try await toolStore.fetchTools(forWorkspaces: [workspaceId])
        #expect(Set(fetched.map(\.toolID)) == Set(["shell", "custom-tool"]))

        let foundWorkspaceId = try await toolStore.findWorkspaceId(forToolId: "shell", in: [workspaceId])
        #expect(foundWorkspaceId == workspaceId)

        let source = try await toolStore.fetchToolSource(
            toolId: "shell",
            workspaceIds: [workspaceId],
            primaryWorkspaceId: nil
        )
        #expect(source != nil)

        try await toolStore.syncTools(workspaceId: workspaceId, tools: [.known(id: "shell")])
        let afterSync = try await toolStore.fetchTools(forWorkspaces: [workspaceId])
        #expect(afterSync.map(\.toolID) == ["shell"])
    }

    @Test("Fetches origin-hosted tools")
    func originToolsRoundTrip() async throws {
        let stores = try makeStores()
        let toolStore: any ToolPersistenceProtocol = stores.tools
        let originId = UUID()
        let workspaceId = UUID()

        let originStore: any RequestOriginStoreProtocol = stores.origins
        let origin = RequestOriginIdentity(id: originId, hostname: "macbook", displayName: "MacBook", platform: "macos")
        try await originStore.saveOrigin(origin)

        try await toolStore.addToolToWorkspace(
            workspaceId: workspaceId,
            tool: .known(id: "remote-tool")
        )

        let originTools = try await toolStore.fetchOriginTools(originId: originId)
        #expect(originTools.isEmpty)
    }

    // MARK: - Agent Instances

    @Test("Round-trips agent instances and their attached timelines")
    func agentInstancesRoundTrip() async throws {
        let stores = try makeStores()
        let agentStore: any AgentStoreProtocol = stores.agents
        let timelineStore: any ThreadPersistenceProtocol = stores.timelines

        let privateTimelineId = UUID()
        let instance = Agent(
            name: "Agent Smith",
            description: "A test agent",
            lifecycle: .retiring,
            privateThreadID: privateTimelineId
        )

        try await agentStore.saveAgent(instance)

        let fetched = try await agentStore.fetchAgent(id: instance.id)
        #expect(fetched?.name == "Agent Smith")
        #expect(fetched?.lifecycle == .retiring)

        let all = try await agentStore.fetchAllAgents()
        #expect(all.map(\.id) == [instance.id])

        let attachedTimeline = Thread(title: "Attached", attachedAgentID: instance.id)
        try await timelineStore.saveThread(attachedTimeline)

        let timelines = try await agentStore.fetchThreads(attachedToAgent: instance.id)
        #expect(timelines.map(\.id) == [attachedTimeline.id])

        try await agentStore.deleteAgent(id: instance.id)
        let afterDelete = try await agentStore.fetchAgent(id: instance.id)
        #expect(afterDelete == nil)
    }

    // MARK: - Agent Templates

    @Test("Round-trips agent templates by id and key")
    func agentTemplatesRoundTrip() async throws {
        let stores = try makeStores()
        let templateStore: any AgentTemplateStoreProtocol = stores.templates

        let template = AgentTemplate(
            id: UUID(),
            name: "Coder",
            description: "Writes code",
            systemPrompt: "You write code."
        )

        try await templateStore.saveAgentTemplate(template)

        let fetchedById = try await templateStore.fetchAgentTemplate(id: template.id)
        #expect(fetchedById?.name == "Coder")

        let fetchedByKey = try await templateStore.fetchAgentTemplate(key: template.id.uuidString)
        #expect(fetchedByKey?.id == template.id)

        let all = try await templateStore.fetchAllAgentTemplates()
        #expect(all.map(\.id) == [template.id])

        let exists = await templateStore.hasAgentTemplate(id: template.id.uuidString)
        #expect(exists)

        let missing = await templateStore.hasAgentTemplate(id: UUID().uuidString)
        #expect(missing == false)
    }

    // MARK: - Request Origins

    @Test("Round-trips request origins")
    func requestOriginsRoundTrip() async throws {
        let stores = try makeStores()
        let originStore: any RequestOriginStoreProtocol = stores.origins

        let origin = RequestOriginIdentity(
            hostname: "macbook.local",
            displayName: "MacBook",
            platform: "macos"
        )

        try await originStore.saveOrigin(origin)

        let fetched = try await originStore.fetchOrigin(id: origin.id)
        #expect(fetched?.hostname == "macbook.local")

        let all = try await originStore.fetchAllOrigins()
        #expect(all.map(\.id) == [origin.id])

        let deleted = try await originStore.deleteOrigin(id: origin.id)
        #expect(deleted == true)

        let afterDelete = try await originStore.fetchOrigin(id: origin.id)
        #expect(afterDelete == nil)

        let deletedAgain = try await originStore.deleteOrigin(id: origin.id)
        #expect(deletedAgain == false)
    }
}
