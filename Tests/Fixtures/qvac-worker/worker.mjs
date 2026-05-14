// Real QVAC Bare worker fixture (YK-208).
//
// Spawned by `QVACWorkerHarness` (Swift). The harness opens a UDS
// server first, then runs:
//
//   bare worker.mjs '{"QVAC_IPC_SOCKET_PATH": "<socket-path>"}'
//
// We just delegate to @qvac/sdk's actual worker.js entry, which:
//   - registers all built-in plugins (llm, embeddings, whisper,
//     parakeet, nmt, tts, ocr, diffusion)
//   - reads argv[2] as JSON config (see @qvac/sdk/dist/server/env.js)
//   - calls createIPCClient(socketPath) to connect out to the
//     harness's UDS server.
//
// There's no stdout "ready" signal — the harness's
// `UDSServer.accept()` returning IS the ready signal (the worker
// has connected to us, which is the strongest possible "alive"
// indication).

import "@qvac/sdk/dist/server/worker.js"
