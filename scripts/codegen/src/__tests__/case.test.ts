import { describe, expect, it } from "vitest";

import { snakeToLowerCamel, snakeToUpperCamel } from "../util/case.js";

describe("snakeToLowerCamel", () => {
  it.each([
    ["INVALID_RESPONSE_TYPE", "invalidResponseType"],
    ["MODEL_NOT_FOUND", "modelNotFound"],
    ["OCR_FAILED", "ocrFailed"],
    ["RPC_NO_HANDLER", "rpcNoHandler"],
    ["TTS_REFERENCE_AUDIO_REQUIRED", "ttsReferenceAudioRequired"],
    ["A", "a"],
    ["AB_C", "abC"],
  ])("%s -> %s", (input, expected) => {
    expect(snakeToLowerCamel(input)).toBe(expected);
  });

  it("returns empty string for empty input", () => {
    expect(snakeToLowerCamel("")).toBe("");
  });
});

describe("snakeToUpperCamel", () => {
  it.each([
    ["INVALID_RESPONSE_TYPE", "InvalidResponseType"],
    ["MODEL_NOT_FOUND", "ModelNotFound"],
    ["OCR_FAILED", "OcrFailed"],
  ])("%s -> %s", (input, expected) => {
    expect(snakeToUpperCamel(input)).toBe(expected);
  });
});
