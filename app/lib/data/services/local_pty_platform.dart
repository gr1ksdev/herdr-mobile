import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'herdr_transport.dart';
import 'local_transport.dart';

const _controlName = 'herdr.local.control';
const _methodName = 'dev.herdrmobile/local-runtime';
const _eventName = 'dev.herdrmobile/local-runtime/output';

/// Main-isolate side of the local PTY.
///
/// Platform channels belong to the root isolate, while [LocalTransport] runs
/// in a worker. This bridge is the only place that touches both: it forwards
/// raw byte arrays between them and never parses ANSI or herdr JSON.
class LocalPtyBridge {
  LocalPtyBridge._();

  static final instance = LocalPtyBridge._();

  final _control = ReceivePort();
  final _listeners = <SendPort>{};
  final _method = const MethodChannel(_methodName);
  var _started = false;

  /// Called once from `main()` after the binding is ready.
  void init() {
    if (_started) return;
    _started = true;
    IsolateNameServer.registerPortWithName(_control.sendPort, _controlName);
    _control.listen((Object? raw) => _onControl(raw! as List<Object?>));
    const EventChannel(_eventName).receiveBroadcastStream().listen(
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
          final result = await _method.invokeMethod<Object?>(message[2]! as String, message[3] as Map<String, Object?>?);
          reply.send([id, 'ok', result]);
        } on Object catch (error) {
          reply.send([id, 'err', error.toString()]);
        }
    }
  }
}

/// Worker-isolate side of the local PTY. Created by a top-level
/// [TransportBuilder] so it can live behind [IsolateTransport].
class MethodChannelLocalPty implements LocalPtyPlatform {
  MethodChannelLocalPty() {
    final control = IsolateNameServer.lookupPortByName(_controlName);
    if (control == null) {
      throw const HerdrTransportException('The local PTY bridge is not ready', fatal: true);
    }
    _control = control;
    _replies.listen((Object? raw) => _onReply(raw! as List<Object?>));
    _output.listen((Object? raw) => _onOutput(raw! as List<Object?>));
    control.send(['listen', _output.sendPort]);
  }

  late final SendPort _control;
  final _replies = ReceivePort();
  final _output = ReceivePort();
  final _pending = <Object, Completer<Object?>>{};
  final _outputController = StreamController<Uint8List>.broadcast();
  var _nextId = 0;

  void _onReply(List<Object?> message) {
    final completer = _pending.remove(message[0]);
    if (completer == null || completer.isCompleted) return;
    if (message[1] == 'ok') {
      completer.complete(message[2]);
    } else {
      completer.completeError(HerdrTransportException(message[2] as String? ?? 'Local PTY call failed'));
    }
  }

  void _onOutput(List<Object?> message) {
    switch (message[0]) {
      case 'bytes':
        if (!_outputController.isClosed) _outputController.add(message[1]! as Uint8List);
      case 'error':
        if (!_outputController.isClosed) {
          _outputController.addError(HerdrTransportException(message[1] as String? ?? 'Local PTY failed'));
        }
      case 'done':
        if (!_outputController.isClosed) _outputController.close();
    }
  }

  Future<Object?> _call(String method, Map<String, Object?> params) {
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _control.send(['call', id, method, params, _replies.sendPort]);
    return completer.future;
  }

  @override
  Future<void> prepare() async {
    await _call('prepare', const {});
  }

  @override
  Future<String> start() async {
    await _call('start', const {});
    return LocalTransport.paneId;
  }

  @override
  Stream<Uint8List> output(String paneId) => _outputController.stream;

  @override
  Future<void> write(String paneId, List<int> bytes) async {
    await _call('write', {'bytes': Uint8List.fromList(bytes)});
  }

  @override
  Future<void> stop(String paneId) async {
    await _call('stop', const {});
  }

  @override
  void dispose() {
    _control.send(['unlisten', _output.sendPort]);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(const HerdrTransportException('Local PTY closed', fatal: true));
      }
    }
    _pending.clear();
    _outputController.close();
    _output.closePort();
    _replies.closePort();
  }
}
