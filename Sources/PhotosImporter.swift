// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import Foundation
import Photos
import UniformTypeIdentifiers

@MainActor
enum PhotosImporter {
    enum Failure: Error, Equatable {
        case invalidPackage
        case permissionDenied
        case importFailed
    }

    struct Resource: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case photo, video, pairedVideo

            var resourceType: PHAssetResourceType {
                switch self {
                case .photo: .photo
                case .video: .video
                case .pairedVideo: .pairedVideo
                }
            }
        }
        let kind: Kind
        let url: URL
    }

    struct Plan: Sendable, Equatable {
        let source: URL
        let resources: [Resource]
    }

    struct Result: Equatable {
        var importedCount = 0
        var failedCount = 0
        var remainingCount = 0
        var wasStopped = false
    }

    struct Progress: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case queued, importing, finished, stopped, permissionDenied }
        var phase: Phase = .queued
        var importedCount = 0
        var failedCount = 0
        var totalCount = 0
        var processedCount: Int { importedCount + failedCount }
        var active: Bool { phase == .queued || phase == .importing }
        var fraction: Double? { totalCount > 0 ? min(1, Double(processedCount) / Double(totalCount)) : nil }

        func label(chinese: Bool) -> String {
            switch phase {
            case .queued: chinese ? "等待导入“照片” · \(totalCount) 项" : "Waiting to add to Photos · \(totalCount) items"
            case .importing: chinese ? "正在导入“照片” · \(processedCount)/\(totalCount)" : "Adding to Photos · \(processedCount)/\(totalCount)"
            case .stopped: chinese ? "照片导入已停止 · 已添加 \(importedCount)，失败 \(failedCount)，剩余 \(max(0, totalCount - processedCount))" : "Photos import stopped · \(importedCount) added, \(failedCount) failed, \(max(0, totalCount - processedCount)) remaining"
            case .permissionDenied: chinese ? "照片导入已停止 · 需要照片图库许可" : "Photos import stopped · Photos permission required"
            case .finished:
                if failedCount > 0 {
                    chinese ? "照片导入结果 · 已添加 \(importedCount)，失败 \(failedCount)" : "Photos · \(importedCount) added, \(failedCount) failed"
                } else {
                    chinese ? "已添加到“照片” · \(importedCount) 项" : "Added to Photos · \(importedCount) items"
                }
            }
        }
    }

    // Tests replace only the OS boundary, without changing a personal library.
    struct Dependencies {
        var authorize: @MainActor () async -> PHAuthorizationStatus
        var create: @MainActor (Plan) async throws -> Void
        var status: @MainActor () -> PHAuthorizationStatus = { PHPhotoLibrary.authorizationStatus(for: .addOnly) }

        static var system: Self {
            Self(authorize: {
                let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                return status == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : status
            }, create: { plan in
                guard PHAssetCreationRequest.supportsAssetResourceTypes(plan.resources.map {
                    NSNumber(value: $0.kind.resourceType.rawValue)
                }) else { throw Failure.importFailed }
                try await PHPhotoLibrary.shared().performChanges {
                    // A separate transaction per asset prevents one unsupported
                    // or corrupt file from failing the rest of a mixed batch.
                    // Both Live Photo resources belong to the same asset.
                    let asset = PHAssetCreationRequest.forAsset()
                    for resource in plan.resources {
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = false
                        asset.addResource(with: resource.kind.resourceType, fileURL: resource.url, options: options)
                    }
                }
            })
        }
    }

    static func isAuthorized(_ status: PHAuthorizationStatus) -> Bool { status == .authorized || status == .limited }

    static func importReceived(files: [[String: Any]], enabled: Bool,
                               using dependencies: Dependencies = .system,
                               shouldContinue: @MainActor () -> Bool = { true },
                               progress: @MainActor (Progress) -> Void = { _ in }) async throws -> Result {
        guard enabled else { return Result() }
        let selection = selection(for: files)
        var result = Result(failedCount: selection.failedCount)
        let total = selection.plans.count + selection.failedCount
        func report(_ phase: Progress.Phase) {
            progress(Progress(phase: phase, importedCount: result.importedCount, failedCount: result.failedCount, totalCount: total))
        }
        func stop() -> Result {
            result.remainingCount = max(0, total - result.importedCount - result.failedCount)
            result.wasStopped = true
            report(.stopped)
            return result
        }
        guard !selection.plans.isEmpty else { report(.finished); return result }
        guard shouldContinue() else { return stop() }
        let status = await dependencies.authorize()
        guard shouldContinue() else { return stop() }
        guard isAuthorized(status) else { throw Failure.permissionDenied }
        report(.importing)
        for plan in selection.plans {
            // Finish an in-flight PhotoKit transaction, then honor OFF/Stop
            // before starting another asset. Never roll back imported assets.
            guard shouldContinue() else { return stop() }
            do {
                try await dependencies.create(plan)
                result.importedCount += 1
            } catch {
                result.failedCount += 1
            }
            report(.importing)
        }
        report(.finished)
        return result
    }

    static func selection(for files: [[String: Any]]) -> (plans: [Plan], failedCount: Int) {
        var result: [Plan] = []
        var seen = Set<URL>()
        var originals = Set<URL>()
        var failedCount = 0
        for file in files where file["kind"] as? String == "live_photo" {
            do {
                for plan in try livePhotoPlans(for: [file]) where seen.insert(plan.source).inserted {
                    result.append(plan)
                    // A converted Motion Photo retains its downloaded original.
                    // Import the validated pair once, without another still asset.
                    if let original = localURL(file["original_path"]) { originals.insert(original.resolvingSymlinksInPath()) }
                }
            } catch { failedCount += 1 }
        }
        for file in files where file["kind"] as? String != "live_photo" {
            guard let url = localURL(file["path"]),
                  let type = UTType(filenameExtension: url.pathExtension),
                  type != .svg, type != .pdf else { continue }
            let kind: Resource.Kind
            if type.conforms(to: .image) { kind = .photo }
            else if type.conforms(to: .movie) { kind = .video }
            else { continue }
            let canonical = url.resolvingSymlinksInPath()
            guard !originals.contains(canonical), seen.insert(canonical).inserted else { continue }
            guard isType(url, .typeRegular) else { failedCount += 1; continue }
            result.append(Plan(source: canonical, resources: [Resource(kind: kind, url: canonical)]))
        }
        return (result, failedCount)
    }

    /// Only locally generated, PhotoKit-validated packages carry this marker.
    /// An arbitrary received .pvt path never authorizes package traversal.
    static func livePhotoPlans(for files: [[String: Any]]) throws -> [Plan] {
        var packages = Set<URL>()
        var result: [Plan] = []
        for file in files where file["kind"] as? String == "live_photo" {
            guard let path = file["path"] as? String, path.hasPrefix("/"), !path.contains("\0") else {
                throw Failure.invalidPackage
            }
            let package = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard package.pathExtension.lowercased() == "pvt", isType(package, .typeDirectory) else {
                throw Failure.invalidPackage
            }
            let canonical = package.resolvingSymlinksInPath()
            guard packages.insert(canonical).inserted else { continue }
            result.append(try plan(for: canonical))
        }
        return result
    }

    private static func isType(_ url: URL, _ expected: FileAttributeType) -> Bool {
        // FileManager's attributesOfItem uses the link itself; a symlink never
        // passes as either a regular resource or a package directory.
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == expected
    }

    private static func plan(for package: URL) throws -> Plan {
        do {
            let children = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)
            guard children.count == 3, children.allSatisfy({ isType($0, .typeRegular) }) else {
                throw Failure.invalidPackage
            }
            let images = children.filter { ["jpg", "jpeg", "heic", "heif"].contains($0.pathExtension.lowercased()) }
            let videos = children.filter { $0.pathExtension.lowercased() == "mov" }
            guard images.count == 1, videos.count == 1, let image = images.first, let video = videos.first,
                  image.deletingPathExtension().lastPathComponent == video.deletingPathExtension().lastPathComponent else {
                throw Failure.invalidPackage
            }
            let stem = image.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("anDrop-"), UUID(uuidString: String(stem.dropFirst(7))) != nil else {
                throw Failure.invalidPackage
            }
            guard let metadata = children.first(where: { $0.lastPathComponent == "metadata.plist" }),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: metadata.path),
                  let metadataSize = attributes[.size] as? NSNumber, metadataSize.int64Value <= 65_536 else {
                throw Failure.invalidPackage
            }
            let data = try Data(contentsOf: metadata)
            let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            guard values?["PFVideoComplementMetadataVersionKey"] == "1" else { throw Failure.invalidPackage }
            return Plan(source: package, resources: [Resource(kind: .photo, url: image.resolvingSymlinksInPath()),
                                                     Resource(kind: .pairedVideo, url: video.resolvingSymlinksInPath())])
        } catch {
            throw Failure.invalidPackage
        }
    }

    private static func localURL(_ value: Any?) -> URL? {
        guard let path = value as? String, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func message(for error: Error) -> String {
        switch error as? Failure {
        case .permissionDenied:
            L("The received files are saved. Allow anDrop to add photos and videos in System Settings → Privacy & Security → Photos.",
              "收到的文件已保存。请在“系统设置 → 隐私与安全性 → 照片”中允许 anDrop 添加照片和视频。")
        default:
            L("The received files are saved, but some photos or videos could not be added to Photos. You can import them manually from the save folder.",
              "收到的文件已保存，但部分照片或视频无法添加到“照片”。您可以从保存文件夹手动导入。")
        }
    }
}
