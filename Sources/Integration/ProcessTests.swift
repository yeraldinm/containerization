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

import ArgumentParser
import Containerization
import ContainerizationOCI
import Foundation
import Logging

extension IntegrationSuite {
    func testProcessTrue() async throws {
        let id = "test-process-true"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/true"]

        try await container.create()
        try await container.start()
        guard container.pid > 0 else {
            throw IntegrationError.assert(msg: "invalid pid \(container.pid)")
        }

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
    }

    func testProcessFalse() async throws {
        let id = "test-process-false"

        let bs = try await bootstrap()
        let container = LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm)
        container.arguments = ["/bin/false"]

        try await container.create()
        try await container.start()
        guard container.pid > 0 else {
            throw IntegrationError.assert(msg: "invalid pid \(container.pid)")
        }

        let status = try await container.wait()
        try await container.stop()

        guard status == 1 else {
            throw IntegrationError.assert(msg: "process status \(status) != 1")
        }
    }

    final class BufferWriter: Writer {
        nonisolated(unsafe) var data = Data()

        func write(_ data: Data) throws {
            guard data.count > 0 else {
                return
            }
            self.data.append(data)
        }
    }

    func testProcessEchoHi() async throws {
        let id = "test-process-echo-hi"
        let bs = try await bootstrap()
        let container = LinuxContainer(id, rootfs: bs.rootfs, vmm: bs.vmm)
        container.arguments = ["/bin/echo", "hi"]

        let buffer = BufferWriter()
        container.stdout = buffer

        do {
            try await container.create()
            try await container.start()
            guard container.pid > 0 else {
                throw IntegrationError.assert(msg: "invalid pid \(container.pid)")
            }
            guard container.pid > 0 else {
                throw IntegrationError.assert(msg: "invalid pid \(container.pid)")
            }

            let status = try await container.wait()
            try await container.stop()

            guard status == 0 else {
                throw IntegrationError.assert(msg: "process status \(status) != 1")
            }

            guard String(data: buffer.data, encoding: .utf8) == "hi\n" else {
                throw IntegrationError.assert(
                    msg: "process should have returned on stdout 'hi' != '\(String(data: buffer.data, encoding: .utf8)!)")
            }
        } catch {
            try? await container.stop()
            throw error
        }
    }

    func testMultipleConcurrentProcesses() async throws {
        let id = "test-concurrent-processes"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/sleep", "1000"]

        do {
            try await container.create()
            try await container.start()
            guard container.pid > 0 else {
                throw IntegrationError.assert(msg: "invalid pid \(container.pid)")
            }

            let execConfig = ContainerizationOCI.Process(
                args: ["/bin/true"],
                env: ["PATH=\(LinuxContainer.defaultPath)"]
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0...80 {
                    let exec = try await container.exec(
                        "exec-\(i)",
                        configuration: execConfig
                    )

                    group.addTask {
                        try await exec.start()
                        guard exec.pid > 0 else {
                            throw IntegrationError.assert(msg: "invalid pid \(exec.pid)")
                        }
                        let status = try await exec.wait()
                        if status != 0 {
                            throw IntegrationError.assert(msg: "process status \(status) != 0")
                        }
                        try await exec.delete()
                    }
                }

                // wait for all the exec'd processes.
                try await group.waitForAll()
                print("all group processes exit")

                // kill the init process.
                try await container.kill(SIGKILL)
                let status = try await container.wait()
                try await container.stop()
                print("\(status)")
            }
        } catch {
            throw error
        }
    }

    func testMultipleConcurrentProcessesOutput() async throws {
        let id = "test-concurrent-processes-output"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/sleep", "1000"]

        do {
            try await container.create()
            try await container.start()

            let execConfig = ContainerizationOCI.Process(
                args: ["/bin/echo", "hi"],
                env: ["PATH=\(LinuxContainer.defaultPath)"]
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0...80 {
                    let idx = i
                    group.addTask {
                        let buffer = BufferWriter()

                        var config = execConfig
                        config.args[1] = "hi\(idx)"

                        let exec = try await container.exec(
                            "exec-\(idx)",
                            configuration: config,
                            stdout: buffer,
                        )
                        try await exec.start()
                        guard exec.pid > 0 else {
                            throw IntegrationError.assert(msg: "invalid pid \(exec.pid)")
                        }

                        let status = try await exec.wait()
                        if status != 0 {
                            throw IntegrationError.assert(msg: "process status \(status) != 0")
                        }

                        let output = String(data: buffer.data, encoding: .utf8)
                        guard output == "hi\(idx)\n" else {
                            throw IntegrationError.assert(
                                msg: "process should have returned on stdout 'hi\(idx)' != '\(output!))")
                        }
                        try await exec.delete()
                    }
                }

                // wait for all the exec'd processes.
                try await group.waitForAll()
                print("all group processes exit")

                // kill the init process.
                try await container.kill(SIGKILL)
                let status = try await container.wait()
                try await container.stop()
                print("\(status)")
            }
        } catch {
            throw error
        }
    }

    func testProcessUser() async throws {
        let id = "test-process-user"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/usr/bin/id"]
        container.user = .init(uid: 1, gid: 1, additionalGids: [1])

        let buffer = BufferWriter()
        container.stdout = buffer

        try await container.create()
        try await container.start()
        guard container.pid > 0 else {
            throw IntegrationError.assert(msg: "invalid pid \(container.pid)")
        }

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        let expected = "uid=1(bin) gid=1(bin) groups=1(bin)"

        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)")
        }
    }

    func testHostname() async throws {
        let id = "test-container-hostname"

        let bs = try await bootstrap()
        let container = LinuxContainer(
            id,
            rootfs: bs.rootfs,
            vmm: bs.vmm
        )
        container.arguments = ["/bin/hostname"]
        container.hostname = "foo-bar"

        let buffer = BufferWriter()
        container.stdout = buffer

        try await container.create()
        try await container.start()
        guard container.pid > 0 else {
            throw IntegrationError.assert(msg: "invalid pid \(container.pid)")
        }

        let status = try await container.wait()
        try await container.stop()

        guard status == 0 else {
            throw IntegrationError.assert(msg: "process status \(status) != 0")
        }
        let expected = "foo-bar"

        guard String(data: buffer.data, encoding: .utf8) == "\(expected)\n" else {
            throw IntegrationError.assert(
                msg: "process should have returned on stdout '\(expected)' != '\(String(data: buffer.data, encoding: .utf8)!)")
        }
    }
}
