import Foundation

/// Result of a one-shot `transcribe` call. The full text plus
/// optional per-segment timings (model-dependent — Whisper emits
/// segment-level timestamps; Parakeet does too in `withTimestamps`
/// mode). Both fields free-form so future model variants don't
/// require a Swift bump.
public struct Transcript: Sendable, Equatable {
  public let text: String
  /// Worker-supplied timing/segment info; opaque dict for now.
  /// Cast to typed shape per-model when YK-209 confirms the wire
  /// format.
  public let segments: [AnyCodableValue]?

  public init(text: String, segments: [AnyCodableValue]? = nil) {
    self.text = text
    self.segments = segments
  }
}

/// One incremental update from `transcribeStream`. The worker
/// typically emits multiple `.partial(_)` updates as audio is
/// processed, then a terminal `.final(_)`. Same lossy-mapping
/// pattern as `CompletionChunk`: unknown chunk shapes are
/// silently dropped rather than throwing.
public enum TranscriptDelta: Sendable, Equatable {
  case partial(String)
  case final(Transcript)
}

/// Sampler / decoder knobs shared by both transcribe variants.
public struct TranscribeOptions: Sendable, Codable, Equatable {
  /// BCP-47 language hint (`"en"`, `"fr"`, `"auto"`). Default: `nil`
  /// lets the worker auto-detect.
  public var language: String?
  /// Whisper task: `"transcribe"` (same-language) or `"translate"`
  /// (to-English). Parakeet ignores.
  public var task: String?
  /// Whether to ask the worker for per-segment timestamps.
  public var withTimestamps: Bool?
  /// Per-model-type extras (e.g. Whisper `temperature` /
  /// `beamSize`). Free-form.
  public var extras: [String: AnyCodable]?

  public init(
    language: String? = nil,
    task: String? = nil,
    withTimestamps: Bool? = nil,
    extras: [String: AnyCodable]? = nil
  ) {
    self.language = language
    self.task = task
    self.withTimestamps = withTimestamps
    self.extras = extras
  }
}

/// Text-to-speech generation knobs.
public struct TTSOptions: Sendable, Codable, Equatable {
  /// Voice ID. Model-specific (Kokoro: `"af_bella"`,
  /// `"am_adam"`, …). `nil` uses the worker default.
  public var voice: String?
  /// Speech rate multiplier (1.0 = normal). Model-dependent.
  public var speed: Double?
  /// Output sample rate in Hz. Model-dependent default
  /// (Kokoro: 22050).
  public var sampleRate: Int?
  public var extras: [String: AnyCodable]?

  public init(
    voice: String? = nil,
    speed: Double? = nil,
    sampleRate: Int? = nil,
    extras: [String: AnyCodable]? = nil
  ) {
    self.voice = voice
    self.speed = speed
    self.sampleRate = sampleRate
    self.extras = extras
  }
}

extension QVACClient {
  // MARK: - transcribe (one-shot)

  /// Transcribe `audio` to text in a single round-trip. `audio` is
  /// base64-encoded into the request envelope (matches the JS
  /// SDK's `Buffer.toString('base64')`).
  ///
  /// The wire command is `transcribe` (mode: stream per
  /// `docs/qvac-sdk-internals.md` §6), so we accumulate the
  /// stream into a single `Transcript` here for the one-shot
  /// convenience. Callers wanting incremental output should use
  /// `transcribeStream(...)`.
  public func transcribe(
    modelId: ModelId,
    audio: Data,
    options: TranscribeOptions = .init()
  ) async throws -> Transcript {
    var text = ""
    var lastFinal: Transcript?
    for try await delta in transcribeStream(
      modelId: modelId, audio: audio, options: options)
    {
      switch delta {
      case .partial(let s):
        text = s  // partials replace the running text
      case .final(let t):
        lastFinal = t
      }
    }
    return lastFinal ?? Transcript(text: text)
  }

