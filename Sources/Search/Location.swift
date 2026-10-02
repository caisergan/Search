import AppKit
import CoreLocation
import WebKit

// Where this Mac is, for the pages you let know.
//
// On the Mac, WebKit leaves where the computer is to the app. Safari hands
// it positions itself; a page in any other app that asked, and was allowed,
// was left waiting for ever — a weather site's "finding your location…"
// that never ended. Search now does what Safari does: WebKit's C geolocation
// provider, set on the process pool before its first process, starts macOS's
// CoreLocation when a page you allowed asks (see Permissions.swift), hands
// over each position as it comes, and stops once no page is asking.
//
// The first time, macOS asks whether Search may know where the Mac is.
// Refused there, the page is told the position couldn't be had, and the top
// of the page says where macOS keeps that switch.

@MainActor
final class LocationFeed: NSObject, CLLocationManagerDelegate {
    static let shared = LocationFeed()

    private let manager = CLLocationManager()
    /// The WKGeolocationManager WebKit named when it asked.
    private var geolocation: UnsafeRawPointer?
    private var updating = false
    private var provided = false
    /// Told once a launch that macOS refuses.
    var onRefused: (() -> Void)?
    private var told = false

    /// For the bench: the last position handed over, and when; how many
    /// times WebKit asked, and whether the provider is in.
    private(set) var handed: (latitude: Double, longitude: Double, accuracy: Double, at: Date)?
    private(set) var asked = 0
    var installed: Bool { provided }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// What macOS says about Search and Location Services.
    var authorization: String {
        switch manager.authorizationStatus {
        case .notDetermined: return "not asked yet"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "allowed"
        @unknown default: return "unknown"
        }
    }

    func provide(for pool: WKProcessPool) {
        guard !provided else { return }
        provided = WebKitGeolocation.install(on: pool)
    }

    // MARK: - WebKit asking

    fileprivate func start(_ geolocation: UnsafeRawPointer) {
        asked += 1
        self.geolocation = geolocation
        updating = true
        switch manager.authorizationStatus {
        case .notDetermined:
            // macOS asks; the updates start once it is answered.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            refuse()
            return
        default:
            manager.startUpdatingLocation()
        }
        // A position already known, and recent, goes at once: a page asking a
        // second time needn't wait for the next fix.
        if let known = manager.location, -known.timestamp.timeIntervalSinceNow < 60 { hand(known) }
    }

    fileprivate func stop() {
        updating = false
        manager.stopUpdatingLocation()
    }

    fileprivate func precise(_ on: Bool) {
        manager.desiredAccuracy = on ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
    }

    // MARK: - CoreLocation answering

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard updating else { return }
            switch status {
            case .authorizedAlways: self.manager.startUpdatingLocation()
            case .denied, .restricted: refuse()
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { hand(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated {
            switch code {
            case .denied: refuse()
            // Still looking: CoreLocation says so, and goes on.
            case .locationUnknown: break
            default: WebKitGeolocation.failed(geolocation, "Location unavailable")
            }
        }
    }

    private func hand(_ location: CLLocation) {
        guard updating, let geolocation else { return }
        handed = (location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy, Date())
        WebKitGeolocation.changed(geolocation, location)
    }

    private func refuse() {
        WebKitGeolocation.failed(geolocation, "User denied Geolocation")
        guard !told else { return }
        told = true
        onRefused?()
    }

    /// System Settings › Privacy & Security › Location Services.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// WebKit's C geolocation provider, by name — the interface Safari's own is
/// set through. Nothing here runs unless every name is there; a WebKit
/// without them leaves pages waiting, as they did.
@MainActor
private enum WebKitGeolocation {
    typealias Ref = UnsafeRawPointer
    private static let wk = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)

    private static func name<T>(_ symbol: String, _: T.Type) -> T? {
        guard let wk, let found = dlsym(wk, symbol) else { return nil }
        return unsafeBitCast(found, to: T.self)
    }

    private static let didChange = name("WKGeolocationManagerProviderDidChangePosition", (@convention(c) (Ref, Ref) -> Void).self)
    private static let didFail = name("WKGeolocationManagerProviderDidFailToDeterminePositionWithErrorMessage", (@convention(c) (Ref, Ref?) -> Void).self)
    private static let position = name("WKGeolocationPositionCreate_b",
        (@convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double) -> Ref?).self)
    private static let makeString = name("WKStringCreateWithUTF8CString", (@convention(c) (UnsafePointer<CChar>) -> Ref?).self)
    private static let release = name("WKRelease", (@convention(c) (Ref) -> Void).self)

    /// The provider as WebKit reads it (WKGeolocationProviderV1): a version
    /// and a pointer, then three callbacks. Made once, for as long as the app
    /// runs.
    private static var provider: UnsafeMutableRawPointer?

    static func install(on pool: WKProcessPool) -> Bool {
        guard let managerOf = name("WKContextGetGeolocationManager", (@convention(c) (Ref) -> Ref?).self),
              let set = name("WKGeolocationManagerSetProvider", (@convention(c) (Ref, UnsafeRawPointer) -> Void).self),
              didChange != nil, didFail != nil, position != nil, makeString != nil, release != nil,
              let geolocation = managerOf(Unmanaged.passUnretained(pool).toOpaque())
        else { return false }
        typealias Updating = @convention(c) (Ref?, Ref?) -> Void
        typealias Accuracy = @convention(c) (Ref?, Bool, Ref?) -> Void
        let start: Updating = { manager, _ in
            guard let raw = manager.map({ UInt(bitPattern: $0) }) else { return }
            MainActor.assumeIsolated {
                guard let manager = UnsafeRawPointer(bitPattern: raw) else { return }
                LocationFeed.shared.start(manager)
            }
        }
        let stop: Updating = { _, _ in
            MainActor.assumeIsolated { LocationFeed.shared.stop() }
        }
        let accuracy: Accuracy = { _, on, _ in
            MainActor.assumeIsolated { LocationFeed.shared.precise(on) }
        }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: 40)
        memory.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)
        let callbacks: [UnsafeRawPointer] = [
            unsafeBitCast(start, to: UnsafeRawPointer.self),
            unsafeBitCast(stop, to: UnsafeRawPointer.self),
            unsafeBitCast(accuracy, to: UnsafeRawPointer.self),
        ]
        for (index, callback) in callbacks.enumerated() {
            memory.storeBytes(of: callback, toByteOffset: 16 + 8 * index, as: UnsafeRawPointer.self)
        }
        provider = memory
        set(geolocation, memory)
        return true
    }

    /// A fix from CoreLocation, as the page's Position: seconds since 1970,
    /// and altitude, heading and speed only where CoreLocation has them.
    static func changed(_ manager: Ref, _ location: CLLocation) {
        let altitude = location.verticalAccuracy >= 0
        guard let made = position?(
            location.timestamp.timeIntervalSince1970, location.coordinate.latitude, location.coordinate.longitude,
            location.horizontalAccuracy, altitude, location.altitude, altitude, location.verticalAccuracy,
            location.course >= 0, location.course, location.speed >= 0, location.speed
        ) else { return }
        didChange?(manager, made)
        release?(made)
    }

    static func failed(_ manager: Ref?, _ message: String) {
        guard let manager else { return }
        let text = message.withCString { makeString?($0) }
        didFail?(manager, text)
        if let text { release?(text) }
    }
}
