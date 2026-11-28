import Foundation

enum AdvisorSection: String, CaseIterable, Identifiable, Sendable {
    case chat = "顾问对话"
    case memories = "记忆库"
    case inbox = "速记收件箱"
    case settings = "模型与设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .memories: return "book.closed"
        case .inbox: return "tray.and.arrow.down"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum ChatMode: String, CaseIterable, Identifiable, Sendable {
    case chat
    case decision
    case interview
    case reflect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "日常倾诉"
        case .decision: return "9步决策"
        case .interview: return "冷启动访谈"
        case .reflect: return "周期反思"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left"
        case .decision: return "safari"
        case .interview: return "mic"
        case .reflect: return "sparkles"
        }
    }

    var heroTitle: String {
        switch self {
        case .chat: return "今天想聊点什么？"
        case .decision: return "冷静拆解这个重要选择"
        case .interview: return "建立你的个人记忆档案"
        case .reflect: return "回望近期轨迹与情绪模式"
        }
    }

    var placeholder: String {
        switch self {
        case .chat: return "说说今天的经历、情绪或正在思考的事…"
        case .decision: return "描述你正在权衡的决定与顾虑…"
        case .interview: return "聊聊你的背景、价值取向或最早的重要经历…"
        case .reflect: return "指定想回顾的时间段、人物或情绪主题…"
        }
    }

    var shortSubtitle: String {
        switch self {
        case .chat: return "自由倾诉当下情绪，温和陪伴"
        case .decision: return "9 步反讨好拆解，强制给出反方"
        case .interview: return "温和追问，逐步建立核心档案"
        case .reflect: return "回看近期速记，梳理情绪模式"
        }
    }
}

enum MemoryViewMode: String, CaseIterable, Identifiable, Sendable {
    case list = "列表"
    case semantic = "语义"
    case timeline = "时间轴"
    case graph = "图谱"

    var id: String { rawValue }
}

// MARK: - API Response Models

struct HealthResponse: Codable, Sendable {
    let ok: Bool
    let version: String?
    let deploymentMode: String?
    let capabilities: [String]?
    let stats: VaultStats
    let index: IndexStats?
    let activeProviderId: String?

    enum CodingKeys: String, CodingKey {
        case ok, version, capabilities, stats, index
        case deploymentMode = "deployment_mode"
        case activeProviderId = "active_provider_id"
    }
}

struct AuthVerifyResponse: Codable, Sendable {
    let ok: Bool
    let deploymentMode: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case ok, version
        case deploymentMode = "deployment_mode"
    }
}

struct VaultStats: Codable, Sendable {
    let total: Int
    let byCategory: [String: Int]
    let highImportanceEvents: Int
    let sensitiveProtected: Int
    let vaultPath: String

    enum CodingKeys: String, CodingKey {
        case total
        case byCategory = "by_category"
        case highImportanceEvents = "high_importance_events"
        case sensitiveProtected = "sensitive_protected"
        case vaultPath = "vault_path"
    }
}

struct IndexStats: Codable, Sendable {
    let totalDocs: Int
    let embeddedDocs: Int
    let embeddingModel: String
    let lastSync: String
    let graphEdges: Int

    enum CodingKeys: String, CodingKey {
        case totalDocs = "total_docs"
        case embeddedDocs = "embedded_docs"
        case embeddingModel = "embedding_model"
        case lastSync = "last_sync"
        case graphEdges = "graph_edges"
    }
}

struct SessionSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let mode: String
    let providerId: String
    let createdAt: String
    let updatedAt: String
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, mode
        case providerId = "provider_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
    }
}

struct SessionsListResponse: Codable, Sendable {
    let items: [SessionSummary]
}

struct MemoryReference: Codable, Identifiable, Hashable, Sendable {
    var id: String { path + source }
    let path: String
    let title: String
    let category: String?
    let importance: Int?
    let source: String
    let reasons: [String]?
}

