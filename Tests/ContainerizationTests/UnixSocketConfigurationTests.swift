import Foundation
import SystemPackage
import Testing

@testable import Containerization

struct UnixSocketConfigurationTests {
    @Test
    func deterministicIDs() {
        let src = URL(fileURLWithPath: "/tmp/source.sock")
        let dst = URL(fileURLWithPath: "/tmp/dest.sock")
        let perms = FilePermissions(rawValue: 0o644)
        let c1 = UnixSocketConfiguration(source: src, destination: dst, permissions: perms, direction: .into)
        let c2 = UnixSocketConfiguration(source: src, destination: dst, permissions: perms, direction: .into)
        #expect(c1.id == c2.id)

        var c3 = c1
        c3.destination = URL(fileURLWithPath: "/tmp/other.sock")
        #expect(c1.id != c3.id)

        let set: Set<UnixSocketConfiguration> = [c1, c2, c3]
        #expect(set.count == 2)
    }
}
