import CoreLocation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LocationBridge") {
      LocationBridge.register(with: registrar)
    }
  }
}

/// The app's location check (App Store guideline 3.2.2(viii)): Core Location, "When In Use" only, one position when
/// asked - never in the background. Channel `bx/location` (lib/security/geo_gate.dart):
///   status       -> "notDetermined" | "granted" | "denied" | "restricted" | "servicesOff"
///   request      -> asks for When In Use (only while not determined yet), answers the status after the choice
///   current      -> {latitude, longitude, accuracy, simulated}, or an error (denied / timeout / unavailable)
///   openSettings -> opens this app's page in Settings
final class LocationBridge: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var authWaiters: [FlutterResult] = []
  private var fixWaiters: [FlutterResult] = []
  private var timeout: DispatchWorkItem?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "bx/location", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LocationBridge(), channel: channel)
  }

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(status())
    case "request":
      if manager.authorizationStatus == .notDetermined {
        authWaiters.append(result)
        manager.requestWhenInUseAuthorization()
      } else {
        result(status())
      }
    case "current":
      current(result)
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func status() -> String {
    switch manager.authorizationStatus {
    case .notDetermined:
      return "notDetermined"
    case .restricted:
      return "restricted"
    case .denied:
      return CLLocationManager.locationServicesEnabled() ? "denied" : "servicesOff"
    default:
      return "granted"
    }
  }

  private func current(_ result: @escaping FlutterResult) {
    guard status() == "granted" else {
      result(FlutterError(code: "denied", message: nil, details: nil))
      return
    }
    fixWaiters.append(result)
    if fixWaiters.count > 1 { return } // one request answers everyone waiting
    manager.requestLocation()
    let t = DispatchWorkItem { [weak self] in
      self?.finish(FlutterError(code: "timeout", message: nil, details: nil))
    }
    timeout = t
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: t)
  }

  private func finish(_ value: Any?) {
    timeout?.cancel()
    timeout = nil
    let waiting = fixWaiters
    fixWaiters = []
    waiting.forEach { $0(value) }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let l = locations.last else { return }
    finish([
      "latitude": l.coordinate.latitude,
      "longitude": l.coordinate.longitude,
      "accuracy": l.horizontalAccuracy,
      "simulated": l.sourceInformation?.isSimulatedBySoftware ?? false,
    ])
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    finish(FlutterError(code: "unavailable", message: error.localizedDescription, details: nil))
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if manager.authorizationStatus == .notDetermined { return }
    let waiting = authWaiters
    authWaiters = []
    let s = status()
    waiting.forEach { $0(s) }
  }
}
