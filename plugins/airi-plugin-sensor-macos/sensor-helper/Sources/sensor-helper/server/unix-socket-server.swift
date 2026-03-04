import Darwin
import Foundation
import Logging

/// A Unix domain socket server that broadcasts newline-delimited JSON to all connected clients.
///
/// Each connected client (e.g. `nc -U /tmp/airi-sensor.sock`) will receive every
/// `broadcast(_:)` call as a single line of JSON text terminated by `\n`.
///
/// Uses Swift's `actor` model for automatic mutual exclusion on all mutable state —
/// no manual locks required and the compiler statically verifies data-race freedom.
/// main thread (RunLoop)
///   └─ Timer fires → Task { await server.broadcast() }
///                         │ hops to actor executor
///                         └─ iterates clients, send()
///
/// actor executor
///   └─ acceptLoop (async)
///        ├─ await withCheckedContinuation ──→ DispatchQueue.background: accept()
///        │                                    (actor free during blocking wait)
///        └─ on resume: clients.insert(fd)
///
/// stop() called → isRunning=false, close(fd) → accept() returns EBADF → break
///
actor UnixSocketServer {
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var clients: Set<Int32> = []
    private var isRunning = false
    private var logger = Logger(label: "airi.sensor-helper.server")

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Start listening and accept connections in the background.
    func start() throws {
        // Clean up any leftover socket file from a previous run.
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { throw SocketError.creationFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path into the fixed-length sun_path C char array.
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(104)) { charPtr in
                _ = strncpy(charPtr, socketPath, 104)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else { throw SocketError.bindFailed }

        // Make the socket file readable/writable by everyone so clients can connect.
        chmod(socketPath, 0o777)
        guard listen(serverSocket, 8) == 0 else { throw SocketError.listenFailed }

        logger.info("Listening on \(socketPath)", metadata: ["path": "\(socketPath)"])

        isRunning = true
        Task {
            await acceptLoop()
        }
    }

    /// Stop the server and clean up the socket file.
    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
        logger.info("Server stopped")
    }

    /// Broadcast `data` followed by a newline to every connected client.
    /// Clients that have disconnected are removed from the set.
    func broadcast(_ data: Data) {
        var payload = data
        payload.append(0x0A) // '\n'

        for fd in clients {
            let sent = payload.withUnsafeBytes { buffer in
                send(fd, buffer.baseAddress!, buffer.count, 0)
            }
            if sent < 0 {
                // Client disconnected — stop tracking it.
                clients.remove(fd)
                close(fd)
                logger.info("Client fd=\(fd) disconnected")
            }
        }
    }

    // MARK: - Private

    private func acceptLoop() async {
        // Capture the fd before suspending so the DispatchQueue block can read it
        // without accessing actor-isolated state from a non-isolated context.
        let serverFd = serverSocket

        while isRunning {
            // Bridge the blocking accept() syscall to the async world:
            // - The actor is suspended during the await, remaining free to handle
            //   broadcast() or stop() calls while waiting for a new connection.
            // - When stop() closes serverSocket, accept() returns EBADF and the
            //   loop exits cleanly on the next iteration.
            let clientFd = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .background).async {
                    continuation.resume(returning: accept(serverFd, nil, nil))
                }
            }

            guard clientFd >= 0 else {
                // EBADF / EINVAL means stop() closed the server socket — exit cleanly.
                if errno == EBADF || errno == EINVAL || !isRunning { break }
                logger.error("accept failed: \(String(cString: strerror(errno)))")
                continue
            }

            logger.info("Client connected fd=\(clientFd)")
            clients.insert(clientFd)
        }
    }
}

extension UnixSocketServer {
    enum SocketError: Error {
        case creationFailed
        case bindFailed
        case listenFailed
    }
}