struct ChatMessageItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var role: String
    var content: String
    var reasoning: String
    var model: String
    var providerName: String
    var references: [MemoryReference]
    var isStreaming: Bool = false

    init(
        id: String = UUID().uuidString,
        role: String,
        content: String,
        reasoning: String = "",
        model: String = "",
        providerName: String = "",
        references: [MemoryReference] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.model = model
        self.providerName = providerName
        self.references = references
        self.isStreaming = isStreaming
    }
}

struct SessionMessageDTO: Codable, Sendable {
    let id: Int?
    let role: String
    let content: String
    let reasoning: String?
    let model: String?
    let providerName: String?
    let references: [MemoryReference]?

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoning, model, references
        case providerName = "provider_name"
    }
}

struct SessionDetailResponse: Codable, Sendable {
    let id: String
    let title: String
    let mode: String
    let providerId: String
    let messages: [SessionMessageDTO]

    enum CodingKeys: String, CodingKey {
        case id, title, mode, messages
        case providerId = "provider_id"
    }
}

// MARK: - Memories / Timeline / Graph

struct CategoryInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

struct MemorySummary: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let title: String
    let category: String
    let categoryLabel: String
    let privacy: String
    let importance: Int
    let eventTime: String
    let recordedAt: String
    let emotions: [String]
    let people: [String]
    let wikilinks: [String]
    let snippet: String
    let score: Double?
    let semantic: Double?
    let reasons: [String]?

    enum CodingKeys: String, CodingKey {
        case path, title, category, privacy, importance, emotions, people, wikilinks, snippet, score, semantic, reasons
        case categoryLabel = "category_label"
        case eventTime = "event_time"
        case recordedAt = "recorded_at"
    }
}

struct MemoriesListResponse: Codable, Sendable {
    let categories: [CategoryInfo]?
    let emotions: [String]?
    let items: [MemorySummary]
    let total: Int
}

struct EmotionDetail: Codable, Identifiable, Hashable, Sendable {
    var id: String { (name ?? "") + (trigger ?? "") }
    let name: String?
    let intensity: Int?
    let valence: String?
    let trigger: String?
    let body: String?
    let thought: String?
}

struct MemoryDetail: Codable, Sendable {
    let path: String
    let title: String
    let category: String
    let categoryLabel: String
    let privacy: String
    let importance: Int
    let eventTime: String
    let recordedAt: String
    let body: String
    let raw: String
    let emotionsDetail: [EmotionDetail]?

    enum CodingKeys: String, CodingKey {
        case path, title, category, privacy, importance, body, raw
        case categoryLabel = "category_label"
        case eventTime = "event_time"
        case recordedAt = "recorded_at"
        case emotionsDetail = "emotions_detail"
    }
}

struct TimelineItem: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let title: String
    let category: String
    let categoryLabel: String
    let eventTime: String
    let recordedAt: String
    let importance: Int
    let privacy: String
    let emotions: [String]
    let people: [String]
    let snippet: String
    let supersededBy: String?

    enum CodingKeys: String, CodingKey {
        case path, title, category, importance, privacy, emotions, people, snippet
        case categoryLabel = "category_label"
        case eventTime = "event_time"
        case recordedAt = "recorded_at"
        case supersededBy = "superseded_by"
    }
}

struct TimelineResponse: Codable, Sendable {
    let items: [TimelineItem]
    let total: Int
}

struct GraphNode: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let category: String
    let categoryLabel: String
    let importance: Int
    let emotions: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, category, importance, emotions
        case categoryLabel = "category_label"
    }
}

struct GraphEdge: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(source)->\(target):\(relationType)" }
    let source: String
    let target: String
    let label: String
    let relationType: String
    let weight: Double

    enum CodingKeys: String, CodingKey {
        case source, target, label, weight
        case relationType = "relation_type"
    }
}

struct GraphResponse: Codable, Sendable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
}

