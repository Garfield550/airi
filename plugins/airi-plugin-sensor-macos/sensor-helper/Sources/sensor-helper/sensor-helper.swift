import Foundation
import Logging

@main
struct SensorHelper {
    static func main() {
        // Disable stdout buffering so log lines reach Electron immediately
        // even when the process stdout is connected to a pipe (fully-buffered by default).
        setbuf(stdout, nil)

        LoggingSystem.bootstrap(JSONLogHandler.init)
        var logger = Logger(label: "airi.sensor-helper")
        logger.logLevel = .trace

        let socketPath = "/tmp/airi-sensor.sock"
        let server = UnixSocketServer(socketPath: socketPath)

        // Actor methods must be called from an async context.
        // Wrap the startup in a Task so we can use await within the sync main().
        Task {
            do {
                try await server.start()
            } catch {
                await server.stop()
                logger.error("Server start failed: \(error)")
                exit(1)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sort keys so output is stable and easy to read in the terminal.
        encoder.outputFormatting = .sortedKeys

        // Broadcast a mock SensorData reading every second.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [logger] _ in
            Task {
                do {
                    let data = try encoder.encode(SensorData.mock())
                    await server.broadcast(data)
                } catch {
                    logger.error("Encode error: \(error)")
                }
            }
        }

        RunLoop.main.run()
    }
}
