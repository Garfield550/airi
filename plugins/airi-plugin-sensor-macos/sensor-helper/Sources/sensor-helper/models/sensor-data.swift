import Foundation

struct SensorData: Codable {
    let id: String
    let temperature: Double
    let humidity: Double
    let timestamp: Date
    let type: String

    static func mock() -> SensorData {
        SensorData(
            id: UUID().uuidString,
            temperature: Double.random(in: 20.0...35.0),
            humidity: Double.random(in: 30.0...70.0),
            timestamp: Date(),
            type: "sensor_reading"
        )
    }
}
