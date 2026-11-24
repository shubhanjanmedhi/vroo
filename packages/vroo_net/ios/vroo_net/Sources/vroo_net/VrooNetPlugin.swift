// SPDX-License-Identifier: GPL-3.0-or-later
import Flutter
import Network
import NetworkExtension
import UIKit

/// iOS side of vroo_net; the channel contract is in lib/src/channel_vroo_net.dart. Box datagrams go over a Dart
/// socket, since iOS routes 192.168.4.x over the box's Wi-Fi by itself. Internet datagrams go over NWConnections
/// here, pinned to mobile data while the box's Wi-Fi (which has no internet) is up.
public class VrooNetPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var joinedSsid: String?
  private var connections: [String: (connection: NWConnection, viaCellular: Bool)] = [:]
  private let queue = DispatchQueue(label: "vroo_net")

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VrooNetPlugin()
    registrar.addMethodCallDelegate(
      instance, channel: FlutterMethodChannel(name: "vroo_net", binaryMessenger: registrar.messenger()))
    FlutterEventChannel(name: "vroo_net/events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "joinBox":
      let ssid = args["ssid"] as! String
      let config = (args["password"] as? String).map { NEHotspotConfiguration(ssid: ssid, passphrase: $0, isWEP: false) }
        ?? NEHotspotConfiguration(ssid: ssid)
      joinedSsid = ssid
      join(config, result)
    case "joinSetupNetwork":
      join(NEHotspotConfiguration(ssidPrefix: "Vroo-setup-"), result)
    case "leaveBox":
      if let ssid = joinedSsid { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
      joinedSsid = nil
      result(nil)
    case "sendToInternet":
      sendToInternet(
        host: args["host"] as! String, port: args["port"] as! Int,
        data: (args["data"] as! FlutterStandardTypedData).data, viaCellular: args["viaCellular"] as? Bool ?? false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 'joined', 'denied' when the rider says no, otherwise 'needsManualJoin' (for example when the app may not
  /// configure hotspots, as under a free Apple ID): the rider then joins in Settings.
  private func join(_ config: NEHotspotConfiguration, _ result: @escaping FlutterResult) {
    config.joinOnce = false
    NEHotspotConfigurationManager.shared.apply(config) { error in
      var outcome = error == nil ? "joined" : "needsManualJoin"
      if let error = error as NSError?, error.domain == NEHotspotConfigurationErrorDomain {
        switch NEHotspotConfigurationError(rawValue: error.code) {
        case .alreadyAssociated: outcome = "joined"
        case .userDenied: outcome = "denied"
        default: break
        }
      }
      DispatchQueue.main.async { result(outcome) }
    }
  }

  private func sendToInternet(host: String, port: Int, data: Data, viaCellular: Bool) {
    let key = "\(host):\(port)"
    var entry = connections[key]
    if entry?.viaCellular != viaCellular {  // the first send, or the box's Wi-Fi came or went
      entry?.connection.cancel()
      entry = (open(host: host, port: port, viaCellular: viaCellular, key: key), viaCellular)
      connections[key] = entry
    }
    entry!.connection.send(content: data, completion: .contentProcessed { _ in })
  }

  private func open(host: String, port: Int, viaCellular: Bool, key: String) -> NWConnection {
    let params = NWParameters.udp
    if viaCellular { params.requiredInterfaceType = .cellular }
    let connection = NWConnection(
      host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: params)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard case .failed = state, let connection else { return }
      connection.cancel()
      DispatchQueue.main.async {  // the next send opens a new one
        if self?.connections[key]?.connection === connection { self?.connections[key] = nil }
      }
    }
    receive(connection, host: host, port: port)
    connection.start(queue: queue)
    return connection
  }

  private func receive(_ connection: NWConnection, host: String, port: Int) {
    connection.receiveMessage { [weak self] data, _, _, error in
      if let data, !data.isEmpty {
        DispatchQueue.main.async {
          self?.sink?(["kind": "internet", "host": host, "port": port, "data": FlutterStandardTypedData(bytes: data)])
        }
      }
      if error == nil { self?.receive(connection, host: host, port: port) }
    }
  }
}
