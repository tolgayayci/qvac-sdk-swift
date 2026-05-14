import Foundation

// MARK: - Diffusion

/// One step in a streaming diffusion. The worker typically emits
/// many `.progress(step, totalSteps)` updates (one per denoising
/// iteration) and a terminal `.completed(image)` carrying the final
/// PNG / JPEG bytes. Some models also emit `.preview(image)`
/// snapshots mid-generation.
public enum DiffusionStep: Sendable, Equatable {
  case progress(step: Int, totalSteps: Int)
  case preview(image: Data)
  case completed(image: Data)
}

/// Generation knobs for `diffusion`. Free-form `extras` carries
/// model-specific options (e.g. Stable Diffusion `cfgScale`,
/// `samplerName`).
public struct DiffusionOptions: Sendable, Codable, Equatable {
  public var width: Int?
  public var height: Int?
  public var steps: Int?
  public var seed: UInt64?
  public var negativePrompt: String?
  public var extras: [String: AnyCodable]?

  public init(
    width: Int? = nil,
    height: Int? = nil,
    steps: Int? = nil,
    seed: UInt64? = nil,
    negativePrompt: String? = nil,
    extras: [String: AnyCodable]? = nil
  ) {
    self.width = width
    self.height = height
    self.steps = steps
    self.seed = seed
    self.negativePrompt = negativePrompt
    self.extras = extras
  }
}

// MARK: - OCR

/// One detected text region in an OCR result.
public struct OCRRegion: Sendable, Equatable {
  /// Recognized text in this region.
  public let text: String
  /// Bounding box in image pixel coordinates: `[x, y, width, height]`
  /// (model convention may vary; YK-209 will pin per-model).
  public let bbox: [Double]?
  /// Confidence score [0, 1] if the model provides one.
  public let confidence: Double?

  public init(text: String, bbox: [Double]? = nil, confidence: Double? = nil) {
    self.text = text
    self.bbox = bbox
    self.confidence = confidence
  }
}

/// Result of an `ocr` call. `text` is the concatenated transcript;
/// `regions` carries per-region detail when the model provides it.
public struct OCRResult: Sendable, Equatable {
  public let text: String
  public let regions: [OCRRegion]

  public init(text: String, regions: [OCRRegion] = []) {
    self.text = text
    self.regions = regions
  }
}

/// OCR generation knobs.
public struct OCROptions: Sendable, Codable, Equatable {
  /// Language hint(s). BCP-47 codes.
  public var languages: [String]?
  public var extras: [String: AnyCodable]?

  public init(
    languages: [String]? = nil,
    extras: [String: AnyCodable]? = nil
  ) {
    self.languages = languages
    self.extras = extras
  }
}

// MARK: - Download

/// One incremental update from a `downloadAsset` stream.
public enum DownloadProgress: Sendable, Equatable {
  case progress(bytesDone: Int64, bytesTotal: Int64?)
  case completed(localPath: String)
}

/// Knobs for `downloadAsset`. Most callers pass none — the worker
/// resolves the destination per its cache config (YK-198 init).
public struct DownloadOptions: Sendable, Codable, Equatable {
  public var destination: String?
  public var extras: [String: AnyCodable]?

  public init(
    destination: String? = nil,
    extras: [String: AnyCodable]? = nil
  ) {
    self.destination = destination
    self.extras = extras
  }
}

// MARK: - QVACClient extensions

extension QVACClient {

  // MARK: translate

  /// Translate `text` from `from` to `to`. Wraps the streaming
  /// `translate` method (per `docs/qvac-sdk-internals.md` §6 it's
  /// a stream); accumulates chunks here for the one-shot
  /// convenience.
  ///
  /// Returns the translated text. `from: nil` lets the worker auto-
  /// detect the source language (model-dependent — Bergamot needs
  /// explicit `from`).
  public func translate(
    modelId: ModelId,
    text: String,
    from: String? = nil,
    to: String
  ) async throws -> String {
    var body: [String: AnyCodable] = [
      "modelId": AnyCodable(.string(modelId)),
      "text": AnyCodable(.string(text)),
      "to": AnyCodable(.string(to)),
    ]
    if let from { body["from"] = AnyCodable(.string(from)) }

    var accumulated = ""
    let raw: AsyncThrowingStream<AnyCodable, Error> = self.streamResponse(
      command: .translate, body)
    for try await chunk in raw {
      if case .object(let dict) = chunk.value,
        case .string(let piece) = dict["text"]
      {
        accumulated = piece  // worker sends partials that replace
      } else if case .string(let s) = chunk.value {
        accumulated += s  // worker sends raw fragments
      }
    }
    return accumulated
  }

