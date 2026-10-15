import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';

// TODO: Check this lint warning
// ignore: avoid_classes_with_only_static_members
class PluginWifiConnect {
  static const MethodChannel _channel = MethodChannel('plugin_wifi_connect');

  static bool _handlerRegistered = false;
  static void Function(String message)? _onLog;

  /// Callback invoked with native log messages sent by the plugin (ohos side).
  ///
  /// A MethodChannel supports only one handler, which the plugin registers
  /// internally; do NOT call `setMethodCallHandler` on the
  /// 'plugin_wifi_connect' channel yourself — use this callback instead.
  static set onLog(void Function(String message)? callback) {
    _onLog = callback;
    if (callback != null) {
      _registerHandler();
    }
  }

  static void Function(String message)? get onLog => _onLog;

  static void _registerHandler() {
    if (_handlerRegistered) {
      return;
    }
    _handlerRegistered = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'log' && call.arguments is String) {
        _onLog?.call(call.arguments as String);
      }
    });
  }

  /// The [hasCandidateConfig] method queries in real time whether a persisted
  /// candidate config (netId) already exists for [ssid]. When [prefix] is true,
  /// the strongest scanned network whose ssid starts with [ssid] is checked
  /// instead. Only works on ohos; other platforms always return false.
  static Future<bool> hasCandidateConfig(String ssid,
      {bool prefix = false}) async {
    if (Platform.isOhos) {
      final bool? exists = await _channel.invokeMethod<bool>(
        'hasCandidateConfig',
        <String, dynamic>{'ssid': ssid, 'prefix': prefix},
      );
      return exists ?? false;
    }
    return false;
  }

  /// The [isEnabled] method returns true if WiFi is enabled.
  /// The method only works on android and ohos.
  static Future<bool> get isEnabled async {
    if (Platform.isAndroid || Platform.isOhos) {
      final bool enabled = await _channel.invokeMethod('isWifiEnabled');
      return enabled;
    }
    return false;
  }

  /// The [activateWifi] method turns on WiFi only works on android and ohos.
  static Future<void> activateWifi() async {
    if (Platform.isAndroid || Platform.isOhos) {
      await _channel.invokeMethod('activateWifi');
    }
  }

  /// The [deactivateWifi] method turns off wifi only works on android and ohos.
  static Future<void> deactivateWifi() async {
    if (Platform.isAndroid || Platform.isOhos) {
      await _channel.invokeMethod('deactivateWifi');
    }
  }

  /// The [connect] method attempts to connect to wifi
  /// matching explicitly the [ssid] parameter.
  static Future<bool?> connect(String ssid, {bool saveNetwork = false}) async {
    final bool? connected = await _channel.invokeMethod<bool>(
      'connect',
      <String, dynamic>{'ssid': ssid, 'saveNetwork': saveNetwork},
    );
    return connected;
  }

  /// The [connectByPrefix] method attempts to connect to the nearest wifi
  /// network with the ssid prefix matching the [ssidPrefix] parameter.
  static Future<bool?> connectByPrefix(String ssidPrefix,
      {bool saveNetwork = false}) async {
    final bool? connected = await _channel.invokeMethod<bool>(
      'prefixConnect',
      <String, dynamic>{'ssid': ssidPrefix, 'saveNetwork': saveNetwork},
    );
    return connected;
  }

  /// The [connectToSecureNetwork] method attempts to connect to wifi
  /// matching explicitly the [ssid] parameter. This will fail if the
  /// [password] doesn't match or the [isWep] parameter isn't set correctly.
  /// Android does not support WEP Networks.
  static Future<bool?> connectToSecureNetwork(String ssid, String password,
      {bool isWep = false,
      bool isWpa3 = false,
      bool saveNetwork = false,
      bool isHidden = false,
      bool userAction = true}) async {
    final bool? connected = await _channel.invokeMethod<bool>(
      'secureConnect',
      <String, dynamic>{
        'ssid': ssid,
        'password': password,
        'saveNetwork': saveNetwork,
        'isWep': isWep,
        'isWpa3': isWpa3,
        'isHidden': isHidden,
        'userAction': userAction,
      },
    );
    return connected;
  }

  /// The [connectToSecureNetworkByPrefix] method attempts to connect to the nearest
  /// wifi network with the ssid prefix matching the [ssidPrefix] parameter.
  /// This will fail if the [password] doesn't match or the [isWep] parameter
  /// isn't set correctly. Android does not support WEP Networks.
  static Future<bool?> connectToSecureNetworkByPrefix(
      String ssidPrefix, String password,
      {bool isWep = false,
      bool isWpa3 = false,
      bool saveNetwork = false}) async {
    final bool? connected = await _channel.invokeMethod<bool>(
      'securePrefixConnect',
      <String, dynamic>{
        'ssid': ssidPrefix,
        'password': password,
        'saveNetwork': saveNetwork,
        'isWep': isWep,
        'isWpa3': isWpa3,
      },
    );
    return connected;
  }

  /// The [disconnect] method disconnects from the wifi network if the network
  /// was connected to using one of the [connect] methods.
  static Future<bool?> disconnect() => _channel.invokeMethod('disconnect');

  /// register wifi network
  static Future<void> register() async {}

  /// unregister wifi network
  static Future<void> unregister() async {}

  /// The [ssid] getter returns the currently connected ssid.
  static Future<String?> get ssid async {
    final String? ssid = await _channel.invokeMethod<String>('getSSID');
    return ssid;
  }
}