  /// Streaming transcribe — emits `.partial(text)` updates as the
  /// worker processes the audio, then a terminal `.final(transcript)`.
  /// `bufferSize` is the standard YK-199 backpressure knob.
  public nonisolated func transcribeStream(
    modelId: ModelId,
    audio: Data,
    options: TranscribeOptions = .init(),
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<TranscriptDelta, Error> {
    let body: [String: AnyCodable] = [
      "modelId": AnyCodable(.string(modelId)),
      "audio": AnyCodable(.string(audio.base64EncodedString())),
      "options": Self.encodeTranscribeOptions(options),
    ]
    let raw: AsyncThrowingStream<AnyCodable, Error> = self.streamResponse(
      command: .transcribe, body, bufferSize: bufferSize)
    return Self.mapTranscriptStream(raw)
  }

  // MARK: - textToSpeech

  /// One-shot TTS — accumulates the streamed audio chunks into a
  /// single `Data` and returns. Suitable for short prompts; long
  /// generation should use `textToSpeechStream` to start playback
  /// before the full clip arrives.
  public func textToSpeech(
    modelId: ModelId,
    text: String,
    options: TTSOptions = .init()
  ) async throws -> Data {
    var buffer = Data()
    for try await chunk in textToSpeechStream(
      modelId: modelId, text: text, options: options)
    {
      buffer.append(chunk)
    }
    return buffer
  }

  /// Streaming TTS — each chunk is a fragment of raw PCM (or
  /// model-specific audio bytes; check the loaded model's
  /// documentation). `bufferSize` is the standard YK-199 knob.
  public nonisolated func textToSpeechStream(
    modelId: ModelId,
    text: String,
    options: TTSOptions = .init(),
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<Data, Error> {
    let body: [String: AnyCodable] = [
      "modelId": AnyCodable(.string(modelId)),
      "text": AnyCodable(.string(text)),
      "options": Self.encodeTTSOptions(options),
    ]
    let raw: AsyncThrowingStream<AnyCodable, Error> = self.streamResponse(
      command: .textToSpeech, body, bufferSize: bufferSize)
    return Self.mapAudioStream(raw)
  }

  // MARK: - private helpers

  private static func mapTranscriptStream(
    _ raw: AsyncThrowingStream<AnyCodable, Error>
  ) -> AsyncThrowingStream<TranscriptDelta, Error> {
    AsyncThrowingStream<TranscriptDelta, Error> { continuation in
      let task = Task {
        do {
          for try await rawChunk in raw {
            if let delta = Self.parseTranscriptDelta(rawChunk) {
              continuation.yield(delta)
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

  /// Chunk patterns:
  ///   `{"final": {"text": "...", "segments": [...]}}` → `.final(_)`
  ///   `{"partial": "..."}`                             → `.partial(_)`
  ///   `{"text": "..."}`                                → `.final(_)`  (compact final shape)
  ///   anything else                                    → nil (dropped)
  private static func parseTranscriptDelta(_ value: AnyCodable) -> TranscriptDelta? {
    guard case .object(let dict) = value.value else { return nil }

    if case .object(let final) = dict["final"],
      case .string(let text) = final["text"]
    {
      let segments: [AnyCodableValue]?
      if case .array(let segs) = final["segments"] {
        segments = segs
      } else {
        segments = nil
      }
      return .final(Transcript(text: text, segments: segments))
    }

    if case .string(let partial) = dict["partial"] {
      return .partial(partial)
    }

    if case .string(let text) = dict["text"] {
      return .final(Transcript(text: text))
    }

    return nil
  }

  private static func mapAudioStream(
    _ raw: AsyncThrowingStream<AnyCodable, Error>
  ) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream<Data, Error> { continuation in
      let task = Task {
        do {
          for try await rawChunk in raw {
            if let data = Self.parseAudioChunk(rawChunk) {
              continuation.yield(data)
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

  /// Audio chunk patterns:
  ///   `{"audio": "<base64>"}`           → decode + yield
  ///   `{"chunk": "<base64>"}`           → same (alt field name)
  ///   raw base64 string (rare)          → decode + yield
  ///   anything else                      → nil (dropped)
  private static func parseAudioChunk(_ value: AnyCodable) -> Data? {
    if case .object(let dict) = value.value {
      if case .string(let b64) = dict["audio"] {
        return Data(base64Encoded: b64)
      }
      if case .string(let b64) = dict["chunk"] {
        return Data(base64Encoded: b64)
      }
    }
    if case .string(let b64) = value.value {
      return Data(base64Encoded: b64)
    }
    return nil
  }

  private static func encodeTranscribeOptions(
    _ opt: TranscribeOptions
  ) -> AnyCodable {
    var dict: [String: AnyCodableValue] = [:]
    if let v = opt.language { dict["language"] = .string(v) }
    if let v = opt.task { dict["task"] = .string(v) }
    if let v = opt.withTimestamps { dict["withTimestamps"] = .bool(v) }
    if let extras = opt.extras {
      for (key, value) in extras { dict[key] = value.value }
    }
    return AnyCodable(.object(dict))
  }

  private static func encodeTTSOptions(_ opt: TTSOptions) -> AnyCodable {
    var dict: [String: AnyCodableValue] = [:]
    if let v = opt.voice { dict["voice"] = .string(v) }
    if let v = opt.speed { dict["speed"] = .double(v) }
    if let v = opt.sampleRate { dict["sampleRate"] = .int(v) }
    if let extras = opt.extras {
      for (key, value) in extras { dict[key] = value.value }
    }
    return AnyCodable(.object(dict))
  }
}
