import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'local_pty_platform.dart' show localControlName, localEventName, localMethodName;

/// Main-isolate side of the local PTY.
///
/// Platform channels belong to the root isolate, while `LocalTransport` runs
/// in a worker. This bridge is the only place that touches both: it forwards
/// raw byte arrays between them and never parses ANSI or herdr JSON.
class LocalPtyBridge {
  LocalPtyBridge._();

  static final instance = LocalPtyBridge._();

  final _control = ReceivePort();
  final _listeners = <SendPort>{};
  final _method = const MethodChannel(localMethodName);
  var _started = false;

  /// Called once from `main()` after the binding is ready.
  void init() {
    if (_started) return;
    _started = true;
    IsolateNameServer.registerPortWithName(_control.sendPort, localControlName);
    _control.listen((Object? raw) => _onControl(raw! as List<Object?>));
    const EventChannel(localEventName).receiveBroadcastStream().listen(
      (Object? data) {
        if (data is Uint8List) {
          for (final port in _listeners) port.send(['bytes', data]);
        }
      },
      onError: (Object error, StackTrace stack) {
        for (final port in _listeners) port.send(['error', error.toString()]);
      },
      onDone: () {
        for (final port in _listeners) port.send(['done']);
      },
    );
  }

  Future<void> _onControl(List<Object?> message) async {
    switch (message[0]) {
      case 'listen':
        _listeners.add(message[1]! as SendPort);
      case 'unlisten':
        _listeners.remove(message[1]);
      case 'call':
        final reply = message[4]! as SendPort;
        final id = message[1]!;
        try {
          final result = await _method.invokeMethod<Object?>(
            message[2]! as String,
            message[3] as Map<String, Object?>?,
          );
          reply.send([id, 'ok', result]);
        } on Object catch (error) {
          reply.send([id, 'err', error.toString()]);
        }
    }
  }
}
