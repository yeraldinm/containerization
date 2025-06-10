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

import ContainerizationError
import ContainerizationOCI
import Foundation

/// Data representing the image to use as the root filesystem for a virtual machine.
/// Typically this image would contain the guest agent used to facilitate container
/// workloads, as well as any extras that may be useful to have in the guest.
public struct InitImage: Sendable {
    public var name: String { image.reference }

    let image: Image

    public init(image: Image) {
        self.image = image
    }
}

extension InitImage {
    fileprivate static func decompressGzip(source: URL, destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", source.path]
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        try out.close()
        guard process.terminationStatus == 0 else {
            throw ContainerizationError(.internalError, message: "failed to decompress \(source.path)")
        }
    }
}

extension InitImage {
    /// Unpack the initial filesystem for the desired platform at a given path.
    public func initBlock(at: URL, for platform: SystemPlatform) async throws -> Mount {
        var fs = try await image.unpack(for: platform.ociPlatform(), at: at, blockSizeInBytes: 512.mib())
        fs.options = ["ro"]
        return fs
    }

    /// Create a new InitImage with the reference as the name.
    /// The `rootfs` parameter must be a tar.gz file whose contents make up the filesystem for the image.
    public static func create(
        reference: String, rootfs: URL, platform: Platform,
        labels: [String: String] = [:], imageStore: ImageStore, contentStore: ContentStore
    ) async throws -> InitImage {

        let indexDescriptorStore = AsyncStore<Descriptor>()
        try await contentStore.ingest { dir in
            let writer = try ContentWriter(for: dir)
            var result = try writer.create(from: rootfs)
            let layerDescriptor = Descriptor(mediaType: ContainerizationOCI.MediaTypes.imageLayerGzip, digest: result.digest.digestString, size: result.size)

            let uncompressedURL = FileManager.default.uniqueTemporaryDirectory().appending(path: "layer.tar")
            defer { try? FileManager.default.removeItem(at: uncompressedURL) }
            try Self.decompressGzip(source: rootfs, destination: uncompressedURL)
            let diffDigest = try LocalContent(path: uncompressedURL).digest()
            let rootfsConfig = ContainerizationOCI.Rootfs(type: "layers", diffIDs: [diffDigest.digestString])
            let runtimeConfig = ContainerizationOCI.ImageConfig(labels: labels)
            let imageConfig = ContainerizationOCI.Image(architecture: platform.architecture, os: platform.os, config: runtimeConfig, rootfs: rootfsConfig)
            result = try writer.create(from: imageConfig)
            let configDescriptor = Descriptor(mediaType: ContainerizationOCI.MediaTypes.imageConfig, digest: result.digest.digestString, size: result.size)

            let manifest = Manifest(config: configDescriptor, layers: [layerDescriptor])
            result = try writer.create(from: manifest)
            let manifestDescriptor = Descriptor(mediaType: ContainerizationOCI.MediaTypes.imageManifest, digest: result.digest.digestString, size: result.size, platform: platform)

            let index = ContainerizationOCI.Index(manifests: [manifestDescriptor])
            result = try writer.create(from: index)

            let indexDescriptor = Descriptor(mediaType: ContainerizationOCI.MediaTypes.index, digest: result.digest.digestString, size: result.size)
            await indexDescriptorStore.set(indexDescriptor)

        }

        guard let indexDescriptor = await indexDescriptorStore.get() else {
            throw ContainerizationError(.notFound, message: "image for \(reference) not found")
        }

        let description = Image.Description(reference: reference, descriptor: indexDescriptor)
        let image = try await imageStore.create(description: description)
        return InitImage(image: image)
    }
}
