import SwiftUI

struct ActivityGroup: Identifiable {
    var entries: [HistoryEntry]
    var latest: HistoryEntry { entries[0] }
    var id: Double { latest.id }
}

func activityGroups(_ history: [HistoryEntry], calendar: Calendar) -> [ActivityGroup] {
    var groups: [ActivityGroup] = []
    for entry in history {
        if let last = groups.last?.latest, calendar.isDate(last.date, inSameDayAs: entry.date),
           last.status == entry.status, last.countryCode == entry.countryCode, last.country == entry.country,
           last.city == entry.city, last.isp == entry.isp, last.ip == entry.ip, last.isVpn == entry.isVpn {
            groups[groups.count - 1].entries.append(entry)
        } else { groups.append(ActivityGroup(entries: [entry])) }
    }
    return groups
}

struct RecentActivity: View {
    @Environment(Monitor.self) private var m
    @State private var showAll = false
    @State private var confirmingClear = false

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: m.systemTimeZone) ?? .current
        return calendar
    }

    var body: some View {
        let groups = activityGroups(m.history, calendar: calendar)
        let visible = Array(groups.prefix(showAll ? groups.count : 10))
        Section {
            if visible.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No activity yet").font(.body.weight(.medium))
                    Text("Saved location and status changes will appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, group in
                if index == 0 || !calendar.isDate(visible[index - 1].latest.date, inSameDayAs: group.latest.date) {
                    Text(calendar.isDateInToday(group.latest.date) ? "Today" : group.latest.date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: calendar.timeZone)))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.75))
                }
                if group.entries.count > 1 {
                    DisclosureGroup {
                        ForEach(group.entries) { entry in
                            HStack {
                                Text(entry.date.formatted(Date.FormatStyle(date: .omitted, time: .standard, timeZone: calendar.timeZone))).monospacedDigit()
                                Spacer()
                                Text(entry.status.label)
                            }.font(.caption).foregroundStyle(Color.primary.opacity(0.75))
                        }
                    } label: {
                        ActivityRow(group: group, timeZone: calendar.timeZone)
                    }
                } else {
                    ActivityRow(group: group, timeZone: calendar.timeZone).padding(.leading, 12)
                }
            }
            if groups.count > 10 {
                Button(showAll ? "Show Less" : "Show All Saved Activity") { showAll.toggle() }
                    .buttonStyle(.link)
            }
        } header: {
            HStack {
                Text("Recent activity")
                Spacer()
                if !m.history.isEmpty {
                    Button("Clear...") { confirmingClear = true }.buttonStyle(.link)
                }
            }
        } footer: {
            if !m.history.isEmpty {
                Text("\(m.history.count) saved events · Times: \(m.systemTimeZone)")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.75))
            }
        }
        .confirmationDialog("Clear recent activity?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { m.clearHistory() }
        } message: {
            Text("This permanently deletes saved location history. The protection timeline is stored separately.")
        }
    }
}

private struct ActivityRow: View {
    let group: ActivityGroup
    let timeZone: TimeZone

    var body: some View {
        let entry = group.latest
        let country = entry.country ?? Countries.name(entry.countryCode) ?? "Unknown location"
        HStack(alignment: .top, spacing: 10) {
            Text(Countries.flag(entry.countryCode)).font(.title3).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.city.map { "\($0), \(country)" } ?? country)
                        .font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Label(entry.status.label, systemImage: entry.status == .safe ? "checkmark.circle" : entry.status == .violation ? "exclamationmark.circle" : "questionmark.circle")
                        .font(.caption).foregroundStyle(entry.status == .safe ? Color.primary.opacity(0.75) : entry.status.tone.textColor)
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Text(entry.date.formatted(Date.FormatStyle(date: .omitted, time: .standard, timeZone: timeZone))).monospacedDigit()
                    if group.entries.count > 1 { Text("· \(group.entries.count) identical events") }
                }.font(.caption).foregroundStyle(Color.primary.opacity(0.75))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { connection(entry) }
                    VStack(alignment: .leading, spacing: 3) { connection(entry) }
                }
                .font(.caption).foregroundStyle(Color.primary.opacity(0.75))
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func connection(_ entry: HistoryEntry) -> some View {
        if let isp = entry.isp { Text(isp).fixedSize(horizontal: false, vertical: true) }
        if let ip = entry.ip { Text(ip).monospaced().fixedSize().accessibilityLabel("IP address \(ip)") }
    }
}
