import Foundation

/// `QVACClient` is the native Swift entry point for talking to a QVAC Bare worker.
///
/// The full surface (loadModel, completion, embed, transcribe, …) is generated from
/// the upstream `@qvac/sdk` TypeScript declarations and lands across milestones M1–M3.
/// At YK-174 the type exists only to validate the package layout and serve as the
/// anchor that codegen will extend.
public actor QVACClient {
  public init() {}
}
