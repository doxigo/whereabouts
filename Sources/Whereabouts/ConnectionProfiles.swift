import SwiftUI

struct ConnectionProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var locations: [SiteLocation] = []
    var asns: [Int] = []

    var isComplete: Bool { !name.isEmpty && !locations.isEmpty && !asns.isEmpty }
}

func normalizedLocations(_ locations: [SiteLocation]) -> [SiteLocation] {
    var seen = Set<String>()
    return locations.compactMap { location in
        let code = location.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let city = location.city?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = SiteLocation(countryCode: code, country: location.country.isEmpty ? code : location.country,
                                  city: city?.isEmpty == false ? city : nil)
        return seen.insert(result.key).inserted ? result : nil
    }
}

func profileVerdict(_ location: Location, _ profile: ConnectionProfile) -> Verdict {
    guard profile.isComplete else { return Verdict(kind: .unknown, message: "Complete the location and ASN rules for \(profile.name).") }
    let countries = profile.locations.filter { $0.countryCode == location.countryCode }
    if !countries.isEmpty, countries.allSatisfy({ $0.city != nil }), location.city?.isEmpty != false {
        return Verdict(kind: .unknown, message: "The provider did not return a city for profile \(profile.name).")
    }
    guard locationSatisfies(location, SiteRule(domain: "", locations: profile.locations)) else {
        return Verdict(kind: .violation, message: "\(location.cityPlace) does not match profile \(profile.name).", reason: .profile)
    }
    guard let asn = location.asn else { return Verdict(kind: .unknown, message: "The provider did not return an ASN for profile \(profile.name).") }
    guard profile.asns.contains(asn) else {
        return Verdict(kind: .violation, message: "AS\(asn) is not allowed by profile \(profile.name).", reason: .profile)
    }
    return Verdict(kind: .safe, message: "Location and AS\(asn) match profile \(profile.name).")
}

func parseASNs(_ text: String) -> [Int]? {
    let parts = text.split { $0 == "," || $0.isWhitespace }
    guard !parts.isEmpty else { return nil }
    var values: [Int] = []
    for part in parts {
        let value = part.uppercased().hasPrefix("AS") ? String(part.dropFirst(2)) : String(part)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(value), number > 0, number <= Int(UInt32.max) else { return nil }
        values.append(number)
    }
    return Array(Set(values)).sorted()
}

struct ConnectionProfileSettings: View {
    @Environment(Monitor.self) private var m
    @State private var draft: ConnectionProfile?

    var body: some View {
        Section {
            Toggle("Enable connection profiles", isOn: m.binding(\.connectionProfilesEnabled))
            if m.settings.connectionProfilesEnabled {
                Picker("Active profile", selection: m.binding(\.activeProfileID)) {
                    Text("Choose a profile").tag(Optional<UUID>.none)
                    ForEach(m.settings.connectionProfiles) { Text($0.name).tag(Optional($0.id)) }
                }
                if m.settings.activeProfile == nil {
                    Text("Choose a profile to verify the connection. Until then its status is unknown.")
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
            ForEach(m.settings.connectionProfiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name).bold()
                        Text(profile.locations.map(\.label).joined(separator: ", ")).foregroundStyle(.secondary)
                        Text(profile.asns.map { "AS\($0)" }.joined(separator: ", ")).font(.caption)
                    }
                    Spacer()
                    Button("Edit") { draft = profile }
                    Button(role: .destructive) {
                        m.update { $0.connectionProfiles.removeAll { $0.id == profile.id } }
                    } label: { Image(systemName: "trash") }
                    .help("Delete \(profile.name)").accessibilityLabel("Delete \(profile.name)")
                }
            }
            Button("Add Profile...") { draft = ConnectionProfile() }
        } header: {
            Text("Connection profiles")
        } footer: {
            Footer("The selected profile requires an allowed country or city AND an exact ASN match. Existing country, provider and site rules still apply. Disabling profiles keeps them saved.")
        }
        .sheet(item: $draft) { profile in
            ConnectionProfileEditor(profile: profile) { saved in
                m.update { settings in
                    if let index = settings.connectionProfiles.firstIndex(where: { $0.id == saved.id }) {
                        settings.connectionProfiles[index] = saved
                    } else { settings.connectionProfiles.append(saved) }
                    if settings.activeProfileID == nil { settings.activeProfileID = saved.id }
                }
            }.environment(m)
        }
    }
}

private struct ConnectionProfileEditor: View {
    @Environment(Monitor.self) private var m
    @Environment(\.dismiss) private var dismiss
    @State var profile: ConnectionProfile
    let onSave: (ConnectionProfile) -> Void
    @State private var pending = PendingSiteLocation()
    @State private var asns = ""

    private var locations: [SiteLocation] { normalizedLocations(pending.appending(to: profile.locations)) }
    private var valid: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !locations.isEmpty && parseASNs(asns) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection profile").font(.headline)
            Form {
                TextField("Name", text: $profile.name)
                ForEach(profile.locations, id: \.key) { location in
                    RemovableRow(onRemove: { profile.locations.removeAll { $0.key == location.key } }) { Text(location.label) }
                }
                HStack {
                    CountryPicker(title: pending.country.flatMap(Countries.name) ?? "Choose Country...") { pending.country = $0 }
                    TextField("City (optional)", text: $pending.city)
                    Button("Add") { pending.add(to: &profile.locations) }.disabled(pending.country == nil)
                }
                TextField("Allowed ASNs", text: $asns, prompt: Text("AS64500, AS64501"))
                Text("Use exact network numbers, separated by commas. A country with no city allows that whole country.")
                    .font(.caption).foregroundStyle(.secondary)
                if !asns.isEmpty && parseASNs(asns) == nil {
                    Text("Enter valid AS numbers from 1 to 4294967295.").foregroundStyle(Tone.error.textColor)
                }
                if let location = m.geo.location, let code = location.countryCode, let asn = location.asn {
                    Button("Use Current Location and ASN") {
                        profile.locations = [SiteLocation(countryCode: code, country: location.country ?? code, city: location.city)]
                        pending = PendingSiteLocation()
                        asns = "AS\(asn)"
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.locations = locations
                    profile.asns = parseASNs(asns) ?? []
                    onSave(profile)
                    dismiss()
                }.disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 520, height: 440)
        .onAppear { asns = profile.asns.map { "AS\($0)" }.joined(separator: ", ") }
    }
}
