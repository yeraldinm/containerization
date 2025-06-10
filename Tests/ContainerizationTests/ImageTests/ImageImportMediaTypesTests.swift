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

import ContainerizationArchive
import ContainerizationOCI
import Foundation
import Testing

@testable import Containerization

@Suite
final class ImageImportMediaTypesTests {
    let store: ImageStore
    let dir: URL
    let contentStore: ContentStore

    init() throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        do {
            let cs = try LocalContentStore(path: dir)
            let store = try ImageStore(path: dir, contentStore: cs)
            self.dir = dir
            self.store = store
            self.contentStore = cs
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: self.dir)
    }

    @Test
    func testLoadWithNonDistributableLayer() async throws {
        let fm = FileManager.default
        let layoutDir = fm.uniqueTemporaryDirectory(create: true)
        defer { try? fm.removeItem(at: layoutDir) }

        let blobDir = layoutDir.appending(path: "blobs/sha256")
        try fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
        let writer = try ContentWriter(for: blobDir)

        let config = Image(
            architecture: "amd64",
            os: "linux",
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
        let configRes = try writer.create(from: config)
        let configDesc = Descriptor(
            mediaType: MediaTypes.imageConfig,
            digest: configRes.digest.digestString,
            size: Int64(configRes.size)
        )

        let layerData = Data("hello".utf8)
        let layerRes = try writer.write(layerData)
        let layerDesc = Descriptor(
            mediaType: MediaTypes.imageLayerNonDistributable,
            digest: layerRes.digest.digestString,
            size: Int64(layerRes.size)
        )

        let manifest = Manifest(config: configDesc, layers: [layerDesc])
        let manifestRes = try writer.create(from: manifest)
        var manifestDesc = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestRes.digest.digestString,
            size: Int64(manifestRes.size),
            platform: Platform(arch: "amd64", os: "linux")
        )

        let index = Index(manifests: [manifestDesc])
        let indexRes = try writer.create(from: index)
        var indexDesc = Descriptor(
            mediaType: MediaTypes.index,
            digest: indexRes.digest.digestString,
            size: Int64(indexRes.size)
        )

        let client = try LocalOCILayoutClient(root: layoutDir)
        client.setImageReferenceAnnotation(
            descriptor: &indexDesc,
            reference: "registry.local/integration-tests/non-dist:latest"
        )
        try client.createOCILayoutStructre(directory: layoutDir, manifests: [indexDesc])

        let images = try await store.load(from: layoutDir)
        #expect(images.count == 1)
        let layer = try await contentStore.get(digest: layerDesc.digest)
        #expect(layer != nil)
    }
}
