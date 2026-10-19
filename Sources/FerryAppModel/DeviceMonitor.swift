import Foundation
import Observation
import FerryCore

/// Finds out who is holding a phone's USB interface (macOS: IORegistry `UsbExclusiveOwner`).
public protocol ExclusiveAccessInspecting: Sendable {
    func holderName(vendorID: UInt16, productID: UInt16) -> String?
}

/// Watches USB for phones and owns the open MTP session for the selected one.
@MainActor @Observable
public final class DeviceMonitor {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var selectedDeviceID: DeviceID?
    public private(set) var state: DeviceConnectionState = .noDevice
    public private(set) var session: DeviceSession?
    public private(set) var storages: [StorageInfo] = []
    /// Bumped whenever a new session opens, so dependants can reset.
    public private(set) var sessionGeneration = 0
    /// A phone the user ejected; left alone until they connect it again or it is unplugged.
    public private(set) var ejectedDeviceID: DeviceID?
    /// Charge of the connected phone in percent, if it reports one. Read on connect, then about once a minute.
    public private(set) var batteryPercent: Int?
    @ObservationIgnored public var batteryInterval: TimeInterval = 60
    @ObservationIgnored private var lastBatteryCheck = Date.distantPast

    @ObservationIgnored private let backend: DeviceBackend
    @ObservationIgnored private let inspector: ExclusiveAccessInspecting?
    @ObservationIgnored private let pollInterval: Double
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var openFailures = 0
    @ObservationIgnored private var pollsUntilRetry = 0
    @ObservationIgnored private var isRefreshing = false
    /// Set by the app while a transfer runs, so polling never adds requests to a busy phone.
    @ObservationIgnored public var isTransferActive: () -> Bool = { false }
    /// Called after anything that may change the session, storages or state.
    @ObservationIgnored public var onChange: () -> Void = {}

    public init(backend: DeviceBackend, inspector: ExclusiveAccessInspecting? = nil, pollInterval: Double = 1.5) {
        self.backend = backend
        self.inspector = inspector
        self.pollInterval = pollInterval
    }

    public var hasMultipleDevices: Bool { devices.count > 1 }

    public var selectedDevice: DiscoveredDevice? { devices.first { $0.id == selectedDeviceID } }

    /// Total and free bytes across the phone's storage areas (internal plus any SD card).
    public var storageTotals: (capacity: UInt64, free: UInt64) {
        storages.reduce((UInt64(0), UInt64(0))) { (ProgressMath.add($0.0, $1.capacityBytes), ProgressMath.add($0.1, $1.freeBytes)) }
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.pollInterval ?? 1.5
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func select(_ id: DeviceID) {
        if id == ejectedDeviceID { return connectEjected(id) } // clicking an ejected phone connects it again
        guard id != selectedDeviceID else { return }
        closeSession()
        selectedDeviceID = id
        openFailures = 0
        pollsUntilRetry = 0
        Task { await refresh() }
    }

    /// Retries opening immediately (e.g. after the user quits a competing app).
    public func retryNow() {
        Task { await retry() }
    }

    /// `retryNow`, finishing when the attempt has (or, if a poll is already running, hasn't) been made.
    public func retry() async {
        pollsUntilRetry = 0
        if case .disconnected = state { state = .noDevice }
        await refresh()
    }

    public var isBusy: Bool {
        if case .busy = state { return true }
        return false
    }

    /// Lets go of the selected phone so it can be unplugged safely or used by another app. Refused while copying.
    /// Returns once the session is closed (any in-flight phone request finishes first).
    public func eject() async {
        guard let s = session, !isTransferActive() else { return }
        ejectedDeviceID = selectedDeviceID
        session = nil
        storages = []
        batteryPercent = nil
        onChange() // stop browsing and previews before closing
        await s.close()
        state = .ejected(s.summary)
        onChange()
    }

    /// Reconnects a phone the user ejected.
    public func connectEjected(_ id: DeviceID? = nil) {
        guard let ejected = ejectedDeviceID, id == nil || id == ejected else { return }
        ejectedDeviceID = nil
        if selectedDeviceID != ejected {
            selectedDeviceID = ejected
            openFailures = 0
        }
        state = .noDevice
        retryNow()
    }

    /// Called by browsing or transfers when the phone vanished mid-operation.
    public func reportDisconnected() {
        guard let summary = session?.summary ?? state.device else { return }
        closeSession()
        state = .disconnected(summary)
        onChange()
    }

    /// One discovery pass. Safe to call repeatedly; overlapping calls are ignored.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; onChange() }

        let found: [DiscoveredDevice]
        do { found = try await backend.discover() } catch {
            Log.warning("monitor", "USB scan failed: \(error)")
            return
        }
        devices = found
        // An ejected phone that has been unplugged is treated as new when it comes back.
        if let ejected = ejectedDeviceID, !found.contains(where: { $0.id == ejected }) { ejectedDeviceID = nil }

        // Selected phone gone?
        if let id = selectedDeviceID, !found.contains(where: { $0.id == id }) {
            if let summary = session?.summary ?? state.device, session != nil {
                closeSession()
                state = .disconnected(summary)
            } else if case .disconnected = state {
                // keep showing "disconnected" until another phone appears
            } else {
                state = .noDevice
            }
            selectedDeviceID = nil
        }

        if selectedDeviceID == nil {
            guard let pick = found.first(where: { $0.mode == .fileTransfer }) ?? found.first else {
                if case .disconnected = state {} else { state = .noDevice }
                return
            }
            selectedDeviceID = pick.id
            openFailures = 0
            pollsUntilRetry = 0
        }
        guard let id = selectedDeviceID, let device = found.first(where: { $0.id == id }) else { return }
        if id == ejectedDeviceID { return }

        if device.mode == .chargingOnly {
            if session != nil { closeSession() }
            state = .chargingOnly(device.summary)
            return
        }

        if let session {
            // Locked phones reveal storage once unlocked; keep checking (but never during a transfer).
            if case .locked = state, !isTransferActive() {
                await loadStorages(session)
            } else if state.isReady, !isTransferActive(), Date().timeIntervalSince(lastBatteryCheck) >= batteryInterval {
                await refreshBattery(session)
            }
            return
        }

        if pollsUntilRetry > 0 { pollsUntilRetry -= 1; return }
        await open(device)
    }

