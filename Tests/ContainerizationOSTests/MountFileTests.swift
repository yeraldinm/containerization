//===----------------------------------------------------------------------===//
// Copyright © none Apple Inc. and the Containerization project authors.
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

import Foundation
import Testing

#if canImport(Musl)
import Musl
private let _mount = Musl.mount
private let _umount = Musl.umount2
#elseif canImport(Glibc)
import Glibc
private let _mount = Glibc.mount
private let _umount = Glibc.umount2
#endif

@Suite("Mount single file")
struct MountFileTests {
    @Test(.disabled("Requires mount permissions"))
    func mountSingleFile() throws {
        #if os(Linux)
        let fm = FileManager.default
        let srcDir = fm.uniqueTemporaryDirectory()
        defer { try? fm.removeItem(at: srcDir) }
        let src = srcDir.appendingPathComponent("src.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)

        let dstDir = fm.uniqueTemporaryDirectory()
        defer { try? fm.removeItem(at: dstDir) }
        let dst = dstDir.appendingPathComponent("dst.txt")
        fm.createFile(atPath: dst.path, contents: nil)

        guard _mount(src.path, dst.path, "bind", UInt(MS_BIND), nil) == 0 else {
            throw POSIXError.fromErrno()
        }
        defer { _ = _umount(dst.path, 0) }

        let contents = try String(contentsOf: dst)
        #expect(contents == "hello")
        #endif
    }
}
