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
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Synchronization

/// `LinuxProcess` represents a Linux process and is used to
/// setup and control the full lifecycle for the process.
public final class LinuxProcess: Sendable {
    /// `IOHandler` informs the process about what should be done
    /// for the stdio streams.
    public struct IOHandler: Sendable {
        public var stdin: ReaderStream?
        public var stdout: Writer?
        public var stderr: Writer?

        public init(stdin: ReaderStream? = nil, stdout: Writer? = nil, stderr: Writer? = nil) {
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
        }

        public static func nullIO() -> IOHandler {
            .init()
        }
    }

    /// The ID of the process. This is purely metadata for the caller.
    public let id: String

    /// What container owns this process (if any).
    public let owningContainer: String?

    package struct StdioSetup: Sendable {
        let port: UInt32
        let writer: Writer
    }

    package struct StdioReaderSetup {
        let port: UInt32
        let reader: ReaderStream
    }

    package struct Stdio: Sendable {
        let stdin: StdioReaderSetup?
        let stdout: StdioSetup?
        let stderr: StdioSetup?
    }

    private struct StdioHandles: Sendable {
        var stdin: FileHandle?
        var stdout: FileHandle?
        var stderr: FileHandle?

        mutating func close() throws {
            if let stdin {
                try stdin.close()
                stdin.readabilityHandler = nil
                self.stdin = nil
            }
            if let stdout {
                try stdout.close()
                stdout.readabilityHandler = nil
                self.stdout = nil
            }
            if let stderr {
                try stderr.close()
                stderr.readabilityHandler = nil
                self.stderr = nil
            }
        }
    }

    private struct State {
        var spec: ContainerizationOCI.Spec
        var pid: Int32
        var stdio: StdioHandles
        var stdinRelay: Task<(), Never>?
    }

    /// The process ID for the container process. This will be -1
    /// if the process has not been started.
    public var pid: Int32 {
        state.withLock { $0.pid }
    }

    /// Arguments passed to the Process.
    public var arguments: [String] {
        get {
            state.withLock { $0.spec.process!.args }
        }
        set {
            state.withLock { $0.spec.process!.args = newValue }
        }
    }

    /// Environment variables for the Process.
    public var environment: [String] {
        get { state.withLock { $0.spec.process!.env } }
        set { state.withLock { $0.spec.process!.env = newValue } }
    }

    /// The current working directory (cwd) for the Process.
    public var workingDirectory: String {
        get { state.withLock { $0.spec.process!.cwd } }
        set { state.withLock { $0.spec.process!.cwd = newValue } }
    }

    /// A boolean value indicating if a Terminal or PTY device should
    /// be attached to the Process's Standard I/O.
    public var terminal: Bool {
        get { state.withLock { $0.spec.process!.terminal } }
        set { state.withLock { $0.spec.process!.terminal = newValue } }
    }

    /// The User a Process should execute under.
    public var user: ContainerizationOCI.User {
        get { state.withLock { $0.spec.process!.user } }
        set { state.withLock { $0.spec.process!.user = newValue } }
    }

    /// Rlimits for the Process.
    public var rlimits: [POSIXRlimit] {
        get { state.withLock { $0.spec.process!.rlimits } }
        set { state.withLock { $0.spec.process!.rlimits = newValue } }
    }

    private let state: Mutex<State>
    private let ioSetup: Stdio
    private let agent: any VirtualMachineAgent
    private let vm: any VirtualMachineInstance
    private let logger: Logger?

    init(
        _ id: String,
        containerID: String? = nil,
        spec: Spec,
        io: Stdio,
        agent: any VirtualMachineAgent,
        vm: any VirtualMachineInstance,
        logger: Logger?
    ) {
        self.id = id
        self.owningContainer = containerID
        self.state = Mutex<State>(.init(spec: spec, pid: -1, stdio: StdioHandles()))
        self.ioSetup = io
        self.agent = agent
        self.vm = vm
        self.logger = logger
    }
}

extension LinuxProcess {
    func setupIO(streams: [VsockConnectionStream?]) async throws -> [FileHandle?] {
        let handles = try await Timeout.run(seconds: 3) {
            await withTaskGroup(of: (Int, FileHandle?).self) { group in
                var results = [FileHandle?](repeating: nil, count: 3)

                for (index, stream) in streams.enumerated() {
                    guard let stream = stream else { continue }

                    group.addTask {
                        let first = await stream.connections.first(where: { _ in true })
                        return (index, first)
                    }
                }

                for await (index, fileHandle) in group {
                    results[index] = fileHandle
                }
                return results
            }
        }

        if let stdin = self.ioSetup.stdin {
            if let handle = handles[0] {
                self.state.withLock {
                    $0.stdinRelay = Task {
                        for await data in stdin.reader.stream() {
                            do {
                                try handle.write(contentsOf: data)
                            } catch {
                                self.logger?.error("failed to write to stdin: \(error)")
                                return
                            }
                        }
                    }
                }
            }
        }

        if let stdout = self.ioSetup.stdout {
            handles[1]?.readabilityHandler = { handle in
                // NOTE: We need some way to know when this data is done being piped,
                // so DispatchGroup or similar. `availableData` is also pretty poor,
                // as it always allocates. We can likely do the read loop ourselves
                // with a buffer we allocate once on creation of the process.
                do {
                    let data = handle.availableData
                    if data.isEmpty {
                        handles[1]?.readabilityHandler = nil
                        return
                    }
                    try stdout.writer.write(data)
                } catch {
                    self.logger?.error("failed to write to stdout: \(error)")
                }
            }
        }

        if let stderr = self.ioSetup.stderr {
            handles[2]?.readabilityHandler = { handle in
                do {
                    let data = handle.availableData
                    if data.isEmpty {
                        handles[2]?.readabilityHandler = nil
                        return
                    }
                    try stderr.writer.write(data)
                } catch {
                    self.logger?.error("failed to write to stderr: \(error)")
                }
            }
        }

        return handles
    }

