import Charts
import SwiftUI

/// Where a removal came from. Every deletion in the app carries one.
enum ReclaimOrigin: String, Codable, CaseIterable, Identifiable {
    case scan = "Disk Scan"
    case cleanup = "Clean Up"
    var id: Self { self }
    var icon: String { self == .scan ? "chart.pie" : "broom.fill" }
}

/// Lifetime record of everything Diskly has removed. One entry per cleanup.
// ponytail: UserDefaults + JSON, not a database — a few entries per week never
// outgrows it. Swap for a file in Application Support if it ever does.
@MainActor @Observable final class ReclaimedLog {
    static let shared = ReclaimedLog()

    struct Entry: Codable, Identifiable {
        let date: Date
        let bytes: Int64
        let origin: ReclaimOrigin
        /// What was removed: a cleanup target name, or the scanned folder.
        let source: String
        var id: Date { date }

        init(date: Date, bytes: Int64, origin: ReclaimOrigin, source: String) {
            self.date = date
            self.bytes = bytes
            self.origin = origin
            self.source = source
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(Date.self, forKey: .date)
            bytes = try c.decode(Int64.self, forKey: .bytes)
            source = try c.decode(String.self, forKey: .source)
            origin = try c.decodeIfPresent(ReclaimOrigin.self, forKey: .origin) ?? .cleanup
        }
    }

    private static let key = "reclaimedLog"
    private(set) var entries: [Entry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    func total(_ origin: ReclaimOrigin) -> Int64 {
        entries.reduce(0) { $1.origin == origin ? $0 + $1.bytes : $0 }
    }

    func record(_ bytes: Int64, origin: ReclaimOrigin, source: String) {
        guard bytes > 0 else { return }
        entries.append(Entry(date: .now, bytes: bytes, origin: origin, source: source))
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    struct DayBucket: Identifiable {
        let day: Date
        let origin: ReclaimOrigin
        let bytes: Int64
        var id: String { "\(day.timeIntervalSince1970)-\(origin.rawValue)" }
    }

    /// Bytes per day and origin for the last `days` days, oldest first. Empty
    /// days are included so the chart keeps an even timeline.
    func daily(days: Int = 30) -> [DayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let timeline = (0..<days).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        assert(timeline.count == days && timeline.last == today)
        var buckets: [Date: [ReclaimOrigin: Int64]] = [:]
        for entry in entries where entry.date >= (timeline.first ?? today) {
            buckets[calendar.startOfDay(for: entry.date), default: [:]][entry.origin, default: 0]
                += entry.bytes
        }
        return timeline.flatMap { day in
            ReclaimOrigin.allCases.map {
                DayBucket(day: day, origin: $0, bytes: buckets[day]?[$0] ?? 0)
            }
        }
    }
}

/// Standalone stats screen: lifetime total, split by origin, 30-day history.
struct ReclaimedStats: View {
    private let log = ReclaimedLog.shared
    @State private var days = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Reclaimed").font(.title.bold())

            if log.entries.isEmpty {
                ContentUnavailableView("Nothing reclaimed yet",
                                       systemImage: "chart.bar.doc.horizontal",
                                       description: Text("Delete files from a scan or clean a cache and it shows up here."))
                    .frame(maxHeight: .infinity)
            } else {
                headline
                chart
                history
            }
        }
        .padding(24)
        .frame(maxWidth: 700, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ALL TIME").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(log.total.byteString).font(.system(size: 34, weight: .bold).monospacedDigit())
                Text("^[\(log.entries.count) cleanup](inflect: true)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(ReclaimOrigin.allCases) { origin in
                VStack(alignment: .leading, spacing: 2) {
                    Label(origin.rawValue, systemImage: origin.icon)
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(log.total(origin).byteString)
                        .font(.title3.weight(.medium).monospacedDigit())
                }
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $days) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Year").tag(365)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Chart(log.daily(days: days)) { bucket in
                BarMark(x: .value("Day", bucket.day, unit: .day),
                        y: .value("Freed", bucket.bytes))
                    .foregroundStyle(by: .value("Origin", bucket.origin.rawValue))
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text((value.as(Int64.self) ?? 0).byteString) }
                }
            }
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 160)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HISTORY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(log.entries.reversed()) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.origin.icon)
                                .foregroundStyle(.tint).frame(width: 16)
                            Text(entry.source).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.bytes.byteString)
                                .monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxHeight: .infinity)
    }
}