  // MARK: diffusion

  /// Streaming image generation. The worker emits step-progress
  /// chunks during denoising and a terminal `.completed(image)`
  /// with the final PNG/JPEG bytes.
  public nonisolated func diffusion(
    modelId: ModelId,
    prompt: String,
    options: DiffusionOptions = .init(),
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<DiffusionStep, Error> {
    let body: [String: AnyCodable] = [
      "modelId": AnyCodable(.string(modelId)),
      "prompt": AnyCodable(.string(prompt)),
      "options": Self.encodeDiffusionOptions(options),
    ]
    let raw: AsyncThrowingStream<AnyCodable, Error> = self.streamResponse(
      command: .diffusionStream, body, bufferSize: bufferSize)
    return Self.mapDiffusionStream(raw)
  }

  // MARK: ocr

  /// OCR an image to text + per-region detail. Wraps the streaming
  /// `ocrStream` and accumulates a single `OCRResult` for the
  /// one-shot signature.
  public func ocr(
    modelId: ModelId,
    image: Data,
    options: OCROptions = .init()
  ) async throws -> OCRResult {
    let body: [String: AnyCodable] = [
      "modelId": AnyCodable(.string(modelId)),
      "image": AnyCodable(.string(image.base64EncodedString())),
      "options": Self.encodeOCROptions(options),
    ]
    let raw: AsyncThrowingStream<AnyCodable, Error> = self.streamResponse(
      command: .ocrStream, body)

    var text = ""
    var regions: [OCRRegion] = []
    for try await chunk in raw {
      if case .object(let dict) = chunk.value {
        if case .string(let t) = dict["text"] {
          text = t
        }
        if case .array(let regs) = dict["regions"] {
          regions = Self.parseRegions(regs)
        }
      }
    }
    return OCRResult(text: text, regions: regions)
  }

  // MARK: downloadAsset

  /// Stream a download of a remote asset to the worker's cache
  /// directory (per YK-198 init config). Emits `.progress(...)`
  /// updates and a terminal `.completed(localPath:)`.
  public nonisolated func downloadAsset(
    src: String,
    options: DownloadOptions = .init(),
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<DownloadProgress, Error> {
    var body: [String: AnyCodable] = [
      "src": AnyCodable(.string(src))
    ]
    if let dest = options.destination {
      body["destination"] = AnyCodable(.string(dest))
    }
    if let extras = options.extras {
      var existing: [String: AnyCodableValue] = [:]
      for (k, v) in body {
        existing[k] = v.value
      }
      for (k, v) in extras {
        existing[k] = v.value
      }
      body = existing.mapValues { AnyCodable($0) }
    }

    let raw: AsyncThrowingStream<AnyCodable, Error> = self.streamResponse(
      command: .downloadAsset, body, bufferSize: bufferSize)
    return Self.mapDownloadStream(raw)
  }

  // MARK: - chunk-shape parsers

  private static func mapDiffusionStream(
    _ raw: AsyncThrowingStream<AnyCodable, Error>
  ) -> AsyncThrowingStream<DiffusionStep, Error> {
    AsyncThrowingStream<DiffusionStep, Error> { continuation in
      let task = Task {
        do {
          for try await rawChunk in raw {
            if let step = Self.parseDiffusionStep(rawChunk) {
              continuation.yield(step)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private static func parseDiffusionStep(_ value: AnyCodable) -> DiffusionStep? {
    guard case .object(let dict) = value.value else { return nil }

    // `{completed: {image: "<base64>"}}` → .completed
    if case .object(let final) = dict["completed"],
      case .string(let b64) = final["image"],
      let data = Data(base64Encoded: b64)
    {
      return .completed(image: data)
    }
    if case .string(let b64) = dict["image"],
      let data = Data(base64Encoded: b64),
      case .bool(let done) = dict["done"], done
    {
      return .completed(image: data)
    }

    // `{preview: "<base64>"}` → .preview
    if case .string(let b64) = dict["preview"],
      let data = Data(base64Encoded: b64)
    {
      return .preview(image: data)
    }

    // `{step: N, totalSteps: M}` → .progress
    if case .int(let s) = dict["step"], case .int(let total) = dict["totalSteps"]
    {
      return .progress(step: s, totalSteps: total)
    }
    if case .double(let s) = dict["step"], case .double(let total) = dict["totalSteps"]
    {
      return .progress(step: Int(s), totalSteps: Int(total))
    }

    return nil
  }

  private static func parseRegions(_ arr: [AnyCodableValue]) -> [OCRRegion] {
    arr.compactMap { v -> OCRRegion? in
      guard case .object(let dict) = v else { return nil }
      var text = ""
      if case .string(let t) = dict["text"] { text = t }
      var bbox: [Double]?
      if case .array(let bboxArr) = dict["bbox"] {
        bbox = bboxArr.compactMap { v -> Double? in
          if case .double(let d) = v { return d }
          if case .int(let i) = v { return Double(i) }
          return nil
        }
      }
      var confidence: Double?
      if case .double(let c) = dict["confidence"] { confidence = c }
      else if case .int(let c) = dict["confidence"] { confidence = Double(c) }
      return OCRRegion(text: text, bbox: bbox, confidence: confidence)
    }
  }

  private static func mapDownloadStream(
    _ raw: AsyncThrowingStream<AnyCodable, Error>
  ) -> AsyncThrowingStream<DownloadProgress, Error> {
    AsyncThrowingStream<DownloadProgress, Error> { continuation in
      let task = Task {
        do {
          for try await rawChunk in raw {
            if let progress = Self.parseDownloadProgress(rawChunk) {
              continuation.yield(progress)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private static func parseDownloadProgress(_ value: AnyCodable) -> DownloadProgress? {
    guard case .object(let dict) = value.value else { return nil }

    // `{localPath: "..."}` → .completed
    if case .string(let path) = dict["localPath"] {
      return .completed(localPath: path)
    }

    // `{bytesDone: N, bytesTotal: M?}` → .progress
    let done: Int64? = {
      if case .int(let v) = dict["bytesDone"] { return Int64(v) }
      if case .double(let v) = dict["bytesDone"] { return Int64(v) }
      return nil
    }()
    if let done {
      let total: Int64?
      if case .int(let v) = dict["bytesTotal"] { total = Int64(v) }
      else if case .double(let v) = dict["bytesTotal"] { total = Int64(v) }
      else { total = nil }
      return .progress(bytesDone: done, bytesTotal: total)
    }

    return nil
  }

  // MARK: - encoders

  private static func encodeDiffusionOptions(_ opt: DiffusionOptions) -> AnyCodable {
    var dict: [String: AnyCodableValue] = [:]
    if let v = opt.width { dict["width"] = .int(v) }
    if let v = opt.height { dict["height"] = .int(v) }
    if let v = opt.steps { dict["steps"] = .int(v) }
    if let v = opt.seed { dict["seed"] = .double(Double(v)) }
    if let v = opt.negativePrompt { dict["negativePrompt"] = .string(v) }
    if let extras = opt.extras {
      for (k, v) in extras { dict[k] = v.value }
    }
    return AnyCodable(.object(dict))
  }

  private static func encodeOCROptions(_ opt: OCROptions) -> AnyCodable {
    var dict: [String: AnyCodableValue] = [:]
    if let langs = opt.languages {
      dict["languages"] = .array(langs.map { .string($0) })
    }
    if let extras = opt.extras {
      for (k, v) in extras { dict[k] = v.value }
    }
    return AnyCodable(.object(dict))
  }
}