    private func open(_ device: DiscoveredDevice) async {
        do {
            let s = try await backend.openSession(device.id)
            guard selectedDeviceID == device.id else { await s.close(); return }
            session = s
            sessionGeneration += 1
            openFailures = 0
            await loadStorages(s)
            if state.isReady { await refreshBattery(s) }
        } catch let e as FerryError {
            openFailures += 1
            switch e {
            case .deviceBusy:
                var holder = inspector?.holderName(vendorID: device.summary.vendorID, productID: device.summary.productID)
                // A failed earlier attempt by Zapdrop itself can leave the phone claimed; never blame ourselves —
                // the busy guidance already says to unplug and reconnect.
                if let h = holder, h.localizedCaseInsensitiveContains(ProcessInfo.processInfo.processName) { holder = nil }
                state = .busy(device.summary, holder: holder)
                pollsUntilRetry = 2
            case .notAuthorized:
                // Keep waiting for the user for about a minute, then say the phone isn't responding normally.
                state = openFailures >= 25 ? .unsupported(device.summary, reason: "never finished connecting")
                                           : .awaitingAuthorization(device.summary)
                pollsUntilRetry = 1
            case .chargingOnlyMode:
                state = .chargingOnly(device.summary)
            case .deviceDisconnected, .noDevice:
                state = .noDevice
            case .deviceLocked:
                state = .locked(device.summary)
            default:
                state = openFailures >= 3 ? .unsupported(device.summary, reason: "\(e)") : .awaitingAuthorization(device.summary)
                pollsUntilRetry = min(openFailures * 2, 10)
            }
        } catch {
            state = .unsupported(device.summary, reason: "\(error)")
        }
    }

    private func loadStorages(_ s: DeviceSession) async {
        do {
            let list = try await s.storages()
            storages = list
            state = list.isEmpty ? .locked(s.summary) : .ready(s.summary)
        } catch FerryError.deviceDisconnected {
            reportDisconnected()
        } catch {
            state = .locked(s.summary)
        }
    }

    private func refreshBattery(_ s: DeviceSession) async {
        lastBatteryCheck = Date()
        let percent = await s.batteryPercent()
        if session === s { batteryPercent = percent }
    }

    private func closeSession() {
        if let s = session {
            Task { await s.close() }
        }
        session = nil
        storages = []
        batteryPercent = nil
    }
}
