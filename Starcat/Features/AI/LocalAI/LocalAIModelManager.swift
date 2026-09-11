//
//  LocalAIModelManager.swift
//  Starcat
//
//  本地 AI 模型管理器：下载 / 暂停 / 删除 / 安装状态 + 内置 profile 同步。
//
//  架构：
//  - `LocalAIModelManager`（@MainActor @Observable）：设置页直接观察的状态机。
//    下载重活交给 `LocalAIModelDownloader`（actor）与 `LocalAIModelStorage`（纯函数）。
//  - 内置 profile：`AIProviderProfile` 的 selection 解析只卡 `isVerifiedConfiguration`
//    （= isEnabled && lastTestStatus.isSuccess），因此本地接入的最小适配是维护一个固定
//    id 的内置 profile：模型安装状态变化时同步 `models`（AIModelDescriptor 列表）与
//    `lastTestStatus`。任务模型 picker、capability 校验、`hasConfiguredChatModel`
//    全部复用现有逻辑，零分支。
//  - 免费：本地 AI 不做 Pro 门控；门控放行由 EntitlementGate 侧按 provider 判断。
//
//  关键约束：
//  - `TestEnvironment.isRunning` 时 `shared` 为 no-op 状态：不发起下载、不触发 MLX。
//  - manifest.json 是安装状态单一真源；本机的 `installStates` 只是 UI 快照，
//    启动时从磁盘 `listInstalled()` 重建。
//

import Foundation
import Observation

/// 设置页观察的单模型下载状态。
enum LocalAIInstallState: Equatable, Sendable {
    case idle
    case preparing
    case downloading(progress: Double)
    case failed(message: String)
    case installed

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

@MainActor
@Observable
final class LocalAIModelManager {

    static let shared = LocalAIModelManager()

    /// 单模型下载状态（key = catalog entry id）。
    private(set) var installStates: [String: LocalAIInstallState] = [:]
    /// 已安装模型（磁盘 manifest 快照，启动 / 安装 / 删除时刷新）。
    private(set) var installedModels: [LocalAIInstalledModel] = []
    /// 是否正在同步内置 profile（避免重入）。
    private var isSyncingProfile = false

    private let downloader = LocalAIModelDownloader()
    /// catalog id -> 正在进行的下载 Task，供暂停/取消。
    private var runningInstalls: [String: Task<Void, Never>] = [:]

    private init() {
        refreshInstalledModels()
    }

    // MARK: - 查询

    func installState(for entryID: String) -> LocalAIInstallState {
        if installedModels.contains(where: { $0.id == entryID }) {
            return .installed
        }
        return installStates[entryID] ?? .idle
    }

    func installedModel(id: String) -> LocalAIInstalledModel? {
        installedModels.first { $0.id == id }
    }

    /// 模型安装目录；未安装返回 nil。`LocalMLXClient` 解析模型名的入口。
    func installedDirectoryURL(entryID: String) -> URL? {
        guard let manifest = installedModel(id: entryID) else { return nil }
        guard let entry = LocalAIModelCatalog.entry(id: entryID) else { return nil }
        return try? LocalAIModelStorage.modelDirectory(entry: entry, revision: manifest.revision)
    }

    var modelsRootURL: URL? {
        try? LocalAIModelStorage.modelsRootURL()
    }

    var totalDiskUsage: Int64 {
        LocalAIModelStorage.totalDiskUsage()
    }

    /// 任务选择器视角：某能力下当前可用（已安装）的模型名列表。
    func installedModelNames(capability: AIModelCapability) -> [String] {
        LocalAIModelCatalog.entries
            .filter { $0.capability == capability }
            .filter { entry in installedModels.contains { $0.id == entry.id } }
            .map(\.displayName)
    }

    // MARK: - 安装 / 暂停 / 删除

