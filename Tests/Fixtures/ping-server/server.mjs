// Minimal Bare worker fixture for YK-191 / YK-192 integration tests.
//
// Listens on a Unix domain socket whose path is passed as a positional argv,
// answers a "PING" request (command id 1) with a `Buffer.from("pong")` reply,
// and echoes any other command back with its number for debugging.
//
// Usage:
//     bare server.mjs <socket-path> [--debug]
//
// Lifecycle signals to the Swift harness:
//   - On successful listen, writes `FIXTURE_READY <path>\n` to stdout.
//   - On SIGTERM/SIGINT/stdin-close, unlinks the socket and exits 0.

import pipe from 'bare-pipe'
import fs from 'bare-fs'
import io from 'bare-stdio'
import RPC from 'bare-rpc'

const positional = Bare.argv.slice(2).filter((a) => !a.startsWith('--'))
const flags = new Set(Bare.argv.slice(2).filter((a) => a.startsWith('--')))
const socketPath = positional[0]
const debug = flags.has('--debug')

if (!socketPath) {
  io.err.write('usage: bare server.mjs <socket-path> [--debug]\n')
  Bare.exit(2)
}

const log = (msg) => {
  if (debug) io.err.write(`[ping-server] ${msg}\n`)
}

async function onRequest(req) {
  try {
    log(`RPC frame received: command=${req.command} id=${req.id} dataLen=${req.data?.length ?? 0}`)
    switch (req.command) {
      case 1: // PING
        await req.reply(Buffer.from('pong', 'utf8'))
        break
      case 2: // ECHO — reply with the request payload verbatim
        await req.reply(req.data ?? Buffer.alloc(0))
        break
      default:
        await req.reply(Buffer.from(`echoed cmd ${req.command}`, 'utf8'))
    }
  } catch (err) {
    io.err.write(`[ping-server] handler error: ${err.message ?? err}\n`)
  }
}

const connections = new Set()

// bare-net's listen(path) silently no-ops on macOS in this Bare version —
// the socket inode never appears. Using bare-pipe (which bare-net dispatches
// to internally) directly works correctly.
const server = pipe.createServer()
server.on('connection', (socket) => {
  log(`connection opened`)
  connections.add(socket)
  // eslint-disable-next-line no-unused-vars
  const rpc = new RPC(socket, onRequest)
  socket.on('close', () => {
    log('connection closed')
    connections.delete(socket)
  })
  socket.on('error', (err) => {
    log(`socket error: ${err.message ?? err}`)
  })
})

server.on('error', (err) => {
  io.err.write(`[ping-server] server error: ${err.message ?? err}\n`)
  Bare.exit(1)
})

server.on('close', () => {
  log('server close event')
})

server.on('listening', () => {
  // Single source of truth for "ready" — the Swift harness scans stdout for
  // this line rather than racing inode appearance.
  io.out.write(`FIXTURE_READY ${socketPath}\n`)
})
// Stale-socket cleanup is best-effort; ignore failures.
try { fs.unlinkSync(socketPath) } catch {}
server.listen({ path: socketPath })

let shuttingDown = false
const shutdown = (signal) => {
  if (shuttingDown) return
  shuttingDown = true
  log(`shutting down on ${signal}`)
  for (const socket of connections) {
    try { socket.destroy() } catch {}
  }
  connections.clear()
  try { server.close() } catch {}
  try { fs.unlinkSync(socketPath) } catch {}
  Bare.exit(0)
}

Bare.on('SIGINT', () => shutdown('SIGINT'))
Bare.on('SIGTERM', () => shutdown('SIGTERM'))
io.in.on('end', () => shutdown('STDIN_EOF'))
io.in.resume()

// Bare's event loop exits when there's nothing scheduled. The pipe server
// alone doesn't ref the loop reliably across versions, and stdin.resume()
// doesn't either. Force the loop alive with a 60s heartbeat that no-ops.
setInterval(() => {}, 60_000)
