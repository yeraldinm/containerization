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

import Containerization
import ContainerizationError
import ContainerizationNetlink
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPC
import Logging
import NIOCore
import NIOPosix
import _NIOFileSystem

private let _setenv = Foundation.setenv

#if canImport(Musl)
import Musl
private let _mount = Musl.mount
private let _umount = Musl.umount2
private let _kill = Musl.kill
private let _sync = Musl.sync
#elseif canImport(Glibc)
import Glibc
private let _mount = Glibc.mount
private let _umount = Glibc.umount2
private let _kill = Glibc.kill
private let _sync = Glibc.sync
#endif

extension Initd: Com_Apple_Containerization_Sandbox_V3_SandboxContextAsyncProvider {
    func setTime(
        request: Com_Apple_Containerization_Sandbox_V3_SetTimeRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SetTimeResponse {
        log.debug(
            "setTime",
            metadata: [
                "sec": "\(request.sec)",
                "usec": "\(request.usec)",
            ])

        var tv = timeval(tv_sec: time_t(request.sec), tv_usec: suseconds_t(request.usec))
        guard settimeofday(&tv, nil) == 0 else {
            let error = swiftErrno("settimeofday")
            log.error(
                "setTime",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "failed to settimeofday: \(error)")
        }

        return .init()
    }

    func setupEmulator(
        request: Com_Apple_Containerization_Sandbox_V3_SetupEmulatorRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SetupEmulatorResponse {
        log.debug(
            "setupEmulator",
            metadata: [
                "request": "\(request)"
            ])

        if !Binfmt.mounted() {
            throw GRPCStatus(
                code: .internalError,
                message: "\(Binfmt.path) is not mounted"
            )
        }

        do {
            let bfmt = Binfmt.Entry(
                name: request.name,
                type: request.type,
                offset: request.offset,
                magic: request.magic,
                mask: request.mask,
                flags: request.flags
            )
            try bfmt.register(binaryPath: request.binaryPath)
        } catch {
            log.error(
                "setupEmulator",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "setupEmulator: failed to register binfmt_misc entry: \(error)"
            )
        }

        return .init()
    }

    func sysctl(
        request: Com_Apple_Containerization_Sandbox_V3_SysctlRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SysctlResponse {
        log.debug(
            "sysctl",
            metadata: [
                "settings": "\(request.settings)"
            ])

        do {
            let sysctlPath = URL(fileURLWithPath: "/proc/sys/")
            for (k, v) in request.settings {
                guard let data = v.data(using: .ascii) else {
                    throw GRPCStatus(code: .internalError, message: "failed to convert \(v) to data buffer for sysctl write")
                }

                let setting =
                    sysctlPath
                    .appendingPathComponent(k.replacingOccurrences(of: ".", with: "/"))
                let fh = try FileHandle(forWritingTo: setting)
                defer { try? fh.close() }

                try fh.write(contentsOf: data)
            }
        } catch {
            log.error(
                "deleteProcess",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "sysctl: failed to set sysctl: \(error)"
            )
        }

        return .init()
    }

    func proxyVsock(
        request: Com_Apple_Containerization_Sandbox_V3_ProxyVsockRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ProxyVsockResponse {
        log.debug(
            "proxy vsock",
            metadata: [
                "id": "\(request.id)",
                "port": "\(request.vsockPort)",
                "guestPath": "\(request.guestPath)",
                "action": "\(request.action)",
            ])

        do {
            let proxy = VsockProxy(
                id: request.id,
                action: request.action == .into ? .dial : .listen,
                port: request.vsockPort,
                path: URL(fileURLWithPath: request.guestPath),
                udsPerms: request.guestSocketPermissions,
                log: log
            )

            try proxy.start()
            try await state.add(proxy: proxy)
        } catch {
            log.error(
                "proxyVsock",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "proxyVsock: failed to setup vsock proxy: \(error)"
            )
        }

        return .init()
    }

    func stopVsockProxy(
        request: Com_Apple_Containerization_Sandbox_V3_StopVsockProxyRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_StopVsockProxyResponse {
        log.debug(
            "stop vsock proxy",
            metadata: [
                "id": "\(request.id)"
            ])

        do {
            let proxy = try await state.remove(proxy: request.id)
            try proxy.close()
        } catch {
            log.error(
                "stopVsockProxy",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "stopVsockProxy: failed to stop vsock proxy: \(error)"
            )
        }

        return .init()
    }

    func mkdir(request: Com_Apple_Containerization_Sandbox_V3_MkdirRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_MkdirResponse
    {
        log.debug(
            "mkdir",
            metadata: [
                "path": "\(request.path)",
                "all": "\(request.all)",
            ])

        do {
            try FileManager.default.createDirectory(
                atPath: request.path,
                withIntermediateDirectories: request.all
            )
        } catch {
            log.error(
                "mkdir",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "mkdir: \(error)")
        }

        return .init()
    }

    func mount(request: Com_Apple_Containerization_Sandbox_V3_MountRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_MountResponse
    {
        log.debug(
            "mount",
            metadata: [
                "type": "\(request.type)",
                "source": "\(request.source)",
                "destination": "\(request.destination)",
            ])

        do {
            // FIXME: Handle single file mounts.
            let mnt = ContainerizationOS.Mount(
                type: request.type,
                source: request.source,
                target: request.destination,
                options: request.options
            )

            #if os(Linux)
            try mnt.mount(createWithPerms: 0o755)
            return .init()
            #else
            fatalError("mount not supported on platform")
            #endif
        } catch {
            log.error(
                "mount",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "mount: \(error)")
        }
    }

    func umount(request: Com_Apple_Containerization_Sandbox_V3_UmountRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_UmountResponse
    {
        log.debug(
            "unmount",
            metadata: [
                "path": "\(request.path)",
                "flags": "\(request.flags)",
            ])

        #if os(Linux)
        // Best effort EBUSY handle.
        for _ in 0...50 {
            let result = _umount(request.path, request.flags)
            if result == -1 {
                if errno == EBUSY {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                let error = swiftErrno("umount")

                log.error(
                    "unmount",
                    metadata: [
                        "error": "\(error)"
                    ])
                throw GRPCStatus(code: .invalidArgument, message: "umount: \(error)")
            }
            break
        }
        return .init()
        #else
        fatalError("unmount not supported on platform")
        #endif
    }

    func setenv(request: Com_Apple_Containerization_Sandbox_V3_SetenvRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_SetenvResponse
    {
        log.debug(
            "setenv",
            metadata: [
                "key": "\(request.key)",
                "value": "\(request.value)",
            ])

        guard _setenv(request.key, request.value, 1) == 0 else {
            let error = swiftErrno("setenv")

            log.error(
                "setEnv",
                metadata: [
                    "error": "\(error)"
                ])

            throw GRPCStatus(code: .invalidArgument, message: "setenv: \(error)")
        }
        return .init()
    }

    func getenv(request: Com_Apple_Containerization_Sandbox_V3_GetenvRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_GetenvResponse
    {
        log.debug(
            "getenv",
            metadata: [
                "key": "\(request.key)"
            ])

        let env = ProcessInfo.processInfo.environment[request.key]
        return .with {
            if let env {
                $0.value = env
            }
        }
    }

    func createProcess(
        request: Com_Apple_Containerization_Sandbox_V3_CreateProcessRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_CreateProcessResponse {
        log.debug(
            "create process",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
                "stdin": "Port: \(request.stdin)",
                "stdout": "Port: \(request.stdout)",
                "stderr": "Port: \(request.stderr)",
            ])

        if !request.hasContainerID {
            fatalError("processes in the root of the vm not implemented")
        }

        do {
            var ociSpec = try JSONDecoder().decode(
                ContainerizationOCI.Spec.self,
                from: request.configuration
            )

            try ociAlterations(ociSpec: &ociSpec)

            guard let process = ociSpec.process else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "oci runtime spec missing process configuration"
                )
            }

            let stdioPorts = HostStdio(
                stdin: request.hasStdin ? request.stdin : nil,
                stdout: request.hasStdout ? request.stdout : nil,
                stderr: request.hasStderr ? request.stderr : nil,
                terminal: process.terminal
            )

            // This is an exec.
            if let container = await self.state.containers[request.containerID] {
                try await container.createExec(
                    id: request.id,
                    stdio: stdioPorts,
                    process: process
                )
            } else {
                // We need to make our new fangled container.
                // The process ID must match the container ID for this.
                guard request.id == request.containerID else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "init process id must match container id"
                    )
                }

                // Write the etc/hostname file in the container rootfs since some init-systems
                // depend on it.
                let hostname = ociSpec.hostname
                if let root = ociSpec.root, !hostname.isEmpty {
                    let etc = URL(fileURLWithPath: root.path).appendingPathComponent("etc")
                    try FileManager.default.createDirectory(atPath: etc.path, withIntermediateDirectories: true)
                    let hostnamePath = etc.appendingPathComponent("hostname")
                    try hostname.write(toFile: hostnamePath.path, atomically: true, encoding: .utf8)
                }

                let ctr = try ManagedContainer(
                    id: request.id,
                    stdio: stdioPorts,
                    spec: ociSpec,
                    log: self.log
                )
                try await self.state.add(container: ctr)
            }

            return .init()
        } catch {
            log.error(
                "create managed process",
                metadata: [
                    "error": "\(error)"
                ])
            if error is GRPCStatus {
                throw error
            }
            throw GRPCStatus(code: .internalError, message: "create managed process: \(error)")
        }
    }

    func killProcess(
        request: Com_Apple_Containerization_Sandbox_V3_KillProcessRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_KillProcessResponse {
        log.debug(
            "kill process",
            metadata: [
                "id": "\(request.id)",
                "signal": "\(request.signal)",
            ])

        if !request.hasContainerID {
            fatalError("processes in the root of the vm not implemented")
        }

        let ctr = try await self.state.get(container: request.containerID)

        if request.id == request.containerID {
            try await ctr.kill(request.signal)
        } else {
            let proc = try await ctr.getExec(id: request.id)
            try proc.kill(request.signal)
        }

        log.debug(
            "kill process result",
            metadata: [
                "id": "\(request.id)",
                "signal": "\(request.signal)",
            ])

        return .init()
    }

    func deleteProcess(
        request: Com_Apple_Containerization_Sandbox_V3_DeleteProcessRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_DeleteProcessResponse {
        log.debug("delete process on port \(request.id)")

        if !request.hasContainerID {
            fatalError("processes in the root of the vm not implemented")
        }

        let ctr = try await self.state.get(container: request.containerID)

        // Are we trying to delete the container itself?
        if request.id == request.containerID {
            try await ctr.delete()
            try await state.remove(container: request.id)
        } else {
            // Or just a single exec.
            try await ctr.deleteExec(id: request.id)
        }

        return .init()
    }

    func startProcess(
        request: Com_Apple_Containerization_Sandbox_V3_StartProcessRequest, context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_StartProcessResponse {
        log.debug("starting process \(request.id)")

        if !request.hasContainerID {
            fatalError("processes in the root of the vm not implemented")
        }

        do {
            let ctr = try await self.state.get(container: request.containerID)
            let pid = try await ctr.startProcess(id: request.id)
            return .with { $0.pid = pid }
        } catch {
            log.error(
                "startProcess",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "startProcess: failed to start process: \(error)"
            )
        }
    }

    func resizeProcess(
        request: Com_Apple_Containerization_Sandbox_V3_ResizeProcessRequest, context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ResizeProcessResponse {
        log.debug("resizing process pty \(request.id)")

        if !request.hasContainerID {
            fatalError("processes in the root of the vm not implemented")
        }

        do {
            let ctr = try await self.state.get(container: request.containerID)

            let size = Terminal.Size(width: UInt16(request.columns), height: UInt16(request.rows))
            if request.id == request.containerID {
                try await ctr.resize(size: size)
            } else {
                let proc = try await ctr.getExec(id: request.id)
                try proc.resize(size: size)
            }
        } catch {
            log.error(
                "resizeProcess",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "resizeProcess: failed to resize process: \(error)"
            )
        }

        return .init()
    }

    func waitProcess(
        request: Com_Apple_Containerization_Sandbox_V3_WaitProcessRequest, context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_WaitProcessResponse {
        log.debug("waiting on process \(request.id)")

        if !request.hasContainerID {
            fatalError("processes in the root of the vm not implemented")
        }

        do {
            let ctr = try await self.state.get(container: request.containerID)

            let exitCode: Int32
            if request.id == request.containerID {
                exitCode = await ctr.wait()
            } else {
                let proc = try await ctr.getExec(id: request.id)
                exitCode = await proc.wait()
            }

            return .with {
                $0.exitCode = exitCode
            }
        } catch {
            log.error(
                "waitProcess",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "waitProcess: failed to wait on process: \(error)"
            )
        }
    }

    func ipLinkSet(
        request: Com_Apple_Containerization_Sandbox_V3_IpLinkSetRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpLinkSetResponse {
        log.debug(
            "ip-link-set",
            metadata: [
                "interface": "\(request.interface)",
                "up": "\(request.up)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            try session.linkSet(interface: request.interface, up: request.up)
        } catch {
            log.error(
                "ip-link-set",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "ip-link-set: \(error)")
        }

        return .init()
    }

    func ipAddrAdd(
        request: Com_Apple_Containerization_Sandbox_V3_IpAddrAddRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpAddrAddResponse {
        log.debug(
            "ip-addr-add",
            metadata: [
                "interface": "\(request.interface)",
                "addr": "\(request.address)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            try session.addressAdd(interface: request.interface, address: request.address)
        } catch {
            log.error(
                "ip-addr-add",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "ip-addr-add: \(error)")
        }

        return .init()
    }

    func ipRouteAddLink(
        request: Com_Apple_Containerization_Sandbox_V3_IpRouteAddLinkRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpRouteAddLinkResponse {
        log.debug(
            "ip-route-add-link",
            metadata: [
                "interface": "\(request.interface)",
                "address": "\(request.address)",
                "srcAddr": "\(request.srcAddr)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            try session.routeAdd(
                interface: request.interface,
                destinationAddress: request.address,
                srcAddr: request.srcAddr
            )
        } catch {
            log.error(
                "ip-route-add-link",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "ip-route-add-link: \(error)")
        }

        return .init()
    }

    func ipRouteAddDefault(
        request: Com_Apple_Containerization_Sandbox_V3_IpRouteAddDefaultRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpRouteAddDefaultResponse {
        log.debug(
            "ip-route-add-default",
            metadata: [
                "interface": "\(request.interface)",
                "gateway": "\(request.gateway)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            try session.routeAddDefault(interface: request.interface, gateway: request.gateway)
        } catch {
            log.error(
                "ip-route-add-default",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "ip-route-add-default: \(error)")
        }

        return .init()
    }

    func configureDns(
        request: Com_Apple_Containerization_Sandbox_V3_ConfigureDnsRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ConfigureDnsResponse {
        let domain = request.hasDomain ? request.domain : nil
        log.debug(
            "configure-dns",
            metadata: [
                "location": "\(request.location)",
                "nameservers": "\(request.nameservers)",
                "domain": "\(domain ?? "")",
            ])

        do {
            let etc = URL(fileURLWithPath: request.location).appendingPathComponent("etc")
            try FileManager.default.createDirectory(atPath: etc.path, withIntermediateDirectories: true)
            let resolvConf = etc.appendingPathComponent("resolv.conf")
            let config = DNS(
                nameservers: request.nameservers,
                domain: domain,
                searchDomains: request.searchDomains,
                options: request.options
            )
            let text = config.resolvConf
            log.debug("writing to path \(resolvConf.path) \(text)")
            try text.write(toFile: resolvConf.path, atomically: true, encoding: .utf8)
            log.debug("wrote resolver configuration", metadata: ["path": "\(resolvConf.path)"])
        } catch {
            log.error(
                "configure-dns",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "configure-dns: \(error)")
        }

        return .init()
    }

    private func swiftErrno(_ msg: Logger.Message) -> POSIXError {
        let error = POSIXError(.init(rawValue: errno)!)
        log.error(
            msg,
            metadata: [
                "error": "\(error)"
            ])
        return error
    }

    func sync(
        request: Com_Apple_Containerization_Sandbox_V3_SyncRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SyncResponse {
        log.debug("sync")

        _sync()
        return .init()
    }

    func kill(
        request: Com_Apple_Containerization_Sandbox_V3_KillRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_KillResponse {
        log.debug(
            "kill",
            metadata: [
                "pid": "\(request.pid)",
                "signal": "\(request.signal)",
            ])

        let r = _kill(request.pid, request.signal)
        return .with {
            $0.result = r
        }
    }
}

extension Initd {
    func ociAlterations(ociSpec: inout ContainerizationOCI.Spec) throws {
        guard var process = ociSpec.process else {
            throw ContainerizationError(.invalidArgument, message: "runtime spec without process field present")
        }
        guard let root = ociSpec.root else {
            throw ContainerizationError(.invalidArgument, message: "runtime spec without root field present")
        }

        try FileManager.default.createDirectory(
            atPath: root.path,
            withIntermediateDirectories: true
        )

        if process.cwd.isEmpty {
            process.cwd = "/"
        }

        // This is truthfully a Windows field, but it's fairly common for vm runtimes
        // to fill this in as a way to defer username lookup until we hit the guest.
        let username = process.user.username
        if !username.isEmpty {
            let parsedUser = try User.parseUser(root: root.path, userString: username)
            process.user.uid = parsedUser.uid
            process.user.gid = parsedUser.gid
            process.user.additionalGids.append(contentsOf: parsedUser.sgids)
            if !process.env.contains("HOME") {
                process.env.append("HOME=\(parsedUser.home)")
            }
        }
        ociSpec.process = process
    }
}
