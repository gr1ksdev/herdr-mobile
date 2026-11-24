import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/local_transport.dart';

class _FakePty implements LocalPtyPlatform {
  final output = StreamController<Uint8List>();
  final written = <List<int>>[];
  var prepared = 0;
  var started = 0;
  var stopped = false;

  @override
  Future<void> prepare() async {
    prepared++;
  }

  @override
  Future<String> start() async {
    started++;
    return LocalTransport.paneId;
  }

  @override
  Stream<Uint8List> output(String paneId) => output.stream;

  @override
  Future<void> write(String paneId, List<int> bytes) async {
    written.add(bytes);
  }

  @override
  Future<void> stop(String paneId) async {
    stopped = true;
  }

  @override
  void dispose() {}
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakePty pty;
  late LocalTransport transport;

  setUp(() {
    pty = _FakePty();
    transport = LocalTransport(pty);
  });

  tearDown(() async {
    await transport.close();
    await pty.output.close();
  });

  test('ping answers without starting the runtime', () async {
    final pong = await transport.request('ping');
    expect(pong['version'], 'local-0.1.0');
    expect(pty.prepared, 0);
    expect(pty.started, 0);
  });

  test('snapshot prepares the runtime once and offers one pane', () async {
    final first = await transport.request('session.snapshot');
    final second = await transport.request('session.snapshot');

    expect(pty.prepared, 1);
    expect(pty.started, 1);
    final snapshot = first['snapshot'] as Map<String, dynamic>;
    expect((snapshot['panes'] as List).single, containsPair('pane_id', LocalTransport.paneId));
    expect((snapshot['workspaces'] as List).single, containsPair('workspace_id', LocalTransport.workspaceId));
    expect(second, equals(first));
  });

  test('read keeps ANSI, honours lines and caps the ring', () async {
    final small = LocalTransport(pty, maxLines: 3);
    await small.request('session.snapshot');
    for (final line in ['one', '\x1b[31mred\x1b[0m', 'three', 'four']) {
      pty.output.add(_bytes('$line\n'));
      await _flush();
    }

    final all = await small.request('pane.read');
    final read = all['read'] as Map<String, dynamic>;
    expect(read['text'], '\x1b[31mred\x1b[0m\nthree\nfour\n');
    expect(read['truncated'], true);

    final last = (await small.request('pane.read', {'lines': 1}))['read'] as Map<String, dynamic>;
    expect(last['text'], 'four\n');
    await small.close();
  });

  test('send text and keys reach the pty as bytes', () async {
    await transport.request('session.snapshot');
    await transport.request('pane.send_text', {'text': 'ls'});
    await transport.request('pane.send_keys', {'keys': ['enter', 'ctrl+c']});
    await transport.request('pane.send_input', {'text': 'pwd', 'keys': ['enter']});

    expect(
      pty.written.map((bytes) => utf8.decode(bytes)).toList(),
      ['ls', '\r', '\x03', 'pwd', '\r'],
    );
  });

  test('unknown keys are refused instead of guessed', () async {
    await transport.request('session.snapshot');
    expect(
      transport.request('pane.send_keys', {'keys': ['super+p']}),
      throwsA(isA<HerdrApiException>()),
    );
  });

  test('events ack before output and carry the pane id', () async {
    await transport.request('session.snapshot');
    final events = transport.events(const []);
    final seen = <Map<String, dynamic>>[];
    final sub = events.listen(seen.add);
    addTearDown(sub.cancel);
    await _flush();

    expect(seen.single, containsPair('event', subscriptionStartedEvent));

    pty.output.add(_bytes('hello\n'));
    await _flush();
    expect(seen.last['event'], 'pane_updated');
    final pane = (seen.last['data'] as Map)['pane'] as Map<String, dynamic>;
    expect(pane['pane_id'], LocalTransport.paneId);
  });

  test('unsupported methods and file channels fail loudly', () async {
    expect(transport.request('workspace.create'), throwsA(isA<HerdrApiException>()));
    expect(transport.supportsFiles, false);
    expect(transport.statFile('/tmp'), throwsA(isA<RemoteFileException>()));
    expect(transport.openExec('true'), throwsA(isA<HerdrTransportException>()));
  });

  test('close stops the pty', () async {
    await transport.request('session.snapshot');
    await transport.close();
    expect(pty.stopped, true);
  });
}
