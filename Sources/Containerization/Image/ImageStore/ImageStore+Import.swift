//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

//

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension ImageStore {
    internal struct ImportOperation {
        static let decoder = JSONDecoder()

        let client: ContentClient
        let ingestDir: URL
        let contentStore: ContentStore
        let progress: ProgressHandler?
        let name: String

        init(name: String, contentStore: ContentStore, client: ContentClient, ingestDir: URL, progress: ProgressHandler? = nil) {
            self.client = client
            self.ingestDir = ingestDir
            self.contentStore = contentStore
            self.progress = progress
            self.name = name
        }

        /// Pull the required image layers for the provided descriptor and platform(s) into the given directory using the provided client. Returns a descriptor to the Index manifest.
        internal func `import`(root: Descriptor, matcher: (ContainerizationOCI.Platform) -> Bool) async throws -> Descriptor {
            var toProcess = [root]
            while !toProcess.isEmpty {
                // Count the total number of blobs and their size
                if let progress {
                    var size: Int64 = 0
                    for desc in toProcess {
                        size += desc.size
                    }
                    await progress([
                        ProgressEvent(event: "add-total-size", value: size),
                        ProgressEvent(event: "add-total-items", value: toProcess.count),
                    ])
                }

                try await self.fetch(toProcess)
                let children = try await self.walk(toProcess)
                let filtered = try filterPlatforms(matcher: matcher, children)
                toProcess = filtered.uniqued { $0.digest }
            }

            guard root.mediaType != MediaTypes.dockerManifestList && root.mediaType != MediaTypes.index else {
                return root
            }

            // Create an index for the root descriptor and write it to the content store
            let index = try await self.createIndex(for: root)
            // In cases where the root descriptor pointed to `MediaTypes.imageManifest`
            // Or `MediaTypes.dockerManifest`, it is required that we check the supported platform
            // matches the platforms we were asked to pull. This can be done only after we created
            // the Index.
            let supportedPlatforms = index.manifests.compactMap { $0.platform }
            guard supportedPlatforms.allSatisfy(matcher) else {
                throw ContainerizationError(.unsupported, message: "Image \(root.digest) does not support required platforms")
            }
            let writer = try ContentWriter(for: self.ingestDir)
            let result = try writer.create(from: index)
            return Descriptor(
                mediaType: MediaTypes.index,
                digest: result.digest.digestString,
                size: Int64(result.size))
        }

        private func getManifestContent<T: Sendable & Codable>(descriptor: Descriptor) async throws -> T {
            do {
                if let content = try await self.contentStore.get(digest: descriptor.digest.trimmingDigestPrefix) {
                    return try content.decode()
                }
                if let content = try? LocalContent(path: ingestDir.appending(path: descriptor.digest.trimmingDigestPrefix)) {
                    return try content.decode()
                }
                return try await self.client.fetch(name: name, descriptor: descriptor)
            } catch {
                throw ContainerizationError(.internalError, message: "Cannot fetch content with digest \(descriptor.digest)")
            }
        }

        private func walk(_ descriptors: [Descriptor]) async throws -> [Descriptor] {
            var out: [Descriptor] = []
            for desc in descriptors {
                let mediaType = desc.mediaType
                switch mediaType {
                case MediaTypes.index, MediaTypes.dockerManifestList:
                    let index: Index = try await self.getManifestContent(descriptor: desc)
                    out.append(contentsOf: index.manifests)
                case MediaTypes.imageManifest, MediaTypes.dockerManifest:
                    let manifest: Manifest = try await self.getManifestContent(descriptor: desc)
                    out.append(manifest.config)
                    out.append(contentsOf: manifest.layers)
                case MediaTypes.orasArtifactManifest:
                    throw ContainerizationError(.unsupported, message: "Artifact manifest not supported")
                case MediaTypes.notarySignature:
                    throw ContainerizationError(.unsupported, message: "Signature type not supported")
                case MediaTypes.imageLayerNonDistributable,
                    MediaTypes.imageLayerNonDistributableGzip,
                    MediaTypes.imageLayerNonDistributableZstd,
                    MediaTypes.dockerForeignLayer,
                    MediaTypes.intototAttestationBlob:
                    continue
                default:
                    continue
                }
            }
            return out
        }

        private func fetch(_ inDesc: [Descriptor]) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for chunk in inDesc.chunks(ofCount: 8) {
                    for desc in chunk {
                        if let found = try await self.contentStore.get(digest: desc.digest) {
                            try FileManager.default.copyItem(at: found.path, to: ingestDir.appendingPathComponent(desc.digest.trimmingDigestPrefix))
                            await progress?([
                                // Count the size of the blob
                                ProgressEvent(event: "add-size", value: desc.size),
                                // Count the number of blobs
                                ProgressEvent(event: "add-items", value: 1),
                            ])
                            continue
                        }
                        group.addTask {
                            if desc.size > 1.mib() {
                                try await self.fetchBlob(desc)
                            } else {
                                try await self.fetchData(desc)
                            }
                            // Count the number of blobs
                            await progress?([
                                ProgressEvent(event: "add-items", value: 1)
                            ])
                        }
                    }
                    try await group.waitForAll()
                }
            }
        }

        private func fetchBlob(_ descriptor: Descriptor) async throws {
            let id = UUID().uuidString
            let fm = FileManager.default
            let tempFile = ingestDir.appendingPathComponent(id)
            let (_, digest) = try await client.fetchBlob(name: name, descriptor: descriptor, into: tempFile, progress: progress)
            guard digest.digestString == descriptor.digest else {
                throw ContainerizationError(.internalError, message: "Digest mismatch expected \(descriptor.digest), got \(digest.digestString)")
            }
            do {
                try fm.moveItem(at: tempFile, to: ingestDir.appendingPathComponent(digest.encoded))
            } catch let err as NSError {
                guard err.code == NSFileWriteFileExistsError else {
                    throw err
                }
                try fm.removeItem(at: tempFile)
            }
        }

        @discardableResult
        private func fetchData(_ descriptor: Descriptor) async throws -> Data {
            let data = try await client.fetchData(name: name, descriptor: descriptor)
            let writer = try ContentWriter(for: ingestDir)
            let result = try writer.write(data)
            if let progress {
                let size = Int64(result.size)
                await progress([
                    ProgressEvent(event: "add-size", value: size)
                ])
            }
            guard result.digest.digestString == descriptor.digest else {
                throw ContainerizationError(.internalError, message: "Digest mismatch expected \(descriptor.digest), got \(result.digest.digestString)")
            }
            return data
        }

        private func createIndex(for root: Descriptor) async throws -> Index {
            switch root.mediaType {
            case MediaTypes.index, MediaTypes.dockerManifestList:
                return try await self.getManifestContent(descriptor: root)
            case MediaTypes.imageManifest, MediaTypes.dockerManifest:
                let supportedPlatforms = try await getSupportedPlatforms(for: root)
                guard supportedPlatforms.count == 1 else {
                    throw ContainerizationError(
                        .internalError,
                        message:
                            "Descriptor \(root.mediaType) with digest \(root.digest) does not list any supported platform or supports more than one platform. Supported platforms = \(supportedPlatforms)"
                    )
                }
                let platform = supportedPlatforms.first!
                var root = root
                root.platform = platform
                let index = ContainerizationOCI.Index(schemaVersion: 2, manifests: [root])
                return index
            case MediaTypes.orasArtifactManifest:
                throw ContainerizationError(.unsupported, message: "Cannot import artifact manifest \(root.digest)")
            case MediaTypes.notarySignature:
                throw ContainerizationError(.unsupported, message: "Cannot import signature \(root.digest)")
            default:
                throw ContainerizationError(.internalError, message: "Failed to create index for descriptor \(root.digest), media type \(root.mediaType)")
            }
        }

        private func getSupportedPlatforms(for root: Descriptor) async throws -> [ContainerizationOCI.Platform] {
            var supportedPlatforms: [ContainerizationOCI.Platform] = []
            var toProcess = [root]
            while !toProcess.isEmpty {
                let children = try await self.walk(toProcess)
                for child in children {
                    if let p = child.platform {
                        supportedPlatforms.append(p)
                        continue
                    }
                    switch child.mediaType {
                    case MediaTypes.imageConfig, MediaTypes.dockerImageConfig:
                        let config: ContainerizationOCI.Image = try await self.getManifestContent(descriptor: child)
                        let p = ContainerizationOCI.Platform(
                            arch: config.architecture, os: config.os, osFeatures: config.osFeatures, variant: config.variant
                        )
                        supportedPlatforms.append(p)
                    case MediaTypes.orasArtifactManifest, MediaTypes.notarySignature:
                        continue
                    default:
                        continue
                    }
                }
                toProcess = children
            }
            return supportedPlatforms
        }

    }
}
