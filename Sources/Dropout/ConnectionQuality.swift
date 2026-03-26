import Foundation

/// Computes a connection quality grade from recent event history.
/// Displayed in the menu bar as a letter grade with trend arrow.
final class ConnectionQuality {
    private let eventLog: EventLog

    init(eventLog: EventLog) {
        self.eventLog = eventLog
    }

    enum Grade: String {
        case excellent = "A"
        case good = "B"
        case fair = "C"
        case poor = "D"
        case terrible = "F"

        var description: String {
            switch self {
            case .excellent: return "Excellent — rock solid"
            case .good: return "Good — minor drops"
            case .fair: return "Fair — occasional issues"
            case .poor: return "Poor — frequent drops"
            case .terrible: return "Terrible — constant drops"
            }
        }

        var color: String {
            switch self {
            case .excellent: return "green"
            case .good: return "green"
            case .fair: return "yellow"
            case .poor: return "orange"
            case .terrible: return "red"
            }
        }
    }

    struct Report {
        let grade: Grade
        let score: Int           // 0-100
        let disconnects24h: Int
        let downtime24h: TimeInterval
        let avgDowntime: TimeInterval
        let longestOutage: TimeInterval
        let trend: Trend         // vs previous 24h
        let peakDropHour: Int?   // hour of day with most drops (0-23)

        var trendArrow: String {
            switch trend {
            case .improving: return "\u{2191}" // ↑
            case .stable: return "\u{2192}"    // →
            case .declining: return "\u{2193}" // ↓
            }
        }

        var summaryLine: String {
            if disconnects24h == 0 {
                return "Connection: \(grade.rawValue) — No drops in 24h"
            }
            let dtStr = formatDuration(downtime24h)
            return "Connection: \(grade.rawValue)\(trendArrow) — \(disconnects24h) drop\(disconnects24h == 1 ? "" : "s"), \(dtStr) down"
        }
    }

    enum Trend {
        case improving, stable, declining
    }

    /// Compute the current connection quality report
    func currentReport() -> Report {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)
        let twoDaysAgo = now.addingTimeInterval(-172800)

        let recentEvents = eventLog.eventsInRange(from: oneDayAgo, to: now)
        let previousEvents = eventLog.eventsInRange(from: twoDaysAgo, to: oneDayAgo)

        let disconnects = recentEvents.filter { $0.type == .disconnected }
        let disconnectCount = disconnects.count

        // Calculate downtime from disconnect/connect pairs
        let (totalDowntime, longestOutage, avgDowntime) = computeDowntime(
            events: recentEvents, periodStart: oneDayAgo, periodEnd: now
        )

        // Previous period for trend
        let prevDisconnects = previousEvents.filter { $0.type == .disconnected }.count

        // Score (0-100): penalize disconnects and downtime
        var score = 100
        score -= disconnectCount * 8         // -8 per disconnect
        score -= Int(totalDowntime / 60) * 3 // -3 per minute of downtime
        score = max(0, min(100, score))

        let grade = gradeFromScore(score)

        // Trend
        let trend: Trend
        if disconnectCount < prevDisconnects - 1 {
            trend = .improving
        } else if disconnectCount > prevDisconnects + 1 {
            trend = .declining
        } else {
            trend = .stable
        }

        // Peak drop hour
        let peakHour = findPeakHour(disconnects: disconnects)

        return Report(
            grade: grade,
            score: score,
            disconnects24h: disconnectCount,
            downtime24h: totalDowntime,
            avgDowntime: avgDowntime,
            longestOutage: longestOutage,
            trend: trend,
            peakDropHour: peakHour
        )
    }

    /// Generate a multi-day reliability summary for a specific network
    func networkReliability(ssid: String, days: Int = 7) -> (uptime: Double, disconnects: Int, avgDowntime: TimeInterval) {
        let now = Date()
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let events = eventLog.eventsInRange(from: start, to: now)
            .filter { $0.ssid == ssid }

        let disconnects = events.filter { $0.type == .disconnected }.count
        let (totalDowntime, _, avgDowntime) = computeDowntime(events: events, periodStart: start, periodEnd: now)

        let totalPeriod = now.timeIntervalSince(start)
        let uptime = totalPeriod > 0 ? ((totalPeriod - totalDowntime) / totalPeriod) * 100 : 100

        return (uptime: min(100, max(0, uptime)), disconnects: disconnects, avgDowntime: avgDowntime)
    }

    // MARK: - Private

    private func computeDowntime(events: [WiFiEvent], periodStart: Date, periodEnd: Date) -> (total: TimeInterval, longest: TimeInterval, average: TimeInterval) {
        var totalDowntime: TimeInterval = 0
        var longestOutage: TimeInterval = 0
        var outageCount = 0
        var lastDisconnect: Date?

        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        for event in sorted {
            if event.type == .disconnected {
                lastDisconnect = event.timestamp
            } else if event.type == .connected, let disc = lastDisconnect {
                let duration = event.timestamp.timeIntervalSince(disc)
                totalDowntime += duration
                longestOutage = max(longestOutage, duration)
                outageCount += 1
                lastDisconnect = nil
            }
        }

        // If still disconnected
        if let disc = lastDisconnect {
            let duration = periodEnd.timeIntervalSince(disc)
            totalDowntime += duration
            longestOutage = max(longestOutage, duration)
            outageCount += 1
        }

        let avgDowntime = outageCount > 0 ? totalDowntime / Double(outageCount) : 0
        return (totalDowntime, longestOutage, avgDowntime)
    }

    private func gradeFromScore(_ score: Int) -> Grade {
        switch score {
        case 90...100: return .excellent
        case 75..<90: return .good
        case 55..<75: return .fair
        case 30..<55: return .poor
        default: return .terrible
        }
    }

    private func findPeakHour(disconnects: [WiFiEvent]) -> Int? {
        guard !disconnects.isEmpty else { return nil }
        var hourCounts = [Int: Int]()
        let calendar = Calendar.current
        for event in disconnects {
            let hour = calendar.component(.hour, from: event.timestamp)
            hourCounts[hour, default: 0] += 1
        }
        return hourCounts.max(by: { $0.value < $1.value })?.key
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
        return "\(Int(seconds))s"
    } else if seconds < 3600 {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return secs > 0 ? "\(mins)m \(secs)s" : "\(mins)m"
    } else {
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }
}
