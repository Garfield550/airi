import Darwin
import Foundation
import Logging

/// A `LogHandler` that writes each log record as a newline-terminated JSON object.
///
/// `warning` and above go to **stderr**; everything below goes to **stdout**.
/// This lets parent processes (e.g. Electron) distinguish operational data from
/// diagnostic noise with a simple stream split.
///
/// Example output line (keys are sorted for stable parsing):
/// ```json
/// {"label":"airi.sensor-helper","level":"info","message":"Listening on /tmp/airi-sensor.sock","metadata":{},"timestamp":"2026-03-04T12:00:00Z"}
/// ```
///
/// Bootstrap once at startup:
/// ```swift
/// LoggingSystem.bootstrap(JSONLogHandler.init)
/// ```
struct JSONLogHandler: LogHandler {
    // MARK: - LogHandler conformance

    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    // MARK: - Private

    private let label: String

    init(label: String) {
        self.label = label
    }

    // MARK: - Output

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata callMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var merged = self.metadata
        if let m = callMetadata {
            merged.merge(m) { _, new in new }
        }

        let entry: [String: Any] = [
            "label": label,
            "level": level.rawValue,
            "message": message.description,
            "metadata": merged.mapValues { $0.description },
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.sortedKeys]
            ),
            let line = String(data: data, encoding: .utf8)
        else { return }

        // NOTICE: warning/error/critical go to stderr so Electron can split
        // operational log lines from sensor data on the stdout stream.
        let stream = level >= .warning ? stderr : stdout
        fputs(line + "\n", stream)
    }
}
