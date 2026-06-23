import Foundation
import PKShared
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
        let messageStore: any MessageStoreProtocol = stores.messages
        let timelineId = UUID()

        let first = ConversationMessage(
            timelineId: timelineId,
            role: .user,
            content: "Hello",
            timestamp: Date(timeIntervalSince1970: 1000)
        )
        let second = ConversationMessage(
            timelineId: timelineId,
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
        let messageStore: any MessageStoreProtocol = stores.messages
        let timelineId = UUID()

        let old = ConversationMessage(
            timelineId: timelineId,
            role: .user,
            content: "Old",
            timestamp: Date().addingTimeInterval(-1_000_000)
        )
        let recent = ConversationMessage(
            timelineId: timelineId,
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
        let messageStore: any MessageStoreProtocol = stores.messages
        let timelineId = UUID()

        let snapshot = TurnSnapshot(
            timelineId: timelineId,
            modelName: "gpt-test",
            turnCount: 1,
            maxTurns: 5
        )
        let snapshotData = try JSONEncoder().encode(snapshot)

        let message = ConversationMessage(
            timelineId: timelineId,
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
        let timelineStore: any TimelinePersistenceProtocol = stores.timelines

        let workspaceId = UUID()
        var timeline = Timeline(
            title: "Test Timeline",
            attachedWorkspaceIds: [workspaceId]
        )

        try await timelineStore.saveTimeline(timeline)

        let fetched = try await timelineStore.fetchTimeline(id: timeline.id)
        #expect(fetched?.title == "Test Timeline")
        #expect(fetched?.attachedWorkspaceIds == [workspaceId])

        timeline.isArchived = true
        try await timelineStore.saveTimeline(timeline)

        let allExcludingArchived = try await timelineStore.fetchAllTimelines(includeArchived: false)
        #expect(allExcludingArchived.isEmpty)

        let allIncludingArchived = try await timelineStore.fetchAllTimelines(includeArchived: true)
        #expect(allIncludingArchived.map(\.id) == [timeline.id])

        try await timelineStore.deleteTimeline(id: timeline.id)
        let afterDelete = try await timelineStore.fetchTimeline(id: timeline.id)
        #expect(afterDelete == nil)
    }

    @Test("Prunes old timelines excluding specified ids")
    func timelinePruning() async throws {
        let stores = try makeStores()
        let timelineStore: any TimelinePersistenceProtocol = stores.timelines

        let oldTimeline = Timeline(
            title: "Old",
            createdAt: Date().addingTimeInterval(-1_000_000),
            updatedAt: Date().addingTimeInterval(-1_000_000)
        )
        let excludedOldTimeline = Timeline(
            title: "ExcludedOld",
            createdAt: Date().addingTimeInterval(-1_000_000),
            updatedAt: Date().addingTimeInterval(-1_000_000)
        )
        try await timelineStore.saveTimeline(oldTimeline)
        try await timelineStore.saveTimeline(excludedOldTimeline)

        let prunedCount = try await timelineStore.pruneTimelines(
            olderThan: 500_000,
            excluding: [excludedOldTimeline.id],
            dryRun: false
        )
        #expect(prunedCount == 1)

        let remaining = try await timelineStore.fetchAllTimelines(includeArchived: true)
        #expect(remaining.map(\.id) == [excludedOldTimeline.id])
    }

    // MARK: - Workspaces

    @Test("Round-trips workspaces with tools")
    func workspacesRoundTrip() async throws {
        let stores = try makeStores()
        let workspaceStore: any WorkspacePersistenceProtocol = stores.workspaces

        let workspace = WorkspaceReference(
            uri: WorkspaceURI(host: "pk-runtime", path: "/timelines/abc"),
            location: .runtime,
            tools: [.known(id: "shell")],
            rootPath: "/tmp/workspace"
        )

        try await workspaceStore.saveWorkspace(workspace)

        let fetchedWithTools = try await workspaceStore.fetchWorkspace(id: workspace.id, includeTools: true)
        #expect(fetchedWithTools?.rootPath == "/tmp/workspace")
        #expect(fetchedWithTools?.tools.map(\.toolId) == ["shell"])

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
        #expect(Set(fetched.map(\.toolId)) == Set(["shell", "custom-tool"]))

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
        #expect(afterSync.map(\.toolId) == ["shell"])
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
        let agentStore: any AgentInstanceStoreProtocol = stores.agents
        let timelineStore: any TimelinePersistenceProtocol = stores.timelines

        let privateTimelineId = UUID()
        let instance = AgentInstance(
            name: "Agent Smith",
            description: "A test agent",
            privateTimelineId: privateTimelineId
        )

        try await agentStore.saveAgentInstance(instance)

        let fetched = try await agentStore.fetchAgentInstance(id: instance.id)
        #expect(fetched?.name == "Agent Smith")

        let all = try await agentStore.fetchAllAgentInstances()
        #expect(all.map(\.id) == [instance.id])

        let attachedTimeline = Timeline(title: "Attached", attachedAgentInstanceId: instance.id)
        try await timelineStore.saveTimeline(attachedTimeline)

        let timelines = try await agentStore.fetchTimelines(attachedToAgent: instance.id)
        #expect(timelines.map(\.id) == [attachedTimeline.id])

        try await agentStore.deleteAgentInstance(id: instance.id)
        let afterDelete = try await agentStore.fetchAgentInstance(id: instance.id)
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