// MARK: - Semi-Auto Proposals

struct MemoryProposal: Codable, Identifiable, Sendable {
    let id: String
    let action: String
    let path: String
    let exists: Bool
    let level: Int
    let title: String
    let summary: String
    let importance: Int
    let emotions: [String]
    let relations: [String]
    var privacy: String
    let evidence: String
    var content: String
    let diff: String
    var selected: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, action, path, exists, level, title, summary, importance, emotions, relations, privacy, evidence, content, diff
    }
}

struct ExtractProposalsResponse: Codable, Sendable {
    let proposals: [MemoryProposal]
    let providerName: String?

    enum CodingKeys: String, CodingKey {
        case proposals
        case providerName = "provider_name"
    }
}

struct CommitProposalsResponse: Codable, Sendable {
    let ok: Bool
    let written: [String]
}

// MARK: - Config & Git

struct ProviderPresetDTO: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: String
    var baseUrl: String
    var apiKey: String
    var apiKeyMasked: String?
    var hasApiKey: Bool?
    var model: String
    var temperature: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, model, temperature
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case apiKeyMasked = "api_key_masked"
        case hasApiKey = "has_api_key"
    }
}

extension ProviderPresetDTO {
    /// 是否已完成密钥配置或 OAuth 订阅授权
    var isConfigured: Bool {
        hasApiKey == true
    }

    var displayModelName: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    var kindIcon: String {
        switch kind {
        case "chatgpt_oauth": return "person.badge.key"
        case "deepseek": return "cpu"
        case "openai_compatible": return "network"
        case "claude": return "sparkle"
        case "gemini": return "diamond"
        default: return "cube"
        }
    }
}

struct EmbeddingConfigDTO: Codable, Sendable {
    var mode: String
    var localModel: String
    var apiBaseUrl: String
    var apiKey: String
    var apiKeyMasked: String?
    var hasApiKey: Bool?
    var apiModel: String

    enum CodingKeys: String, CodingKey {
        case mode
        case localModel = "local_model"
        case apiBaseUrl = "api_base_url"
        case apiKey = "api_key"
        case apiKeyMasked = "api_key_masked"
        case hasApiKey = "has_api_key"
        case apiModel = "api_model"
    }
}

struct NetworkInfoDTO: Codable, Sendable {
    let localUrl: String?
    let lanUrl: String?
    let tailscaleUrl: String?

    enum CodingKeys: String, CodingKey {
        case localUrl = "local_url"
        case lanUrl = "lan_url"
        case tailscaleUrl = "tailscale_url"
    }
}

struct ChatGPTModelOption: Codable, Identifiable, Hashable, Sendable {
    var id: String { slug }
    let slug: String
    let displayName: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case slug, description
        case displayName = "display_name"
    }
}

struct ChatGPTOAuthFlowDTO: Codable, Sendable {
    let state: String
    let status: String
    let error: String
}

struct ChatGPTOAuthStatusDTO: Codable, Sendable {
    let connected: Bool
    let accountEmail: String
    let accountName: String
    let planType: String
    let hasPlanUsageScope: Bool
    let hasIssuedClientId: Bool
    let clientIdMasked: String
    let expiresAt: Int
    let isExpired: Bool
    let canRefresh: Bool
    let availableModels: [ChatGPTModelOption]
    let redirectUri: String
    let updatedAt: String
    let flow: ChatGPTOAuthFlowDTO?

    enum CodingKeys: String, CodingKey {
        case connected, flow
        case accountEmail = "account_email"
        case accountName = "account_name"
        case planType = "plan_type"
        case hasPlanUsageScope = "has_plan_usage_scope"
        case hasIssuedClientId = "has_issued_client_id"
        case clientIdMasked = "client_id_masked"
        case expiresAt = "expires_at"
        case isExpired = "is_expired"
        case canRefresh = "can_refresh"
        case availableModels = "available_models"
        case redirectUri = "redirect_uri"
        case updatedAt = "updated_at"
    }
}