    /// 下载并安装一个 catalog 模型。重复调用同 id 时忽略（UI 按钮已置灰，防御性兜底）。
    func install(entry: LocalAIModelCatalogEntry) {
        if TestEnvironment.isRunning { return }
        guard runningInstalls[entry.id] == nil else { return }
        guard !installState(for: entry.id).isInstalled else { return }

        installStates[entry.id] = .preparing
        // 强持有 self：manager 是进程级单例，安装期间不释放；weak 会让 Task 句柄变成 Void?。
        let task = Task {
            await self.runInstall(entry: entry)
        }
        runningInstalls[entry.id] = task
    }

    /// 暂停（取消当前下载）。`.part` 保留，下次 install 从断点续传。
    func pause(entryID: String) {
        runningInstalls[entryID]?.cancel()
        runningInstalls[entryID] = nil
        if case .downloading = installStates[entryID] {
            installStates[entryID] = .idle
        } else if installStates[entryID] == .preparing {
            installStates[entryID] = .idle
        }
    }

    func delete(entryID: String) {
        pause(entryID: entryID)
        guard let manifest = installedModel(id: entryID),
            let entry = LocalAIModelCatalog.entry(id: entryID)
        else { return }
        let directory = try? LocalAIModelStorage.modelDirectory(
            entry: entry, revision: manifest.revision)
        if let directory {
            try? LocalAIModelStorage.remove(modelDirectory: directory)
        }
        refreshInstalledModels()
        syncBuiltInProfile()
    }

    /// 删除全部本地模型（设置页危险操作）。
    func deleteAll() {
        for entry in LocalAIModelCatalog.entries {
            pause(entryID: entry.id)
        }
        for manifest in installedModels {
            guard let entry = LocalAIModelCatalog.entry(id: manifest.id) else { continue }
            if let directory = try? LocalAIModelStorage.modelDirectory(
                entry: entry, revision: manifest.revision) {
                try? LocalAIModelStorage.remove(modelDirectory: directory)
            }
        }
        LocalAIModelStorage.cleanPartialFiles()
        refreshInstalledModels()
        syncBuiltInProfile()
    }

    // MARK: - 内部安装流程

    private func runInstall(entry: LocalAIModelCatalogEntry) async {
        do {
            let revision = try await resolveRevision(for: entry.source)
            let directory = try LocalAIModelStorage.modelDirectory(
                entry: entry, revision: revision)
            var records: [LocalAIFileRecord] = []
            let optionalFiles = Set(
                entry.files.filter { !$0.isRequired }.map(\.name))

            for file in entry.files {
                if Task.isCancelled {
                    installStates[entry.id] = .idle
                    runningInstalls[entry.id] = nil
                    return
                }
                do {
                    let record = try await downloadOne(
                        entry: entry, revision: revision, file: file.name,
                        directory: directory)
                    records.append(record)
                } catch let error as LocalAIDownloadError {
                    if error == .cancelled {
                        installStates[entry.id] = .idle
                        runningInstalls[entry.id] = nil
                        return
                    }
                    // 可选文件 404 / 不存在时跳过（不同 mlx-community 转换仓库文件集不一致）。
                    if optionalFiles.contains(file.name), isNotFound(error) {
                        continue
                    }
                    throw error
                }
            }

            let manifest = LocalAIInstalledModel(
                id: entry.id,
                displayName: entry.displayName,
                type: entry.type,
                revision: revision,
                installedAt: Date(),
                sourceKind: entry.source.kind,
                files: records,
                embeddingDimension: entry.embeddingDimension,
                totalBytes: records.reduce(0) { $0 + $1.sizeBytes })
            try LocalAIModelStorage.save(manifest, in: directory)

            refreshInstalledModels()
            installStates[entry.id] = .installed
            syncBuiltInProfile()
        } catch {
            installStates[entry.id] = .failed(
                message: error.localizedDescription)
        }
        runningInstalls[entry.id] = nil
    }

