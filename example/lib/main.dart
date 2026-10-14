import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:plugin_wifi_connect/plugin_wifi_connect.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const MethodChannel _nativeChannel =
      MethodChannel('plugin_wifi_connect');

  final TextEditingController _ssidController =
      TextEditingController(text: 'Helmetcam2_07c106');//Helmetcam2_07c106  SC2S_e22116
  final TextEditingController _passwordController =
      TextEditingController(text: '1234567890');
  final TextEditingController _prefixController = TextEditingController();
  final List<String> _logs = <String>[];
  bool _isWpa3 = false;
  bool _userAction = false;

  @override
  void initState() {
    super.initState();
    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'log') {
        _log('native: ${call.arguments}');
      }
    });
  }

  void _log(String message) {
    DateTime currentTime = DateTime.now();
    // final formatter = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');
    final formatter = DateFormat('HH:mm:ss.SSS');
    final formattedTime = formatter.format(currentTime);
    log('[WifiTest] [$formattedTime] $message');
    final DateTime now = DateTime.now();
    final String ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logs.insert(0, '$ts  $message');
    });
  }

  Future<void> _run(String name, Future<Object?> Function() action) async {

    _log('$name ...');
    try {
      final Object? value = await action();
      _log('$name => $value');
    } on PlatformException catch (e) {
      _log('$name => PlatformException(${e.code}: ${e.message})');
    } catch (e) {
      _log('$name => $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('wifi_connect test')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  TextField(
                    controller: _ssidController,
                    decoration: const InputDecoration(labelText: 'SSID'),
                  ),
                  TextField(
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  TextField(
                    controller: _prefixController,
                    decoration: const InputDecoration(labelText: 'SSID prefix'),
                  ),
                  SwitchListTile(
                    title: const Text('WPA3 (SAE)'),
                    value: _isWpa3,
                    onChanged: (v) => setState(() => _isWpa3 = v),
                  ),
                  SwitchListTile(
                    title: const Text('userAction (系统确认弹窗)'),
                    value: _userAction,
                    onChanged: (v) => setState(() => _userAction = v),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: () => _run('isEnabled',
                          () => PluginWifiConnect.isEnabled),
                      child: const Text('isEnabled'),
                    ),
                    ElevatedButton(
                      onPressed: () =>
                          _run('activateWifi', PluginWifiConnect.activateWifi),
                      child: const Text('activateWifi'),
                    ),
                    ElevatedButton(
                      onPressed: () => _run(
                          'deactivateWifi', PluginWifiConnect.deactivateWifi),
                      child: const Text('deactivateWifi'),
                    ),
                    ElevatedButton(
                      onPressed: () => _run('ssid', () => PluginWifiConnect.ssid),
                      child: const Text('getSSID'),
                    ),
                    ElevatedButton(
                      onPressed: () => _run('connect',
                          () => PluginWifiConnect.connect(_ssidController.text)),
                      child: const Text('connect'),
                    ),
                    ElevatedButton(
                      onPressed: () => _run(
                          'secureConnect',
                          () => PluginWifiConnect.connectToSecureNetwork(
                              _ssidController.text, _passwordController.text,
                              isWpa3: _isWpa3, userAction: _userAction)),
                      child: const Text('secureConnect'),
                    ),
                    ElevatedButton(
                      onPressed: () => _run(
                          'connectByPrefix',
                          () => PluginWifiConnect.connectByPrefix(
                              _prefixController.text)),
                      child: const Text('prefixConnect'),
                    ),
                    ElevatedButton(
                      onPressed: () => _run(
                          'securePrefixConnect',
                          () => PluginWifiConnect.connectToSecureNetworkByPrefix(
                              _prefixController.text, _passwordController.text)),
                      child: const Text('securePrefix'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent),
                      onPressed: () =>
                          _run('disconnect', PluginWifiConnect.disconnect),
                      child: const Text('disconnect'),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              flex: 3,
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _logs.length,
                itemBuilder: (context, index) => Text(
                  _logs[index],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