    /// Start the process.
    public func start() async throws {
        let spec = self.state.withLock { $0.spec }

        var streams = [VsockConnectionStream?](repeating: nil, count: 3)
        if let stdin = self.ioSetup.stdin {
            streams[0] = try self.vm.listen(stdin.port)
        }
        if let stdout = self.ioSetup.stdout {
            streams[1] = try self.vm.listen(stdout.port)
        }
        if let stderr = self.ioSetup.stderr {
            if spec.process!.terminal {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "stderr should not be configured with terminal=true"
                )
            }
            streams[2] = try self.vm.listen(stderr.port)
        }

        let t = Task {
            try await self.setupIO(streams: streams)
        }

        try await agent.createProcess(
            id: self.id,
            containerID: self.owningContainer,
            stdinPort: self.ioSetup.stdin?.port,
            stdoutPort: self.ioSetup.stdout?.port,
            stderrPort: self.ioSetup.stderr?.port,
            configuration: spec,
            options: nil
        )

        let result = try await t.value
        let pid = try await self.agent.startProcess(
            id: self.id,
            containerID: self.owningContainer
        )

        self.state.withLock {
            $0.stdio = StdioHandles(
                stdin: result[0],
                stdout: result[1],
                stderr: result[2]
            )
            $0.pid = pid
        }
    }

    /// Kill the process with the specified signal.
    public func kill(_ signal: Int32) async throws {
        try await agent.signalProcess(
            id: self.id,
            containerID: self.owningContainer,
            signal: signal
        )
    }

    /// Resize the processes pty (if requested).
    public func resize(to: Terminal.Size) async throws {
        try await agent.resizeProcess(
            id: self.id,
            containerID: self.owningContainer,
            columns: UInt32(to.width),
            rows: UInt32(to.height)
        )
    }

    /// Wait on the process to exit with an optional timeout. Returns the exit code of the process.
    @discardableResult
    public func wait(timeoutInSeconds: Int64? = nil) async throws -> Int32 {
        do {
            return try await self.agent.waitProcess(
                id: self.id,
                containerID: self.owningContainer,
                timeoutInSeconds: timeoutInSeconds
            )
        } catch {
            if error is ContainerizationError {
                throw error
            }
            throw ContainerizationError(
                .internalError,
                message: "failed to wait on process",
                cause: error
            )
        }
    }

    /// Cleans up guest state and waits on and closes any host resources (stdio handles).
    public func delete() async throws {
        try await self.agent.deleteProcess(
            id: self.id,
            containerID: self.owningContainer
        )

        // Give any pending stdout/stderr data time to be delivered. We poll the
        // file handles for up to two seconds so that leftover output can be
        // consumed before we close them.
        await self.drainIO(timeoutSeconds: 2)

        // Now free up stdio handles.
        try self.state.withLock {
            $0.stdinRelay?.cancel()
            try $0.stdio.close()
        }

        // Finally, close our agent conn.
        try await self.agent.close()
    }

    /// Drain any remaining stdout/stderr data until no more is available or the
    /// timeout has been reached.
private func drainIO(timeoutSeconds: Int) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds) * 1_000_000_000

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let hasData = self.state.withLock { state -> Bool in
                var consumed = false
                if let stdout = state.stdio.stdout, let outWriter = self.ioSetup.stdout?.writer {
                    let data = stdout.availableData
                    if !data.isEmpty {
                        try? outWriter.write(data)
                        consumed = true
                    }
                }
                if let stderr = state.stdio.stderr, let errWriter = self.ioSetup.stderr?.writer {
                    let data = stderr.availableData
                    if !data.isEmpty {
                        try? errWriter.write(data)
                        consumed = true
                    }
                }
                return consumed
            }

            if !hasData {
                break
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    package func testSetStdioHandles(stdout: FileHandle?, stderr: FileHandle?) {
        self.state.withLock { state in
            state.stdio = StdioHandles(stdin: nil, stdout: stdout, stderr: stderr)

            if let stdout = stdout, let stdoutSetup = self.ioSetup.stdout {
                stdout.readabilityHandler = { handle in
                    do {
                        let data = handle.availableData
                        if data.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        try stdoutSetup.writer.write(data)
                    } catch {
                        self.logger?.error("failed to write to stdout: \(error)")
                    }
                }
            }

            if let stderr = stderr, let stderrSetup = self.ioSetup.stderr {
                stderr.readabilityHandler = { handle in
                    do {
                        let data = handle.availableData
                        if data.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        try stderrSetup.writer.write(data)
                    } catch {
                        self.logger?.error("failed to write to stderr: \(error)")
                    }
                }
            }
        }
    }
}
