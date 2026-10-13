import MapKit
import SwiftUI

/// Past anchorages, newest first.
struct AnchorageLogView: View {
    @EnvironmentObject var engine: AnchorWatchEngine

    var body: some View {
        List {
            if engine.anchorages.isEmpty {
                Text("Each time you raise the anchor after ten minutes or more, the stay is saved here: where, depth, rode, bottom, how far you swung and the track.")
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.anchorages) { entry in
                NavigationLink {
                    AnchorageDetailView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.name).font(.headline)
                            if entry.isLocked {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityLabel("Locked")
                            }
                            Spacer()
                            if entry.held == .dragged {
                                Label("Dragged", systemImage: "exclamationmark.triangle.fill").labelStyle(.iconOnly).foregroundStyle(.red)
                            } else if entry.held == .well {
                                Label("Held", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                            }
                        }
                        Text("\(entry.dropped.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())) · \(stay(entry))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(engine.units.format(entry.depth)) deep · \(engine.units.format(entry.rodeOut)) out · \(entry.bottom.lowercased())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if entry.isLocked {
                        Button { engine.setAnchorageLocked(entry.id, false) } label: { Label("Unlock", systemImage: "lock.open") }
                            .tint(.gray)
                    } else {
                        Button(role: .destructive) { withAnimation { engine.deleteAnchorage(entry.id) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { engine.setAnchorageLocked(entry.id, true) } label: { Label("Lock", systemImage: "lock") }
                            .tint(.blue)
                    }
                }
            }
            if !engine.anchorages.isEmpty {
                Text("Swipe left to delete an anchorage, or lock it so it can't be deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Anchorage Log")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stay(_ e: AnchorageEntry) -> String {
        let minutes = Int(e.raised.timeIntervalSince(e.dropped) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// One stay: the track round the anchor, the figures, how it held, and notes.
struct AnchorageDetailView: View {
    @EnvironmentObject var engine: AnchorWatchEngine
    @Environment(\.dismiss) private var dismiss
    @State var entry: AnchorageEntry

    private var units: Units { engine.units }

    var body: some View {
        Form {
            Section {
                Map(initialPosition: .region(MKCoordinateRegion(center: entry.coordinate,
                                                                latitudinalMeters: max(entry.radius, entry.maxDistance) * 3,
                                                                longitudinalMeters: max(entry.radius, entry.maxDistance) * 3))) {
                    MapCircle(center: entry.coordinate, radius: entry.radius)
                        .foregroundStyle(.green.opacity(0.15)).stroke(.green, lineWidth: 2)
                    if entry.track.count > 1 {
                        MapPolyline(coordinates: entry.trackCoordinates).stroke(.purple, lineWidth: 2)
                    }
                    Annotation("Anchor", coordinate: entry.coordinate) {
                        Text(anchorGlyph).font(.title3)
                    }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
            Section {
                TextField("Name", text: $entry.name)
                Picker("How did it hold?", selection: $entry.held) {
                    ForEach(AnchorageEntry.Held.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Notes: holding, shelter, swell, neighbours…", text: $entry.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section {
                LabeledContent("Dropped", value: entry.dropped.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Raised", value: entry.raised.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Depth when set", value: units.format(entry.depth))
                LabeledContent("Rode out", value: units.format(entry.rodeOut))
                LabeledContent("Bottom", value: entry.bottom)
                LabeledContent("Alarm radius", value: units.format(entry.radius))
                LabeledContent("Furthest swing", value: units.format(entry.maxDistance))
                LabeledContent("Position", value: String(format: "%.5f, %.5f", entry.latitude, entry.longitude))
            }
            Section {
                Toggle(isOn: $entry.isLocked) { Label("Locked", systemImage: "lock") }
                if !entry.isLocked {
                    Button("Delete this anchorage", role: .destructive) {
                        engine.deleteAnchorage(entry.id)
                        dismiss()
                    }
                }
            } footer: {
                Text(entry.isLocked ? "Locked: it can't be deleted until you unlock it." : "Lock it to keep it from being deleted.")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: entry) { _, changed in engine.updateAnchorage(changed) }
    }
}
