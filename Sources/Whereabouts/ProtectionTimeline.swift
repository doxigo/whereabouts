import SwiftUI

struct ProtectionEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var category: String
    var detail: String
    var location: TimelineLocation?

    var locationDetails: TimelineLocation? { location ?? (category == "Location check" ? TimelineLocation.legacy(detail) : nil) }

    var symbol: String {
        switch category {
        case "Location check": "location"
        case "Connection": "network"
        case "Firewall": "lock.shield"
        case "Firewall error": "exclamationmark.triangle"
        case "Site rule": "safari"
        case "Confirmation": "checkmark.bubble"
        case "Recording": "record.circle"
        case "Settings": "slider.horizontal.3"
        default: "text.alignleft"
        }
    }

    func matches(query: String, category: String) -> Bool {
        (category.isEmpty || self.category == category)
            && (query.isEmpty || (self.category + " " + detail).localizedStandardContains(query))
    }
}

struct TimelineLocation: Codable, Equatable {
    var place: String
    var ip: String?
    var asn: Int?
    var isp: String?
    var source: String
    var message: String

    // Older records contain a sentence; only split the known format, preserving everything else.
    static func legacy(_ detail: String) -> TimelineLocation? {
        guard let sourceEnd = detail.range(of: " metadata: "), let messageStart = detail.range(of: ". Your IP "),
              sourceEnd.upperBound < messageStart.lowerBound else { return nil }
        let fields = detail[sourceEnd.upperBound..<messageStart.lowerBound].components(separatedBy: " | ")
        guard fields.count == 4, isIPAddress(fields[0]), let asn = asNumber(fields[2]) else { return nil }
        return TimelineLocation(place: fields[1], ip: fields[0], asn: asn, isp: fields[3],
                                source: String(detail[..<sourceEnd.lowerBound]),
                                message: String(detail[detail.index(messageStart.lowerBound, offsetBy: 2)...]))
    }
}

extension Monitor {
    func recordProtection(_ category: String, _ detail: String, location: TimelineLocation? = nil) {
        guard settings.protectionTimeline, !Demo.enabled else { return }
        timeline.insert(ProtectionEvent(category: category, detail: detail, location: location), at: 0)
        timeline = Array(timeline.prefix(Store.maxTimeline))
        if !testing { Store.saveTimeline(timeline) }
    }

    func clearTimeline() {
        timeline = []
        if !testing { Store.saveTimeline([]) }
    }
}

struct ProtectionTimelineSettings: View {
    @Environment(Monitor.self) private var m
    @State private var showing = false

    var body: some View {
        Section {
            Toggle(isOn: m.binding(\.protectionTimeline)) {
                Text("Record protection timeline")
                Text("Keep route changes, location checks, rule results and firewall actions on this Mac.")
            }
            HStack {
                Button("View Timeline...") { showing = true }.disabled(m.timeline.isEmpty)
                Spacer()
                Button("Clear Timeline", role: .destructive) { m.clearTimeline() }.disabled(m.timeline.isEmpty)
            }
        } header: { Text("Protection timeline") }
        footer: { Footer("Keeps the latest 500 events, including IP addresses and checked site domains. Turning this off stops recording; Clear Timeline deletes the saved events.") }
        .sheet(isPresented: $showing) {
            ProtectionTimelineView()
        }
        .onAppear { if Demo.scenario == "timeline" { showing = true } }
    }
}

private struct ProtectionTimelineView: View {
    @Environment(Monitor.self) private var m
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category = ""

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: m.systemTimeZone) ?? .current
        return calendar
    }

    private var events: [ProtectionEvent] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.timeline.filter { $0.matches(query: query, category: category) }
    }

    private var days: [(date: Date, events: [ProtectionEvent])] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
            .map { (date: $0.key, events: $0.value) }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Protection timeline").font(.title2.weight(.semibold))
                        Text("Connection checks and protection activity").font(.callout).foregroundStyle(Color.primary.opacity(0.75))
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 12) {
                    TextField("Search events", text: $query).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search timeline events")
                    Picker("Event type", selection: $category) {
                        Text("All events").tag("")
                        ForEach(Array(Set(m.timeline.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().accessibilityLabel("Filter by event type")
                    .fixedSize()
                }
            }
            .padding(20)
            Divider()
            if events.isEmpty {
                ContentUnavailableView {
                    Label(m.timeline.isEmpty ? "No events yet" : "No matching events", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(m.timeline.isEmpty ? "Recorded connection checks and protection activity will appear here."
                         : "Try another search or choose a different event type.")
                } actions: {
                    if !m.timeline.isEmpty { Button("Reset Filters") { query = ""; category = "" } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days, id: \.date) { day in
                        Section {
                            ForEach(day.events) { event in
                                ProtectionTimelineRow(event: event, timeZone: calendar.timeZone)
                                    .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 12, trailing: 4))
                            }
                        } header: {
                            Text(calendar.isDateInToday(day.date) ? "Today" : day.date.formatted(Date.FormatStyle(date: .long, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)))
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 6).padding(.bottom, 2)
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            HStack(spacing: 6) {
                Text("\(events.count) of \(m.timeline.count) events")
                Text("· Newest first")
                Spacer()
                Text(m.settings.protectionTimeline ? "Recording on" : "Recording off")
                Text("· Times: \(m.systemTimeZone)")
            }
            .font(.caption).foregroundStyle(Color.primary.opacity(0.75)).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 680, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ProtectionTimelineRow: View {
    let event: ProtectionEvent
    let timeZone: TimeZone

    var body: some View {
        let location = event.locationDetails
        HStack(alignment: .top, spacing: 12) {
            Text(event.date.formatted(Date.FormatStyle(date: .omitted, time: .standard, timeZone: timeZone)))
                .font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: 76, alignment: .trailing).padding(.top, 2)
                .accessibilityLabel(event.date.formatted(Date.FormatStyle(date: .complete, time: .standard, timeZone: timeZone)))
            Image(systemName: event.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(event.category == "Firewall error" ? Tone.error.textColor : .secondary)
                .frame(width: 18).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(location?.place ?? event.category).font(.body.weight(.semibold))
                        .accessibilityLabel(event.category + (location.map { ": " + $0.place } ?? ""))
                    if let location {
                        Text(location.source).font(.caption).foregroundStyle(Color.primary.opacity(0.75))
                    }
                }
                Text(location?.message ?? event.detail)
                    .font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let location {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { metadata(location) }
                        VStack(alignment: .leading, spacing: 4) { metadata(location) }
                    }
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Copy Event") {
                NSPasteboard.general.clearContents()
                let date = event.date.formatted(Date.FormatStyle(date: .complete, time: .standard, timeZone: timeZone))
                NSPasteboard.general.setString("\(date) (\(timeZone.identifier))\n\(event.category)\n\(event.detail)", forType: .string)
            }
        }
    }

    @ViewBuilder private func metadata(_ location: TimelineLocation) -> some View {
        if let ip = location.ip { Text(ip).monospaced().fixedSize().accessibilityLabel("IP address \(ip)") }
        if let asn = location.asn { Text("AS" + String(asn)).monospaced().fixedSize() }
        if let isp = location.isp { Text(isp).fixedSize(horizontal: false, vertical: true) }
    }
}
