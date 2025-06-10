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
import Crypto
import Foundation
import Testing

@testable import Containerization

@Suite
final class InitImageTests {
    @Test func testDiffIDMatchesUncompressedLayer() async throws {
        let fm = FileManager.default
        let tempDir = fm.uniqueTemporaryDirectory(create: true)
        defer { try? fm.removeItem(at: tempDir) }

        // create a simple gzipped rootfs archive
        let rootfs = tempDir.appendingPathComponent("rootfs.tar.gz")
        let writer = try ArchiveWriter(format: .paxRestricted, filter: .gzip, file: rootfs)
        let entry = WriteEntry()
        entry.fileType = .regular
        entry.path = "hello.txt"
        let data = "hello".data(using: .utf8)!
        entry.size = Int64(data.count)
        try writer.writeEntry(entry: entry, data: data)
        try writer.finishEncoding()

        // compute expected diffID
        let uncompressed = tempDir.appendingPathComponent("layer.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", rootfs.path]
        fm.createFile(atPath: uncompressed.path, contents: nil)
        let out = try FileHandle(forWritingTo: uncompressed)
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        try out.close()
        let diffData = try Data(contentsOf: uncompressed)
        let expectedDiffID = SHA256.hash(data: diffData).digestString

        // create image store
        let storeDir = fm.uniqueTemporaryDirectory(create: true)
        defer { try? fm.removeItem(at: storeDir) }
        let contentStore = try LocalContentStore(path: storeDir)
        let imageStore = try ImageStore(path: storeDir, contentStore: contentStore)

        let platform = Platform(arch: "amd64", os: "linux")
        let initImage = try await InitImage.create(
            reference: "test:init",
            rootfs: rootfs,
            platform: platform,
            imageStore: imageStore,
            contentStore: contentStore
        )

        let config = try await initImage.image.config(for: platform)
        #expect(config.rootfs.diffIDs.first == expectedDiffID)
    }
}
