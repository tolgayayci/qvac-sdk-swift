import BareRPC
import Foundation

/// References each external module that `QVACClient` links against, so a
/// missing dependency surfaces at compile time rather than only when an
/// `import` happens to fire in a consumer file.
///
/// `BareKit` is intentionally not linked in M1 — it requires a separate
/// native framework and lands as a real dependency in YK-206 alongside
/// `BareKitIPCTransport`. The Package.swift pins its version so M1 has
/// a stable reference point.
internal enum DependencyProbe {
  /// Touch a type from `BareRPC` so the linker doesn't dead-strip the
  /// import. Used as the smallest possible compile-time anchor.
  static let bareRPC: BareRPC.RPC.Type = BareRPC.RPC.self
}
