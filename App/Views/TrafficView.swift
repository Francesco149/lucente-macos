import LucenteKit
import SwiftUI

/// Every byte to and from the lights, newest at the bottom.
struct TrafficView: View {
    @Environment(LightStore.self) private var store
    @State private var filter = ""

    private var entries: [TrafficLog.Entry] {
        guard !filter.isEmpty else { return store.traffic.entries }
        return store.traffic.entries.filter {
            $0.light.localizedCaseInsensitiveContains(filter) || $0.hex.localizedCaseInsensitiveContains(filter)
                || $0.message.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onAppear { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                .onChange(of: entries.last?.id) { _, last in proxy.scrollTo(last, anchor: .bottom) }
        }
    }

    private var table: some View {
        Table(entries) {
            TableColumn("Time") { entry in
                Text(entry.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100, max: 120)
            TableColumn("Light", value: \.light)
                .width(min: 80, ideal: 120, max: 200)
            TableColumn("") { entry in
                Image(systemName: entry.direction.symbol)
                    .foregroundStyle(entry.direction.tint)
                    .help(entry.direction.label)
            }
            .width(18)
            TableColumn("Data") { entry in
                Text(entry.bytes.isEmpty ? entry.message : entry.hex)
                    .font(entry.bytes.isEmpty ? .body : .body.monospaced())
                    .textSelection(.enabled)
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItem {
                Button("Copy All", systemImage: "doc.on.doc") {
                    let text = entries.map { "\($0.date.formatted(.iso8601))\t\($0.light)\t\($0.direction.label)\t\($0.bytes.isEmpty ? $0.message : $0.hex)" }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.joined(separator: "\n"), forType: .string)
                }
            }
            ToolbarItem {
                Button("Clear", systemImage: "trash") { store.traffic.clear() }
            }
        }
        .overlay {
            if store.traffic.entries.isEmpty {
                ContentUnavailableView("No Traffic Yet", systemImage: "antenna.radiowaves.left.and.right", description: Text("Commands and replies appear here as they happen."))
            }
        }
    }
}

extension TrafficLog.Direction {
    var symbol: String {
        switch self {
        case .sent: "arrow.up.right"
        case .received: "arrow.down.left"
        case .event: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .sent: .blue
        case .received: .green
        case .event: .secondary
        }
    }

    var label: String {
        switch self {
        case .sent: "Sent"
        case .received: "Received"
        case .event: "Event"
        }
    }
}
