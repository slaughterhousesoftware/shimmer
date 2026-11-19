// Inline PC pairing and the address-entry popover used by the Servers tab.
import Accessibility
import Foundation
import SwiftUI
import Observation

struct PCPairingTarget: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    var startImmediately = false
    /// A PS5 to register (PlayStationPairingPane), not a Sunshine PC.
    var isPlayStation = false
}

/// Owns one attempt. A cancelled or replaced attempt cannot select a saved
/// PC later, even if its network operation completes after cancellation.
@MainActor @Observable
final class PCPairingFlow {
    enum Result { case paired(String), failed(String) }
    private(set) var pin: String?
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func start(pin: String, pair: @escaping @MainActor (String) async -> Result,
               completed: @escaping @MainActor (String) -> Void) {
        guard !isRunning else { return }
        generation += 1
        let run = generation
        self.pin = pin
        error = nil
        isRunning = true
        isCancelling = false
        task = Task { [weak self] in
            let result = await pair(pin)
            guard let self, generation == run else { return }
            isRunning = false
            isCancelling = false
            task = nil
            guard !Task.isCancelled else {
                self.pin = nil
                error = nil
                return
            }
            switch result {
            case .paired(let id): completed(id)
            case .failed(let message):
                self.pin = nil
                error = message
            }
        }
    }

    func cancel() {
        guard isRunning else { reset(); return }
        isCancelling = true
        task?.cancel()
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        pin = nil
        error = nil
        isRunning = false
        isCancelling = false
    }
}

struct PCPairingPane: View {
    @Environment(AppModel.self) private var model
    let target: PCPairingTarget
    let failed: ((String, String) -> Void)?
    let paired: (String) -> Void
    @State private var flow = PCPairingFlow()
    @State private var address: String

    init(target: PCPairingTarget, failed: ((String, String) -> Void)? = nil,
         paired: @escaping (String) -> Void) {
        self.target = target
        self.failed = failed
        self.paired = paired
        _address = State(initialValue: target.address)
    }

    var body: some View {
        Group {
            if let error = flow.error {
                recoveryForm(error: error)
            } else {
                pairingBody
            }
        }
        .task { if target.startImmediately { begin() } }
        .onChange(of: flow.error) { _, error in
            if let error { failed?(address, error) }
        }
        .onDisappear { flow.reset() }
    }

