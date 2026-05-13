# `ping-server` — minimal Bare worker fixture (YK-191)

A 100-line Bare worker that listens on a Unix domain socket, wraps each
incoming connection in `bare-rpc`, and answers a handful of canned commands.
Used by Swift integration tests (YK-192) to exercise the
`UDSTransport` → `RPCBridge` stack against a real `bare-rpc` peer instead
of a Swift-only mock.

## Install

```bash
cd Tests/Fixtures/ping-server
npm install
```

This pulls `bare-runtime`, `bare-rpc`, `bare-pipe`, `bare-fs`, `bare-stdio`,
and `bare-buffer` into `node_modules/`. The fixture is then runnable via
`node_modules/.bin/bare`.

## Commands

| Command id | Behavior |
| --- | --- |
| `1` (PING) | Reply with `Buffer.from("pong")` |
| `2` (ECHO) | Reply with the request payload verbatim |
| anything else | Reply with `Buffer.from("echoed cmd <id>")` |

The fixture deliberately does **not** speak any QVAC SDK methods — its only
job is to validate the bare-rpc framing layer end-to-end with the Swift
client. Real QVAC method handlers live on a different fixture (M2 / YK-208).

## CLI

```
bare server.mjs <socket-path> [--debug]
```

- `<socket-path>` is required; the parent directory must exist.
- `--debug` enables `[ping-server]` logging on stderr (RPC frame metadata,
  connection lifecycle).

The fixture writes the single line `FIXTURE_READY <socket-path>\n` to
stdout once the socket is bound and listening. Consumers (the Swift
`PingServerHarness`) wait for this line — it's more reliable than
poll-statting the inode.

## Shutdown

- `SIGTERM` / `SIGINT`: graceful — closes connections, removes the socket inode, exits 0.
- `stdin` close: same as SIGTERM. This is what the Swift harness uses.

## Lockfile

`package-lock.json` is committed so re-running `npm ci` in CI installs the
exact same transitive tree. Don't `npm update` without re-running the
M1 integration suite (YK-192).
