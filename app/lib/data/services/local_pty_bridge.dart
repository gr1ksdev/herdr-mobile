import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'local_pty_platform.dart' show localEventName, localMethodName;

/// Main-isolate side of the local PTY.
///
/// Platform channels belong to the root isolate, while `LocalTransport` runs
/// in a worker. The worker's ports are handed over through the transport's
/// `config` (see `createLocalTransport`), so no isolate-name registry is
/// needed and this class never runs off the main isolate.
class LocalPtyBridge {
  LocalPtyBridge() {
    _control.listen((Object? raw) => _onControl(raw! as List<Object?>));
    const EventChannel(localEventName).receiveBroadcastStream().listen(
      (Object? data) {
        if (data is Uint8List) {
          for (final port in _listeners) {
            port.send(['bytes', data]);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        for (final port in _listeners) {
          port.send(['error', error.toString()]);
        }
      },
      onDone: () {
        for (final port in _listeners) {
          port.send(['done']);
        }
      },
    );
  }

  /// Passed to the worker through `IsolateTransport.config`.
  SendPort get control => _control.sendPort;

  final _control = ReceivePort();
  final _listeners = <SendPort>{};
  final _method = const MethodChannel(localMethodName);

  Future<void> _onControl(List<Object?> message) async {
    SendPort? reply;
    Object? id;
    try {
      switch (message[0]) {
        case 'listen':
          _listeners.add(message[1]! as SendPort);
        case 'unlisten':
          _listeners.remove(message[1]);
        case 'call':
          reply = message[4] as SendPort?;
          id = message[1];
          final result = await _method.invokeMethod<Object?>(
            message[2]! as String,
            message[3] as Map<String, Object?>?,
          );
          reply?.send([id, 'ok', result]);
      }
    } on Object catch (error) {
      // Never leave the worker's completer pending: that would look like a
      // hung connection instead of a failed call.
      reply?.send([id, 'err', error.toString()]);
    }
  }

  Future<void> dispose() async {
    await _control.close();
  }
}
