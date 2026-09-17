//
//  RepoFileBrowserSheet.swift
//  Starcat
//
//  详情页「下载文件」Sheet：树形勾选 + 下载到用户选的目录。
//
//  必须由 `RepoListView` 根节点 `.sheet(item:)` 呈现，不能挂在 toolbar 菜单子树上，
//  否则会复现 CodeFlow 的「关闭后又闪一下」。文件夹展开必须整行可点，checkbox
//  是独立命中区，避免和折叠手势抢点击。
//

import SwiftUI
import AppKit

struct RepoFileBrowserSheetItem: Identifiable {
    let id = UUID()
    let target: RepoFileBrowserTarget
}

struct RepoFileBrowserSheet: View {
    let target: RepoFileBrowserTarget
    let apiClient: any GitHubAPIClientProtocol

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: RepoFileBrowserViewModel

    init(target: RepoFileBrowserTarget, apiClient: any GitHubAPIClientProtocol) {
        self.target = target
        self.apiClient = apiClient
        _viewModel = State(initialValue: RepoFileBrowserViewModel(target: target, apiClient: apiClient))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 14) {
            header
            treeArea
            footer
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .task {
            await viewModel.loadTree()
        }
        .onDisappear {
            viewModel.stop()
        }
        .toast(
            message: $viewModel.toastMessage,
            icon: viewModel.toastFileURL == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            duration: 4,
            iconColor: viewModel.toastFileURL == nil ? Color.orange : Color.green,
            bottomPadding: 24,
            actionLabel: viewModel.toastFileURL == nil ? nil : "repo.files.openFolder",
            onAction: {
                if let url = viewModel.toastFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("repo.files.title")
                    .font(.title3.weight(.semibold))
                Text(verbatim: "\(target.fullName) @ \(target.ref)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SheetCloseButton(action: { dismiss() })
        }
    }

    @ViewBuilder
    private var treeArea: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView("repo.files.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("action.retry") {
                    Task { await viewModel.loadTree() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .downloading, .finished:
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.isTruncated {
                    Label("repo.files.truncated", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.nodes.isEmpty {
                    Text("repo.files.empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.nodes) { node in
                                RepoFileTreeRow(node: node, viewModel: viewModel)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("repo.files.selectAll") {
                viewModel.selectAll()
            }
            .disabled(viewModel.isDownloading || viewModel.nodes.isEmpty)

            Button("repo.files.deselectAll") {
                viewModel.deselectAll()
            }
            .disabled(viewModel.isDownloading || viewModel.selectedCount == 0)

            Spacer()

            Text(verbatim: String(format: String.l10n("repo.files.selectedCountFormat"), viewModel.selectedCount))
                .font(.callout)
                .foregroundStyle(.secondary)

            if viewModel.isDownloading {
                if case .downloading(let completed, let total) = viewModel.phase {
                    Text(verbatim: String(format: String.l10n("repo.files.downloadingFormat"), completed, total))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("repo.files.cancelDownload", role: .destructive) {
                    viewModel.cancelDownload()
                }
            } else {
                Button("repo.files.downloadSelected") {
                    viewModel.startDownload()
                }
                .disabled(!viewModel.canDownload)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// 单个树节点。checkbox 与展开是两个独立 Button，满足整行折叠规范。
private struct RepoFileTreeRow: View {
    let node: RepoFileNode
    var viewModel: RepoFileBrowserViewModel
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                checkboxButton
                if node.isDirectory {
                    expandButton
                } else {
                    fileLabel
                }
            }
            .padding(.vertical, 3)

            if node.isDirectory, isExpanded, let children = node.children, !children.isEmpty {
                ForEach(children) { child in
                    RepoFileTreeRow(node: child, viewModel: viewModel)
                        .padding(.leading, 16)
                }
            }
        }
    }

    private var checkboxButton: some View {
        let state = RepoFileTreeBuilder.checkState(of: node, selected: viewModel.selectedPaths)
        let hasFiles = !RepoFileTreeBuilder.descendantFilePaths(of: node).isEmpty
        return Button {
            viewModel.toggle(node)
        } label: {
            Image(systemName: checkboxSymbol(state))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hasFiles ? Color.primary : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!hasFiles || viewModel.isDownloading)
        .accessibilityLabel(Text(node.isDirectory ? "repo.files.folder" : "repo.files.file"))
    }

    private var expandButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(verbatim: node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var fileLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(verbatim: node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = node.size {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func checkboxSymbol(_ state: RepoFileCheckState) -> String {
        switch state {
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        case .on: return "checkmark.square.fill"
        }
    }
}
