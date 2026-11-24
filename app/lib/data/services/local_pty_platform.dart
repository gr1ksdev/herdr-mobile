import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'herdr_transport.dart';
import 'local_transport.dart';

/// Names shared with [LocalPtyBridge] in `local_pty_bridge.dart`. This file
/// must stay free of Flutter imports: it is loaded inside the transport
/// worker isolate, where platform channels do not exist.
const localControlName = 'herdr.local.control';
const localMethodName = 'dev.herdrmobile/local-runtime';
const localEventName = 'dev.herdrmobile/local-runtime/output';

/// Worker-isolate side of the local PTY. Created by a top-level
/// [TransportBuilder] so it can live behind [IsolateTransport].
class MethodChannelLocalPty implements LocalPtyPlatform {
  MethodChannelLocalPty() {
    final control = IsolateNameServer.lookupPortByName(localControlName);
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
