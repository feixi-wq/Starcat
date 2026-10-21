//
//  BusinessIconTests.swift
//  StarcatTests
//
//  验证业务图标资源、跨页面映射和紧凑尺寸；离屏测试不打开或操作应用窗口。
//

import AppKit
import SwiftUI
import Testing
@testable import Starcat

/// 资源测试避免只改调用点却遗漏 Asset Catalog，导致实际界面出现空白图标。
@MainActor
@Suite("Business icons")
struct BusinessIconTests {
    @Test("补充业务图标存在且为可着色模板", arguments: BusinessIcon.Symbol.allCases.filter(\.isAsset))
    func assetsAreBundledTemplates(_ symbol: BusinessIcon.Symbol) throws {
        let image = try #require(NSImage(named: symbol.rawValue))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 24, height: 24))
    }

    @Test("保留的系统业务图标在当前系统可用", arguments: BusinessIcon.Symbol.allCases.filter { !$0.isAsset })
    func systemSymbolsExist(_ symbol: BusinessIcon.Symbol) {
        #expect(NSImage(systemSymbolName: symbol.systemImage, accessibilityDescription: nil) != nil)
    }

    @Test("图标遵循显示尺寸而不是 24px 素材网格", arguments: BusinessIcon.Symbol.allCases.filter(\.isAsset), [11.0, 13.0, 14.0, 16.0, 18.0])
    func renderingKeepsRequestedSize(_ symbol: BusinessIcon.Symbol, size: Double) throws {
        let renderer = ImageRenderer(content: BusinessIcon(symbol, pointSize: size)
            .foregroundStyle(.primary)
            .dynamicTypeSize(.large))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(size))
        #expect(image.height == Int(size))
    }

    /// 共享来源和窗口标题必须同源；只测单个资源存在，无法发现另一页仍引用旧图标。
    @Test("主侧栏、Agent 来源和 RAG 设置共享业务语义")
    func navigationMappingsStayConsistent() {
        #expect(ExploreMode.awesome.businessIcon == .curatedCollection)
        #expect(ExploreMode.discover.businessIcon.systemImage == AgentRepositorySource.discovery.systemImage)
        #expect(ExploreMode.trending.businessIcon.systemImage == AgentRepositorySource.trending.systemImage)
        #expect(ExploreMode.weekly.businessIcon.systemImage == AgentRepositorySource.weekly.systemImage)
        #expect(SidebarItem.library.systemImage == AgentRepositorySource.knowledge.systemImage)
        #expect(SidebarItem.allStars.systemImage == AgentRepositorySource.starred.systemImage)
        #expect(RAGSettingsSection.inference.businessIcon == .inference)
        #expect(RAGSettingsSection.prompts.businessIcon == .prompts)
        #expect(RAGSettingsSection.retrieval.businessIcon == .retrieval)
        #expect(AppBackgroundTask.Kind.indexing.icon == .aiIndex)
        #expect(AppBackgroundTask.Kind.grouping.icon == .groups)
        #expect(AppBackgroundTask.Kind.tags.icon == .tags)
    }

    @Test("RAG 引用与分片的内容类型一致，摘要不再使用翻译图标")
    func citationMappingsStayConsistent() {
        #expect(RAGChunkSource.readme.systemImageName == RAGCitationSource.readme.systemImageName)
        #expect(RAGChunkSource.notes.systemImageName == RAGCitationSource.notes.systemImageName)
        #expect(RAGChunkSource.summary.systemImageName == RAGCitationSource.summary.systemImageName)
        #expect(RAGChunkSource.metadata.systemImageName == RAGCitationSource.metadata.systemImageName)
        #expect(RAGChunkSource.summary.systemImageName == BusinessIcon.Symbol.summary.systemImage)
        #expect(RAGChunkSource.summary.systemImageName != BusinessIcon.Symbol.translation.systemImage)
        #expect(RAGCitationSource.repoContext.systemImageName == BusinessIcon.Symbol.codeContext.systemImage)
        #expect(RAGPlanSectionHelpTopic.repoContext.systemImage == BusinessIcon.Symbol.codeContext.systemImage)
        #expect(BuiltInAgents.untaggedTidy.systemImage == BusinessIcon.Symbol.tags.systemImage)
    }

    /// 固定容器代表既有 Label 图标列；覆盖明暗主题与三个字号档，不依赖真实屏幕。
    @Test("所有业务图标在明暗主题和字号档位中不改变图标列", arguments: [ColorScheme.light, .dark])
    func iconSlotsStayBounded(colorScheme: ColorScheme) throws {
        for scale in InterfaceScale.allCases {
            for symbol in BusinessIcon.Symbol.allCases {
                let side = 18 * scale.multiplier
                let renderer = ImageRenderer(content: BusinessIcon(symbol, pointSize: 13 * scale.multiplier, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .environment(\.colorScheme, colorScheme)
                    .dynamicTypeSize(.large))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(abs(CGFloat(image.width) / 2 - side) < 1)
                #expect(abs(CGFloat(image.height) / 2 - side) < 1)
            }
        }
    }
}
