# ContainerizationOS Utilities

`ContainerizationOS` bundles a collection of low level helpers for interacting with the operating system. These types simplify common tasks needed when running containerized workloads on macOS and Linux.

## Available utilities

- **Mount** – represent and perform Linux style mounts. Useful for mounting filesystems or block devices. ([source](./Mount/Mount.swift))
- **Path** – query the current `PATH` and locate executables. ([source](./Path.swift))
- **Command** – spawn and control child processes. ([source](./Command.swift))

Other helpers include wrappers for signals, keychain access, sockets and files. Browse the `Sources/ContainerizationOS` directory for the full set of utilities.

## Examples

### Mounting a tmpfs directory
```swift
let mount = Mount(type: "tmpfs", source: "tmpfs", target: "/tmp/container", options: ["size=64m"])
try mount.mount(createWithPerms: 0o755)
```

### Running a command
```swift
var cmd = Command("/bin/echo", arguments: ["hello"])
try cmd.start()
let status = try cmd.wait()
print("exit status: \(status)")
```

### Looking up a binary
```swift
if let swiftPath = Path.lookPath("swift") {
    print("Swift found at \(swiftPath.path)")
}
```

For more usage information see the linked source files above.