    private var pairingBody: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        // The sidebar's grey avatar for a machine not added yet.
                        NearbyHostAvatar(name: target.name, address: address, isPlayStation: false, size: 64)
                            .padding(.bottom, 4)
                            .accessibilityHidden(true)
                        Text(address == target.address ? target.name : address)
                            .font(.system(size: 18, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(address).font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let pin = flow.pin {
                        Text("Enter this code in the pairing prompt on your PC.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pin)
                            .id(pin)
                            .font(.system(size: 34, weight: .medium, design: .monospaced))
                            .tracking(8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        if flow.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(flow.isCancelling ? "Cancelling…" : "Waiting for your PC…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Cancel") { flow.cancel() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(flow.isCancelling)
                    } else {
                        VStack(spacing: 16) {
                            Text("Pair with this PC to stream its apps to your Mac.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Pair PC", action: begin)
                                .buttonStyle(.borderedProminent)
                                .disabled(model.pairingInFlight)
                        }
                    }
                }
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func recoveryForm(error: String) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        NearbyHostAvatar(name: target.name, address: address, isPlayStation: false, size: 64)
                            .accessibilityHidden(true)
                        Text(target.name)
                            .font(.system(size: 18, weight: .semibold))
                        Text(address)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        PCConnectionErrorBanner(message: error)
                        HStack(spacing: 10) {
                            TextField("IP address or hostname", text: $address)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.large)
                                .disableAutocorrection(true)
                                .accessibilityLabel("PC IP address or hostname")
                                .onSubmit(begin)
                            Button("Try Again", action: begin)
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.roundedRectangle(radius: 5))
                                .controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                                .disabled(model.pairingInFlight || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .font(.system(size: 14))
                .frame(maxWidth: 400)
                .padding(.horizontal, 28)
                .padding(.top, 68)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func begin() {
        guard !model.pairingInFlight else { return }
        let pairingAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pairingAddress.isEmpty else { return }
        address = pairingAddress
        flow.start(pin: model.generatePairingPIN()) { pin in
            if let id = await model.pair(hostnameOrIP: pairingAddress, pin: pin) {
                if model.hosts.contains(where: { $0.id == id }) { return .paired(id) }
                return .failed("Pairing finished, but this PC couldn't be added. Try again.")
            }
            return .failed(model.pairingMessage ?? "Couldn't pair this PC. Try again.")
        } completed: { id in paired(id) }
    }
}

/// What answers at an address someone typed: a PS5 (PlayStation discovery
/// on UDP 9302) or a Sunshine PC (its HTTP port). Both are asked at once, so
/// the person never has to say which kind of machine it is.
enum AddressLookup {
    enum Outcome: Equatable {
        case playStation(name: String, address: String)
        case pc(address: String)
        /// Nothing answered; the message says what to check.
        case nothing(String)
    }

    static let notFound = "Address not found. Check the IP address or hostname."

    static func nothingAnswered(at address: String) -> String {
        "Nothing answered at \(address). Make sure the PC is on with Sunshine running, "
            + "or that the PS5 is on or in rest mode with Remote Play turned on."
    }

    /// Sunshine's HTTP port, or the one typed after a single colon ("pc:47999").
    static func sunshineEndpoint(_ address: String) -> (host: String, port: Int) {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) {
            return (String(parts[0]), port)
        }
        return (address, 47989)
    }

    /// The IPv4 address PlayStation discovery needs; a literal is returned as is.
    static func ipv4(for host: String) async -> String? {
        var probe = in_addr()
        if inet_pton(AF_INET, host, &probe) == 1 { return host }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(result) }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let found: String? = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var addr = $0.pointee.sin_addr
                    return inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil
                        ? String(cString: text) : nil
                }
                continuation.resume(returning: found)
            }
        }
    }

    static func identify(_ address: String) async -> Outcome {
        await identify(address,
                       resolve: { await ipv4(for: $0) },
                       playStation: { ip in
                           guard let status = await PlayStationDiscovery.probe(address: ip) else { return nil }
                           return status.hostName ?? "PS5"
                       },
                       sunshine: { host, port in
                           if case .reachable = await HostReachability.measureRTT(host: host, port: port) { return true }
                           return false
                       })
    }

    /// `playStation` returns the console's name, nil when it doesn't answer. A PS5 is
    /// found by its IPv4 address and saved under it; a PC keeps what was typed.
    static func identify(_ address: String,
                         resolve: @escaping @Sendable (String) async -> String?,
                         playStation: @escaping @Sendable (String) async -> String?,
                         sunshine: @escaping @Sendable (String, Int) async -> Bool) async -> Outcome {
        let endpoint = sunshineEndpoint(address)
        // An IPv6 literal or "host:port" is never a PS5 (discovery is IPv4).
        let ip = address.contains(":") ? nil : await resolve(address)
        if ip == nil, !address.contains(":") { return .nothing(notFound) }
        enum Answer: Sendable { case playStation(String, String), pc, none }
        return await withTaskGroup(of: Answer.self) { group in
            if let ip {
                group.addTask {
                    if let name = await playStation(ip) { return .playStation(name, ip) }
                    return .none
                }
            }
            group.addTask { await sunshine(endpoint.host, endpoint.port) ? .pc : .none }
            for await answer in group {
                switch answer {
                case .playStation(let name, let ip):
                    group.cancelAll()
                    return .playStation(name: name, address: ip)
                case .pc:
                    group.cancelAll()
                    return .pc(address: address)
                case .none: continue
                }
            }
            return .nothing(nothingAnswered(at: address))
        }
    }
}

/// Add by Address: one field for a PC or a PS5. The popover stays open while
/// the address is looked up, and says so in place when nothing answers.
struct ManualAddressPopover: View {
    /// True for an address already saved: it is selected, not looked up.
    var isSaved: (String) -> Bool = { _ in false }
    let cancel: () -> Void
    let add: (AddressLookup.Outcome) -> Void
    @State private var address = ""
    @State private var looking = false
    @State private var problem: String?
    @FocusState private var addressFocused: Bool

    init(initialAddress: String = "", isSaved: @escaping (String) -> Bool = { _ in false },
         cancel: @escaping () -> Void, add: @escaping (AddressLookup.Outcome) -> Void) {
        self.isSaved = isSaved
        self.cancel = cancel
        self.add = add
        _address = State(initialValue: initialAddress)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add by Address")
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
            Text("Enter the IP address or hostname of a PC running Sunshine, or of a PS5.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                TextField("192.168.1.10 or gaming-pc.local", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .focused($addressFocused)
                    .disabled(looking)
                    .onSubmit(submit)
                    .accessibilityLabel("IP address or hostname")
                if let problem {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(problem)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 24) {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button(action: submit) {
                    ZStack {
                        Text("Add").opacity(looking ? 0 : 1)
                        if looking { ProgressView().controlSize(.small) }
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedAddress.isEmpty || looking)
                .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 360)
        .onAppear { addressFocused = true }
        .onChange(of: address) { problem = nil }
    }

    private func submit() {
        guard !trimmedAddress.isEmpty, !looking else { return }
        let typed = trimmedAddress
        if isSaved(typed) {
            add(.pc(address: typed))
            return
        }
        looking = true
        problem = nil
        Task {
            let outcome = await AddressLookup.identify(typed)
            looking = false
            if case .nothing(let message) = outcome {
                problem = message
                addressFocused = true
                AccessibilityNotification.Announcement(message).post()
            } else {
                add(outcome)
            }
        }
    }
}