struct ChatGPTOAuthStartResponse: Codable, Sendable {
    let authUrl: String
    let state: String
    let redirectUri: String
    let isFirstRegistration: Bool
    let clientIdUsed: String

    enum CodingKeys: String, CodingKey {
        case state
        case authUrl = "auth_url"
        case redirectUri = "redirect_uri"
        case isFirstRegistration = "is_first_registration"
        case clientIdUsed = "client_id_used"
    }
}

struct ChatGPTOAuthCompleteResponse: Codable, Sendable {
    let ok: Bool
    let oauth: ChatGPTOAuthStatusDTO
    let config: PublicConfigDTO
}

struct ChatGPTOAuthRefreshModelsResponse: Codable, Sendable {
    let ok: Bool
    let models: [ChatGPTModelOption]
    let oauth: ChatGPTOAuthStatusDTO
    let config: PublicConfigDTO
}

struct ChatGPTOAuthLogoutResponse: Codable, Sendable {
    let ok: Bool
    let oauth: ChatGPTOAuthStatusDTO
    let config: PublicConfigDTO
}

struct PublicConfigDTO: Codable, Sendable {
    var deploymentMode: String?
    var vaultPath: String
    var publicBaseUrl: String
    var mcpEndpointUrl: String
    var hasAccessToken: Bool
    var activeProviderId: String
    var providers: [ProviderPresetDTO]
    var embedding: EmbeddingConfigDTO
    var network: NetworkInfoDTO?
    var chatgptOauth: ChatGPTOAuthStatusDTO?

    enum CodingKeys: String, CodingKey {
        case providers, embedding, network
        case deploymentMode = "deployment_mode"
        case vaultPath = "vault_path"
        case publicBaseUrl = "public_base_url"
        case mcpEndpointUrl = "mcp_endpoint_url"
        case hasAccessToken = "has_access_token"
        case activeProviderId = "active_provider_id"
        case chatgptOauth = "chatgpt_oauth"
    }
}

struct GitSnapshotItem: Codable, Identifiable, Hashable, Sendable {
    var id: String { hash + date }
    let hash: String
    let date: String
    let message: String
}

struct GitHistoryResponse: Codable, Sendable {
    let items: [GitSnapshotItem]
}

struct RebuildIndexResponse: Codable, Sendable {
    let ok: Bool
    let totalDocs: Int
    let embeddedDocs: Int
    let graphEdges: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case totalDocs = "total_docs"
        case embeddedDocs = "embedded_docs"
        case graphEdges = "graph_edges"
    }
}

struct TestProviderResponse: Codable, Sendable {
    let ok: Bool
    let provider: String
    let model: String
    let reply: String
}

enum StreamEvent: Sendable {
    case meta(sessionId: String, providerName: String, model: String, references: [MemoryReference])
    case reasoning(String)
    case text(String)
    case error(String)
    case done(String)
}

// MARK: - Onboarding & Cross-Agent Memory Import

struct OnboardingSlotDTO: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let title: String
    let description: String
    let interviewPrompt: String
    let exists: Bool
    let status: String // "empty" | "partial" | "ready"
    let charCount: Int
    let excerpt: String

    enum CodingKeys: String, CodingKey {
        case id, path, title, description, exists, status, excerpt
        case interviewPrompt = "interview_prompt"
        case charCount = "char_count"
    }
}

struct AdvisorStyleOptionDTO: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let description: String
}

struct OnboardingStatusDTO: Codable, Sendable {
    let needsOnboarding: Bool
    let completed: Bool
    let dismissed: Bool
    let onboardingState: String
    let completeness: Int
    let readyCount: Int
    let partialCount: Int
    let emptyCount: Int
    let totalSlots: Int
    let nonCoreMemories: Int
    let hasProtocol: Bool
    let missingSlots: [String]
    let partialSlots: [String]
    let nextSlotId: String
    let slots: [OnboardingSlotDTO]
    let advisorStyles: [AdvisorStyleOptionDTO]?