    private func downloadOne(
        entry: LocalAIModelCatalogEntry,
        revision: String,
        file: String,
        directory: URL
    ) async throws -> LocalAIFileRecord {
        let remoteURL: URL
        switch entry.source.kind {
        case .huggingFace:
            guard let url = URL(string: "https://huggingface.co/\(entry.source.repo)/resolve/\(revision)/\(file)"
            ) else {
                throw LocalAIDownloadError.invalidURL(file)
            }
            remoteURL = url
        case .modelScope:
            // v1 catalog 不登记 ModelScope；保留分支使源枚举完备。
            throw LocalAIDownloadError.invalidURL(file)
        }
        let result = try await downloader.downloadFile(
            remoteURL: remoteURL,
            fileName: file,
            into: directory,
            expectedTotalBytes: entry.estimatedDownloadSize,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.installStates[entry.id] = .downloading(progress: progress)
                }
            })
        return LocalAIFileRecord(
            name: result.name, sha256: result.sha256, sizeBytes: result.sizeBytes)
    }

    /// 解析远端 revision：固定值直接用；否则查 HF API 取当前 commit SHA（记录进 manifest 可追溯）。
    private func resolveRevision(for source: LocalAIModelSource) async throws -> String {
        if let revision = source.revision { return revision }
        switch source.kind {
        case .huggingFace:
            guard let url = URL(string: "https://huggingface.co/api/models/\(source.repo)") else {
                throw LocalAIDownloadError.invalidURL(source.repo)
            }
            var request = URLRequest(url: url)
            request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw LocalAIDownloadError.invalidURL(source.repo)
            }
            struct HFModelInfo: Decodable { let sha: String }
            return try JSONDecoder().decode(HFModelInfo.self, from: data).sha
        case .modelScope:
            throw LocalAIDownloadError.invalidURL(source.repo)
        }
    }

    private func isNotFound(_ error: LocalAIDownloadError) -> Bool {
        if case .httpStatus(let code) = error { return code == 404 }
        return false
    }

    private func refreshInstalledModels() {
        installedModels = (try? LocalAIModelStorage.listInstalled()) ?? []
    }

    // MARK: - 内置 profile 同步

    /// 把安装状态写进内置 profile。App 启动与每次安装 / 删除后调用。
    ///
    /// `lastTestStatus` 只承担「本地 provider 已验证」语义：有任一已安装模型即
    /// `.success(modelCount:)`；细粒度的 capability 匹配仍由 `resolveChatSelection` /
    /// `resolveEmbeddingSelection` 按 `profile.models` 校验兜底。
    func syncBuiltInProfile() {
        guard !TestEnvironment.isRunning else { return }
        guard !isSyncingProfile else { return }
        isSyncingProfile = true
        defer { isSyncingProfile = false }

        let settings = AppSettings.shared
        var profiles = settings.aiProviderProfiles
        let descriptors = installedModelDescriptors()
        let index = profiles.firstIndex { $0.id == LocalAIModelCatalog.builtInProfileID }

        if descriptors.isEmpty && index == nil {
            return
        }

        if let index {
            var profile = profiles[index]
            guard profile.provider == .localAI else { return }
            profile.models = descriptors
            profile.lastTestStatus = descriptors.isEmpty
                ? .notTested
                : .success(modelCount: descriptors.count)
            profiles[index] = profile
        } else {
            let profile = AIProviderProfile(
                id: LocalAIModelCatalog.builtInProfileID,
                provider: .localAI,
                models: descriptors,
                lastTestStatus: descriptors.isEmpty
                    ? .notTested
                    : .success(modelCount: descriptors.count))
            profiles.append(profile)
        }
        settings.aiProviderProfiles = profiles
    }

    /// 已安装模型 → 内置 profile 的 AIModelDescriptor 列表。
    ///
    /// name 用 catalog 稳定名（用户在任务配置里看到的名字）；revision 由
    /// `LocalMLXClient` 经 manager 解析，用户不感知。
    private func installedModelDescriptors() -> [AIModelDescriptor] {
        let catalogByID = Dictionary(
            uniqueKeysWithValues: LocalAIModelCatalog.entries.map { ($0.id, $0) })
        return installedModels.compactMap { manifest in
            guard let entry = catalogByID[manifest.id] else { return nil }
            return AIModelDescriptor(
                providerID: LocalAIModelCatalog.builtInProfileID,
                name: entry.displayName,
                ownedBy: "Starcat Local AI",
                capability: entry.capability,
                isEnabled: true)
        }
    }
}
