import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class EventLog {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.dropout.db")

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Dropout")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("events.db").path

        if sqlite3_open(path, &db) == SQLITE_OK {
            createTable()
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                type TEXT NOT NULL,
                ssid TEXT,
                bssid TEXT,
                rssi INTEGER,
                transmit_rate REAL,
                details TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
            """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Write

    func log(_ event: WiFiEvent) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = """
                INSERT INTO events (timestamp, type, ssid, bssid, rssi, transmit_rate, details)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, event.timestamp.timeIntervalSince1970)
            self.bindText(stmt, 2, event.type.rawValue)
            self.bindOptionalText(stmt, 3, event.ssid)
            self.bindOptionalText(stmt, 4, event.bssid)
            self.bindOptionalInt(stmt, 5, event.rssi)
            self.bindOptionalDouble(stmt, 6, event.transmitRate)
            self.bindOptionalText(stmt, 7, event.details)

            sqlite3_step(stmt)
        }
    }

    // MARK: - Read

    func recentEvents(limit: Int = 10) -> [WiFiEvent] {
        var events: [WiFiEvent] = []
        queue.sync {
            guard let db else { return }
            let sql = """
                SELECT id, timestamp, type, ssid, bssid, rssi, transmit_rate, details
                FROM events ORDER BY timestamp DESC LIMIT ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(readEvent(from: stmt))
            }
        }
        return events
    }

    func eventsInRange(from start: Date, to end: Date) -> [WiFiEvent] {
        var events: [WiFiEvent] = []
        queue.sync {
            guard let db else { return }
            let sql = """
                SELECT id, timestamp, type, ssid, bssid, rssi, transmit_rate, details
                FROM events WHERE timestamp >= ? AND timestamp <= ?
                ORDER BY timestamp ASC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)

            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(readEvent(from: stmt))
            }
        }
        return events
    }

    /// Returns all unique SSIDs seen in the database
    func knownNetworks() -> [String] {
        var networks: [String] = []
        queue.sync {
            guard let db else { return }
            let sql = "SELECT DISTINCT ssid FROM events WHERE ssid IS NOT NULL ORDER BY ssid"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    networks.append(String(cString: cStr))
                }
            }
        }
        return networks
    }

    func todayStats() -> (disconnects: Int, totalDowntime: TimeInterval) {
        var disconnects = 0
        var totalDowntime: TimeInterval = 0

        queue.sync {
            guard let db else { return }
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970

            // Count disconnects
            var stmt: OpaquePointer?
            let countSQL = "SELECT COUNT(*) FROM events WHERE type = 'disconnected' AND timestamp >= ?"
            if sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, startOfDay)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    disconnects = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }

            // Calculate downtime from disconnect/connect pairs
            let pairsSQL = """
                SELECT timestamp, type FROM events
                WHERE type IN ('disconnected', 'connected') AND timestamp >= ?
                ORDER BY timestamp ASC
                """
            if sqlite3_prepare_v2(db, pairsSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, startOfDay)
                var lastDisconnect: TimeInterval?
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let ts = sqlite3_column_double(stmt, 0)
                    let type = String(cString: sqlite3_column_text(stmt, 1))
                    if type == "disconnected" {
                        lastDisconnect = ts
                    } else if type == "connected", let disc = lastDisconnect {
                        totalDowntime += ts - disc
                        lastDisconnect = nil
                    }
                }
                if let disc = lastDisconnect {
                    totalDowntime += Date().timeIntervalSince1970 - disc
                }
                sqlite3_finalize(stmt)
            }
        }
        return (disconnects, totalDowntime)
    }

    // MARK: - Export

    func exportCSV() -> String {
        var csv = "timestamp,type,ssid,bssid,rssi,transmit_rate,details\n"
        queue.sync {
            guard let db else { return }
            let sql = """
                SELECT timestamp, type, ssid, bssid, rssi, transmit_rate, details
                FROM events ORDER BY timestamp ASC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let formatter = ISO8601DateFormatter()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = formatter.string(from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)))
                let type = String(cString: sqlite3_column_text(stmt, 1))
                let ssid = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let bssid = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let rssi = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? "\(sqlite3_column_int(stmt, 4))" : ""
                let rate = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? "\(sqlite3_column_double(stmt, 5))" : ""
                let details = (sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "")
                    .replacingOccurrences(of: "\"", with: "\"\"")
                csv += "\(ts),\(type),\"\(ssid)\",\"\(bssid)\",\(rssi),\(rate),\"\(details)\"\n"
            }
        }
        return csv
    }

    // MARK: - Helpers

    private func readEvent(from stmt: OpaquePointer?) -> WiFiEvent {
        WiFiEvent(
            type: WiFiEventType(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .disconnected,
            ssid: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            bssid: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            rssi: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil,
            transmitRate: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_double(stmt, 6) : nil,
            details: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
            id: sqlite3_column_int64(stmt, 0),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        )
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int(stmt, index, Int32(value)) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }
}