    enum CodingKeys: String, CodingKey {
        case completed, dismissed, completeness, slots
        case needsOnboarding = "needs_onboarding"
        case onboardingState = "onboarding_state"
        case readyCount = "ready_count"
        case partialCount = "partial_count"
        case emptyCount = "empty_count"
        case totalSlots = "total_slots"
        case nonCoreMemories = "non_core_memories"
        case hasProtocol = "has_protocol"
        case missingSlots = "missing_slots"
        case partialSlots = "partial_slots"
        case nextSlotId = "next_slot_id"
        case advisorStyles = "advisor_styles"
    }
}

struct OnboardingStateResponse: Codable, Sendable {
    let ok: Bool
    let status: OnboardingStatusDTO
}

struct QuickProfilePayload: Encodable, Sendable {
    let preferredName: String
    let lifeStage: String
    let currentFocus: String
    let coreValues: [String]
    let valuesNote: String
    let boundaries: String
    let patterns: String
    let goals: String
    let advisorStyle: String
    let advisorStyleNote: String
    var commit: Bool

    enum CodingKeys: String, CodingKey {
        case boundaries, patterns, goals, commit
        case preferredName = "preferred_name"
        case lifeStage = "life_stage"
        case currentFocus = "current_focus"
        case coreValues = "core_values"
        case valuesNote = "values_note"
        case advisorStyle = "advisor_style"
        case advisorStyleNote = "advisor_style_note"
    }
}

struct QuickProfileResponse: Codable, Sendable {
    let ok: Bool
    let written: [String]
    let proposals: [MemoryProposal]
    let status: OnboardingStatusDTO
}

struct InterviewStartResponse: Codable, Sendable {
    let ok: Bool
    let sessionId: String
    let title: String
    let mode: String
    let openingMessage: String
    let usedFallback: Bool
    let status: OnboardingStatusDTO

    enum CodingKeys: String, CodingKey {
        case ok, title, mode, status
        case sessionId = "session_id"
        case openingMessage = "opening_message"
        case usedFallback = "used_fallback"
    }
}

struct ImportPromptTemplateDTO: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let prompt: String
}

struct ImportPromptsResponse: Codable, Sendable {
    let templates: [ImportPromptTemplateDTO]
}

struct ImportChunkDTO: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let sourceType: String
    let sourceLabel: String
    let title: String
    let date: String
    let charCount: Int
    let signalScore: Int
    let recommended: Bool
    var selected: Bool
    let preview: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case id, title, date, recommended, selected, preview, content
        case sourceType = "source_type"
        case sourceLabel = "source_label"
        case charCount = "char_count"
        case signalScore = "signal_score"
    }
}

struct ImportPreviewResponse: Codable, Sendable {
    let detectedSource: String
    let detectedLabel: String
    let summary: String
    let totalItems: Int
    let shownItems: Int
    let recommendedItems: Int
    let selectedItems: Int
    let totalChars: Int
    let selectedChars: Int
    let warnings: [String]
    let items: [ImportChunkDTO]

    enum CodingKeys: String, CodingKey {
        case summary, warnings, items
        case detectedSource = "detected_source"
        case detectedLabel = "detected_label"
        case totalItems = "total_items"
        case shownItems = "shown_items"
        case recommendedItems = "recommended_items"
        case selectedItems = "selected_items"
        case totalChars = "total_chars"
        case selectedChars = "selected_chars"
    }
}

struct ImportExtractResponse: Codable, Sendable {
    let proposals: [MemoryProposal]
    let providerName: String?
    let batchesProcessed: Int?

    enum CodingKeys: String, CodingKey {
        case proposals
        case providerName = "provider_name"
        case batchesProcessed = "batches_processed"
    }
}
