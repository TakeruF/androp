// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import AppKit
import Foundation
import Photos

@MainActor
enum LivePhotoImporter {
    enum Failure: Error, Equatable {
        case invalidPackage
        case permissionDenied
        case importFailed
        case openFailed
    }

    struct Resource: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case photo, pairedVideo }
        let kind: Kind
        let url: URL
    }

    struct Plan: Sendable, Equatable {
        let package: URL
        let resources: [Resource]
    }

    // Keeping the three system operations injectable lets tests exercise the
    // complete flow without accessing or changing a personal Photos library.
    struct Dependencies {
        var authorize: @MainActor () async -> PHAuthorizationStatus
        var create: @MainActor ([Plan]) async throws -> Void
        var open: @MainActor () async throws -> Void

        static var system: Self {
            Self(authorize: {
                let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                return status == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : status
            }, create: { plans in
                guard PHAssetCreationRequest.supportsAssetResourceTypes([
                    NSNumber(value: PHAssetResourceType.photo.rawValue),
                    NSNumber(value: PHAssetResourceType.pairedVideo.rawValue)
                ]) else { throw Failure.importFailed }
                try await PHPhotoLibrary.shared().performChanges {
                    for plan in plans {
                        // One creation request, with both resources, creates one
                        // Live Photo rather than an unrelated image and movie.
                        let asset = PHAssetCreationRequest.forAsset()
                        for resource in plan.resources {
                            let options = PHAssetResourceCreationOptions()
                            options.shouldMoveFile = false
                            let type: PHAssetResourceType = resource.kind == .photo ? .photo : .pairedVideo
                            asset.addResource(with: type, fileURL: resource.url, options: options)
                        }
                    }
                }
            }, open: {
                guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else {
                    throw Failure.openFailed
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
            })
        }
    }

    /// Only the engine's locally generated, already PhotoKit-validated packages
    /// carry `kind: live_photo`. A received .pvt path alone never authorizes an
    /// import, and ordinary received photos never request Photos permission.
    static func importAndOpen(files: [[String: Any]]) async throws -> Bool {
        try await importAndOpen(files: files, using: .system)
    }

    static func importAndOpen(files: [[String: Any]], using dependencies: Dependencies) async throws -> Bool {
        let plans = try plans(for: files)
        guard !plans.isEmpty else { return false }
        let status = await dependencies.authorize()
        guard status == .authorized || status == .limited else { throw Failure.permissionDenied }
        do { try await dependencies.create(plans) }
        catch { throw Failure.importFailed }
        do { try await dependencies.open() }
        catch { throw Failure.openFailed }
        return true
    }

    static func plans(for files: [[String: Any]]) throws -> [Plan] {
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
            return Plan(package: package, resources: [Resource(kind: .photo, url: image.resolvingSymlinksInPath()),
                                                     Resource(kind: .pairedVideo, url: video.resolvingSymlinksInPath())])
        } catch {
            throw Failure.invalidPackage
        }
    }

    static func message(for error: Error) -> String {
        switch error as? Failure {
        case .permissionDenied:
            L("The received files are saved. Allow anDrop to add photos in System Settings → Privacy & Security → Photos.",
              "收到的文件已保存。请在“系统设置 → 隐私与安全性 → 照片”中允许 anDrop 添加照片。")
        case .invalidPackage:
            L("The received files are saved, but the Live Photo package could not be opened.",
              "收到的文件已保存，但无法打开实况照片文件包。")
        case .openFailed:
            L("The Live Photo was added to Photos, but Photos could not be opened.",
              "实况照片已添加到“照片”，但无法打开“照片”应用。")
        default:
            L("The received files are saved, but the Live Photo could not be added to Photos.",
              "收到的文件已保存，但无法将实况照片添加到“照片”。")
        }
    }
}
