//
//  LocalAIModelCatalogTests.swift
//  StarcatTests
//
//  内置模型目录的契约测试：唯一性、能力标签、reranker 命名约定（RerankerModelFactory
//  的 verified-naming 依赖目录名包含 "rerank"）。
//

import Foundation
import Testing
@testable import Starcat

@Suite("LocalAIModelCatalog")
struct LocalAIModelCatalogTests {

    @Test("entry id 唯一且非空")
    func uniqueIDs() {
        let ids = LocalAIModelCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { !$0.isEmpty })
    }

    @Test("每类至少有一个推荐模型，且推荐项唯一")
    func recommendedPerType() {
        for type in LocalAIModelType.allCases {
            let entries = LocalAIModelCatalog.entries.filter { $0.type == type }
            #expect(!entries.isEmpty)
            #expect(entries.filter(\.recommended).count == 1)
        }
    }

    @Test("capability 与类型对齐")
    func capabilityMapping() {
        for entry in LocalAIModelCatalog.entries {
            switch entry.type {
            case .embedding:
                #expect(entry.capability == .embedding)
                #expect(entry.embeddingDimension != nil)
            case .llm:
                #expect(entry.capability == .chat)
            case .reranker:
                #expect(entry.capability == .rerank)
            }
        }
    }

    @Test("reranker 目录命名满足 RerankerModelFactory verified-naming")
    func rerankerVerifiedNaming() {
        for entry in LocalAIModelCatalog.entries where entry.type == .reranker {
            #expect(LocalAIModelCatalog.usesRerankerVerifiedNaming(entry.id))
        }
    }

    @Test("预估体积与必填文件集非空")
    func sizesAndFiles() {
        for entry in LocalAIModelCatalog.entries {
            #expect(entry.estimatedDownloadSize > 0)
            #expect(entry.memoryRecommendation > 0)
            #expect(entry.files.contains { $0.name == "config.json" })
            #expect(entry.files.contains { $0.name == "model.safetensors" })
            #expect(entry.source.kind == .huggingFace)
            #expect(!entry.source.repo.isEmpty)
        }
    }

    @Test("内置 profile id 与 catalog 解析稳定")
    func builtInProfileIDLookup() {
        #expect(LocalAIModelCatalog.builtInProfileID == "built-in.local-ai")
        #expect(LocalAIModelCatalog.entry(id: "qwen3-embedding-0.6b-8bit") != nil)
        #expect(LocalAIModelCatalog.entry(id: "not-exist") == nil)
    }
}
