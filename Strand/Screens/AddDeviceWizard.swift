import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Add a device — guided, branching wizard
//
// Different bands pair COMPLETELY differently, so this wizard asks the device TYPE first, then gives
// type-specific prep guidance and runs the RIGHT scan/connect for that type:
//
//   • WHOOP 4.0 / WHOOP 5.0 (MG)  → BLEManager's present-scan (`scanForWhoops`), targeted at the
//     chosen WHOOP family via `model.presentWhoopScan(model:)`. Lists nearby straps from
//     `ble.discoveredWhoops` (a present-only mode that never auto-connects).
//   • Heart-rate strap (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) → its OWN
//     isolated `StandardHRSource` scanning the standard 0x180D HR service. Lists from `discovered`.
//
// Registration goes through `model.registerDevice(_:makeActive:)` → DeviceRegistry; the
// SourceCoordinator reacts to the active-device change and connects. The wizard never touches
// BLEManager directly — only the AppModel pass-throughs. WHOOP-FIRST: WHOOP is the primary band; the
// type list shows it first and a footer reiterates it. Renders cleanly with nothing nearby (the type
// picker, every prep step, and the searching/empty pick state all need no hardware).

struct AddDeviceWizard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let onClose: () -> Void

    // MARK: Flow

    /// What the user is adding. Drives the prep copy AND which scan/register path runs.
    enum DeviceType: Identifiable, Hashable {
        case whoop5mg
        case whoop4
        case hrStrap
        var id: Self { self }

        var isWhoop: Bool { self == .whoop4 || self == .whoop5mg }
        var whoopModel: WhoopModel? {
            switch self {
            case .whoop4:   return .whoop4
            case .whoop5mg: return .whoop5mg
            case .hrStrap:  return nil
            }
        }
    }

    enum Step { case type, prep, pick, confirm }

    @State private var step: Step = .type
    @State private var type: DeviceType?

    // The chosen strap, in whichever shape its path produces.
    /// A WHOOP picked from `discoveredWhoops` (uuid / advertised name / rssi).
    @State private var pickedWhoop: (uuid: String, name: String, rssi: Int)?
    /// A generic HR strap picked from the StandardHRSource scan.
    @State private var pickedStrap: StandardHRSource.DiscoveredStrap?

    @State private var nameDraft = ""
    /// After registering, ask whether to make the new device active.
    @State private var askMakeActive = false

    /// Discovery-only HR source for the strap path. Never persists (no-op closure) and is never asked
    /// to `connect` — we only read its `@Published discovered` / `scanning` while scanning. Built once.
    @StateObject private var hrScanner: StandardHRSource

    init(live: LiveState, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _hrScanner = StateObject(wrappedValue: StandardHRSource(
            live: live, deviceId: "scan-preview", persist: { _ in }))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    switch step {
                    case .type:    typeStep
                    case .prep:    prepStep
                    case .pick:    pickStep
                    case .confirm: confirmStep
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase)
        // Stop whichever scan is live whenever the sheet goes away (belt-and-braces alongside the
        // per-transition stops below) so neither central keeps scanning after dismiss.
        .onDisappear { stopAllScans() }
        // After adding, offer to make the new device active.
        .alert("Make this your active device?",
               isPresented: $askMakeActive) {
            Button("Not now", role: .cancel) { finishAdd(makeActive: false) }
            Button("Make active") { finishAdd(makeActive: true) }
        } message: {
            Text("Make \(confirmName) your active device now? It will provide your live data. You can change this any time.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if step != .type {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let sub = headerSubtitle {
                    Text(sub).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Button(action: { stopAllScans(); onClose() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var headerTitle: LocalizedStringKey {
        switch step {
        case .type:    return "Add a device"
        case .prep:    return LocalizedStringKey(type.map(typeTitle) ?? "Add a device")
        case .pick:    return "Pick your device"
        case .confirm: return "Name & confirm"
        }
    }

    private var headerSubtitle: LocalizedStringKey? {
        switch step {
        case .type:    return "What are you adding?"
        case .prep:    return "Get it ready, then scan."
        case .pick:    return "Tap the one that's yours."
        case .confirm: return nil
        }
    }

    // MARK: Step 1 — type picker

    @ViewBuilder private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            typeRow(.whoop5mg, icon: "applewatch.side.right",
                    title: "WHOOP 5.0 / MG",
                    subtitle: "Newer WHOOP band — experimental in NOOP")
            typeRow(.whoop4, icon: "applewatch.side.right",
                    title: "WHOOP 4.0",
                    subtitle: "NOOP's primary, fully-supported band")
            typeRow(.hrStrap, icon: "heart.circle",
                    title: "Heart-rate strap",
                    subtitle: "Polar, Wahoo, Coospo, Garmin HRM, Amazfit Helio broadcast")

            Text("Coming soon").strandOverline().padding(.top, 8)
            comingSoonRow(icon: "applewatch", title: "Garmin watch")
            comingSoonRow(icon: "waveform.path.ecg.rectangle", title: "Amazfit / Zepp")
            comingSoonRow(icon: "square.and.arrow.down", title: "Import from Oura or Fitbit")

            whoopFirstNote
        }
    }

    private func typeRow(_ t: DeviceType, icon: String, title: String, subtitle: String) -> some View {
        Button {
            type = t
            step = .prep
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private func comingSoonRow(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 30)
                .accessibilityHidden(true)
            Text(title).font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            StatePill("Soon", tone: .neutral, showsDot: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface(cornerRadius: 14)
        .opacity(0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), coming soon")
    }

    // MARK: Step 2 — type-specific prep + guidance

    @ViewBuilder private var prepStep: some View {
        if let type {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: type.isWhoop ? "applewatch.side.right" : "heart.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(typeTitle(type)).font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }

                if type == .whoop5mg {
                    experimentalNote
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(prepInstructions(type).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            Text(line)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frostedCardSurface(cornerRadius: 14)

                Button {
                    startScan(for: type)
                    step = .pick
                } label: {
                    Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .accessibilityLabel("Scan for \(typeTitle(type))")
            }
        }
    }

    /// Type-specific "get it ready" guidance — the point of the branching wizard.
    private func prepInstructions(_ t: DeviceType) -> [String] {
        switch t {
        case .whoop4:
            return [
                "Put your WHOOP 4.0 on your wrist and make sure it's awake.",
                "Make sure it's NOT connected to the official WHOOP app right now.",
                "NOOP will look for it nearby.",
            ]
        case .whoop5mg:
            return [
                "WHOOP 5.0 / MG bonds to one device at a time — unpair it from the official WHOOP app first.",
                "Put the band into pairing mode, on your wrist and awake.",
                "NOOP will look for it nearby.",
            ]
        case .hrStrap:
            return [
                "Wake your strap — put it on, or dampen the contacts.",
                "Make sure it isn't connected to another app (a bike computer, the brand's own app…).",
                "NOOP will look for it nearby.",
            ]
        }
    }

    // MARK: Step 3 — pick from the live scan

    @ViewBuilder private var pickStep: some View {
        if let type {
            if type.isWhoop {
                // Observe BLEManager directly so the list updates as `discoveredWhoops` grows. The
                // subview holds the @ObservedObject; the wizard owns selection + scan lifecycle.
                WhoopPickList(ble: model.ble) { strap in
                    pickedWhoop = strap
                    pickedStrap = nil
                    nameDraft = strap.name.isEmpty ? typeTitle(type) : strap.name
                    model.stopWhoopScan()
                    step = .confirm
                } onRescan: {
                    model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
                }
            } else {
                HRPickList(scanner: hrScanner) { strap in
                    pickedStrap = strap
                    pickedWhoop = nil
                    nameDraft = strap.name
                    hrScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    hrScanner.scan()
                }
            }
        }
    }

    // MARK: Step 4 — name + confirm

    @ViewBuilder private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SignalBars(rssi: confirmRSSI)
                VStack(alignment: .leading, spacing: 2) {
                    Text(confirmAdvertisedName).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(confirmBrand).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)

            Text("Name").strandOverline()
            TextField("Device name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(12)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Device name")

            Button("Add") { askMakeActive = true }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .frame(maxWidth: .infinity)
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 4)
        }
    }

    // MARK: Confirm-step derived values

    private var confirmName: String {
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? confirmAdvertisedName : n
    }
    private var confirmAdvertisedName: String {
        if let pickedWhoop { return pickedWhoop.name.isEmpty ? (type.map(typeTitle) ?? "Device") : pickedWhoop.name }
        if let pickedStrap { return pickedStrap.name }
        return type.map(typeTitle) ?? "Device"
    }
    private var confirmBrand: String {
        if type?.isWhoop == true { return "WHOOP" }
        if let pickedStrap { return brandGuess(from: pickedStrap.name) }
        return "Heart-rate strap"
    }
    private var confirmRSSI: Int {
        pickedWhoop?.rssi ?? pickedStrap?.rssi ?? -70
    }

    // MARK: Actions

    private func goBack() {
        switch step {
        case .type:    break
        case .prep:    step = .type
        case .pick:    stopAllScans(); step = .prep
        case .confirm:
            // Re-enter the pick step and restart its scan so the user can choose a different device.
            if let type { startScan(for: type) }
            pickedWhoop = nil; pickedStrap = nil
            step = .pick
        }
    }

    private func startScan(for type: DeviceType) {
        if type.isWhoop {
            model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
        } else {
            hrScanner.scan()
        }
    }

    private func stopAllScans() {
        model.stopWhoopScan()
        hrScanner.stopScan()
    }

    /// Build the right `PairedDevice` for the chosen path, register it, optionally activate, then close.
    private func finishAdd(makeActive: Bool) {
        stopAllScans()
        let now = Int(Date().timeIntervalSince1970)
        let name = confirmName
        let device: PairedDevice

        if let pickedWhoop, let type, let wm = type.whoopModel {
            // WHOOP: full capability set; id namespaced by uuid; model "4.0" / "5.0 MG".
            let modelLabel = (wm == .whoop4) ? "4.0" : "5.0 MG"
            device = PairedDevice(
                id: "whoop-\(pickedWhoop.uuid)",
                brand: "WHOOP",
                model: modelLabel,
                nickname: name,
                peripheralId: pickedWhoop.uuid,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedStrap {
            // Generic HR strap: HR + HRV only.
            device = PairedDevice(
                id: "strap-\(pickedStrap.id.uuidString)",
                brand: brandGuess(from: pickedStrap.name),
                model: pickedStrap.name,
                nickname: name == pickedStrap.name ? nil : name,
                peripheralId: pickedStrap.id.uuidString,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else {
            onClose(); return
        }

        model.registerDevice(device, makeActive: makeActive)
        onClose()
    }

    // MARK: Copy / helpers

    private func typeTitle(_ t: DeviceType) -> String {
        switch t {
        case .whoop5mg: return "WHOOP 5.0 / MG"
        case .whoop4:   return "WHOOP 4.0"
        case .hrStrap:  return "Heart-rate strap"
        }
    }

    private var experimentalNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text("WHOOP 5.0 / MG support is newer and still experimental in NOOP.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var whoopFirstNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    /// Best-effort brand from the advertised name; neutral fallback for unknown straps.
    private func brandGuess(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("polar") { return "Polar" }
        if lower.contains("wahoo") || lower.contains("tickr") { return "Wahoo" }
        if lower.contains("coospo") { return "Coospo" }
        if lower.contains("garmin") || lower.contains("hrm") { return "Garmin" }
        if lower.contains("scosche") || lower.contains("rhythm") { return "Scosche" }
        if lower.contains("magene") { return "Magene" }
        if lower.contains("amazfit") || lower.contains("helio") || lower.contains("zepp") { return "Amazfit" }
        return "Heart-rate strap"
    }
}

// MARK: - WHOOP pick list (observes BLEManager's present-scan)

/// The WHOOP family pick step. Holds `@ObservedObject ble` so the list re-renders as the present-scan
/// surfaces straps in `discoveredWhoops`. Pure UI — selection + scan lifecycle live in the wizard.
private struct WhoopPickList: View {
    @ObservedObject var ble: BLEManager
    let onSelect: ((uuid: String, name: String, rssi: Int)) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: true, onRescan: onRescan)
            let found = ble.discoveredWhoops.sorted { $0.rssi > $1.rssi }
            if found.isEmpty {
                SearchingCard()
            } else {
                ForEach(found, id: \.uuid) { strap in
                    DiscoveredRow(name: strap.name.isEmpty ? "WHOOP" : strap.name,
                                  subtitle: "WHOOP",
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }
}

// MARK: - HR strap pick list (observes its own StandardHRSource)

private struct HRPickList: View {
    @ObservedObject var scanner: StandardHRSource
    let onSelect: (StandardHRSource.DiscoveredStrap) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { strap in
                    DiscoveredRow(name: strap.name,
                                  subtitle: brandGuess(from: strap.name),
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }

    private func brandGuess(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("polar") { return "Polar" }
        if lower.contains("wahoo") || lower.contains("tickr") { return "Wahoo" }
        if lower.contains("coospo") { return "Coospo" }
        if lower.contains("garmin") || lower.contains("hrm") { return "Garmin" }
        if lower.contains("scosche") || lower.contains("rhythm") { return "Scosche" }
        if lower.contains("magene") { return "Magene" }
        if lower.contains("amazfit") || lower.contains("helio") || lower.contains("zepp") { return "Amazfit" }
        return "Heart-rate strap"
    }
}

// MARK: - Shared pick-step pieces

private struct ScanStatusBar: View {
    let searching: Bool
    let onRescan: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            StatePill(searching ? "Searching…" : "Idle",
                      tone: searching ? .accent : .neutral,
                      pulsing: searching)
            Spacer()
            Button("Rescan", action: onRescan)
                .font(StrandFont.subhead)
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
        }
    }
}

private struct SearchingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().tint(StrandPalette.accent)
            Text("Searching…")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Make sure it's awake and not connected elsewhere.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .frostedCardSurface(cornerRadius: 14)
    }
}

private struct DiscoveredRow: View {
    let name: String
    let subtitle: String
    let rssi: Int
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                SignalBars(rssi: rssi)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), signal \(SignalBars.level(for: rssi)) of 4")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Add device wizard") {
    let model = AppModel()
    return AddDeviceWizard(live: model.live, onClose: {})
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
