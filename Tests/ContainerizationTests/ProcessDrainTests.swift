//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// Licensed under the Apache License, Version 2.0
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import Containerization

final class ProcessDrainTests {
    final class BufferWriter: Writer {
        var data = Data()
        func write(_ data: Data) throws {
            self.data.append(data)
        }
    }

    final class DummyAgent: VirtualMachineAgent {
        var deleteCalled = false
        var closeCalled = false
        let outPipe: FileHandle

        init(outPipe: FileHandle) {
            self.outPipe = outPipe
        }

        func standardSetup() async throws {}
        func close() async throws { closeCalled = true }
        func getenv(key: String) async throws -> String { "" }
        func setenv(key: String, value: String) async throws {}
        func mount(_ mount: ContainerizationOCI.Mount) async throws {}
        func umount(path: String, flags: Int32) async throws {}
        func mkdir(path: String, all: Bool, perms: UInt32) async throws {}
        func kill(pid: Int32, signal: Int32) async throws -> Int32 { 0 }
        func createProcess(id: String, containerID: String?, stdinPort: UInt32?, stdoutPort: UInt32?, stderrPort: UInt32?, configuration: ContainerizationOCI.Spec, options: Data?) async throws {}
        func startProcess(id: String, containerID: String?) async throws -> Int32 { 0 }
        func signalProcess(id: String, containerID: String?, signal: Int32) async throws {}
        func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws {}
        func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> Int32 { 0 }
        func deleteProcess(id: String, containerID: String?) async throws {
            deleteCalled = true
            // Emit leftover output shortly after deletion
            Task.detached {
                try? await Task.sleep(nanoseconds: 100_000_000)
                try? self.outPipe.write(contentsOf: Data("leftover".utf8))
                try? self.outPipe.close()
            }
        }
        func up(name: String) async throws {}
        func down(name: String) async throws {}
        func addressAdd(name: String, address: String) async throws {}
        func routeAddDefault(name: String, gateway: String) async throws {}
        func configureDNS(config: DNS, location: String) async throws {}
    }

    struct DummyVM: VirtualMachineInstance {
        typealias Agent = DummyAgent
        var state: VirtualMachineInstanceState = .running
        var mounts: [AttachedFilesystem] = []
        func dialAgent() async throws -> DummyAgent { fatalError() }
        func dial(_ port: UInt32) async throws -> FileHandle { fatalError() }
        func listen(_ port: UInt32) throws -> VsockConnectionStream { fatalError() }
        func stopListen(_ port: UInt32) throws {}
        func start() async throws {}
        func stop() async throws {}
    }

    @Test
    func testDeleteDrainsOutput() async throws {
        let writer = BufferWriter()
        let pipe = Pipe()
        let agent = DummyAgent(outPipe: pipe.fileHandleForWriting)
        let vm = DummyVM()
        let spec = ContainerizationOCI.Spec(process: .init())
        let io = LinuxProcess.Stdio(stdin: nil, stdout: .init(port: 0, writer: writer), stderr: nil)
        let process = LinuxProcess("p", spec: spec, io: io, agent: agent, vm: vm, logger: nil)
        process.testSetStdioHandles(stdout: pipe.fileHandleForReading, stderr: nil)

        try await process.delete()

        #expect(String(data: writer.data, encoding: .utf8) == "leftover")
        #expect(agent.deleteCalled)
        #expect(agent.closeCalled)
    }
}
