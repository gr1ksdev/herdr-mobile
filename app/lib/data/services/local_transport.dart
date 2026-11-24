import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/remote_file.dart';
import '../models/web_bridge.dart';
import 'herdr_transport.dart';

/// The native side of a Debian rootfs running on the phone itself.
///
/// Implemented by the Android plugin: it owns the foreground service, the
/// PTY and the PRoot process. Nothing here opens a socket or execs a shell;
/// this class only turns PTY bytes into the small slice of the herdr API that
/// the board and the pane use. Swapping in `herdr-core` later means replacing
/// this transport, not the UI.
abstract interface class LocalPtyPlatform {
  /// Makes the rootfs available (download and verify on first use). Safe to
  /// call again while the runtime is already prepared.
  Future<void> prepare();

  /// Starts the shell session. Returns the pane id, which must be
  /// [LocalTransport.paneId].
  Future<String> start();

  /// Raw PTY output for [paneId], including ANSI escapes.
  Stream<Uint8List> output(String paneId);

  /// Types [bytes] into the PTY.
  Future<void> write(String paneId, List<int> bytes);

  /// Ends the session. [LocalTransport.close] is the only caller.
  Future<void> stop(String paneId);

  /// Releases the ports/channels to the native side after [stop].
  void dispose();
}

/// A `HerdrTransport` backed by a Debian PTY on this device.
///
/// It deliberately implements only what the pane reads:
/// `ping`, `session.snapshot`, `pane.read`, `pane.send_text`,
/// `pane.send_keys`, `pane.send_input` and `events.subscribe`. Everything
/// else answers `HerdrApiException('unsupported', ...)` the way an older
/// herdr answers an unknown method, so `HerdrApi` can degrade instead of
/// growing branches here.
///
/// The text is a 1000-line ring, matching herdr's scrollback cap. ANSI is
/// kept: the pane's renderer paints SGR colours and redraws a line on `\r`.
/// There is no cursor, alternate screen or mouse support -- see
/// `docs/LOCAL_DEBIAN.md` for why that is a product decision, not a bug.
class LocalTransport implements HerdrTransport {
  LocalTransport(this._platform, {this.version = 'local-0.1.0', this.maxLines = 1000});

  static const workspaceId = 'local-w1';
  static const tabId = 'local-t1';
  static const paneId = 'local-p1';

  final LocalPtyPlatform _platform;
  final String version;
  final int maxLines;

  /// CSI sequences (colours, cursor moves). Stripped when the caller asks for
  /// plain text, as pane previews and answer guards do.
  static final _csi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

  final List<String> _lines = [];
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<String>? _output;
  Future<void>? _starting;
  var _wantsPaneUpdates = false;
  var _closed = false;

  Future<void> _ensureStarted() {
    if (_closed) {
      return Future.error(const HerdrTransportException('Local runtime closed', fatal: true));
    }
    return _starting ??= _start();
  }

  Future<void> _start() async {
    try {
      await _platform.prepare();
      final id = await _platform.start();
      if (id != paneId) {
        throw HerdrTransportException('Unexpected local pane id: $id', fatal: true);
      }
      _output = utf8.decoder
          .bind(_platform.output(id))
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onError: (Object e, StackTrace s) => _fail(const HerdrTransportException('Local PTY output failed'), e, s),
            onDone: () => _fail(const HerdrTransportException('Local PTY ended'), null, null),
          );
    } on Object {
      // A failed start is not cached: the next call tries again.
      _starting = null;
      rethrow;
    }
  }

  void _onLine(String line) {
    _lines.add(line);
    while (_lines.length > maxLines) {
      _lines.removeAt(0);
    }
    // The background profile asks only for status changes, not for output.
    // Sending pane_updated anyway would wake the radio for every shell line.
    if (_wantsPaneUpdates) {
      _emit({
        'event': 'pane_updated',
        'data': {'pane': _pane()},
      });
    }
  }

  void _fail(Object error, Object? cause, StackTrace? trace) {
    if (_events.isClosed) return;
    _events.addError(error, trace);
    if (cause != null) debugPrintLocal('local PTY: $cause');
  }

  void _emit(Map<String, dynamic> event) {
    if (!_events.isClosed) _events.add(event);
  }

  Map<String, dynamic> _pane() => {
    'pane_id': paneId,
    'workspace_id': workspaceId,
    'tab_id': tabId,
    'focused': true,
    'cwd': '/home/thoth',
    'terminal_title': 'Debian',
    'terminal_title_stripped': 'Debian',
    'label': 'Debian',
    'agent_status': 'idle',
  };

  Map<String, dynamic> _snapshot() => {
    'version': version,
    'workspaces': [
      {
        'workspace_id': workspaceId,
        'number': 1,
        'label': 'Debian',
        'focused': true,
        'pane_count': 1,
        'tab_count': 1,
        'agent_status': 'idle',
      },
    ],
    'tabs': [
      {
        'tab_id': tabId,
        'workspace_id': workspaceId,
        'number': 1,
        'label': '1',
        'focused': true,
        'pane_count': 1,
        'agent_status': 'idle',
      },
    ],
    'panes': [_pane()],
  };

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    switch (method) {
      case 'ping':
        return {'type': 'pong', 'version': version};

      case 'session.snapshot':
        await _ensureStarted();
        return {'type': 'session_snapshot', 'snapshot': _snapshot()};

      case 'pane.read':
        await _ensureStarted();
        final wanted = (params['lines'] as num?)?.toInt();
        final count = wanted == null ? _lines.length : wanted.clamp(0, _lines.length).toInt();
        final from = _lines.length - count;
        var text = _lines.skip(from).join('\n') + (from < _lines.length ? '\n' : '');
        if (params['strip_ansi'] == true) text = text.replaceAll(_csi, '');
        return {
          'type': 'pane_read',
          'read': {'text': text, 'truncated': from > 0},
        };

      case 'pane.send_text':
        await _ensureStarted();
        final text = params['text'] as String?;
        if (text != null && text.isNotEmpty) await _platform.write(paneId, utf8.encode(text));
        return {'type': 'ok'};

      case 'pane.send_keys':
        await _ensureStarted();
        await _sendKeys((params['keys'] as List?) ?? const []);
        return {'type': 'ok'};

      case 'pane.send_input':
        await _ensureStarted();
        final text = params['text'] as String?;
        if (text != null && text.isNotEmpty) await _platform.write(paneId, utf8.encode(text));
        await _sendKeys((params['keys'] as List?) ?? const []);
        return {'type': 'ok'};

      default:
        throw HerdrApiException('unsupported', 'unknown variant `$method` for the local runtime');
    }
  }

  Future<void> _sendKeys(List<Object?> keys) async {
    for (final key in keys) {
      final bytes = _keyBytes[key];
      if (bytes == null) {
        throw HerdrApiException('unsupported', 'unknown key `$key` for the local runtime');
      }
      await _platform.write(paneId, bytes);
    }
  }

  /// What the quick keys and the answer dock can send. Anything else is
  /// refused, not guessed: a silent wrong key in a shell is worse than an
  /// error the person can see.
  static const _keyBytes = <String, List<int>>{
    'enter': [13],
    'esc': [27],
    'tab': [9],
    'shift+tab': [27, 91, 90],
    'backspace': [127],
    'delete': [27, 91, 51, 126],
    'up': [27, 91, 65],
    'down': [27, 91, 66],
    'right': [27, 91, 67],
    'left': [27, 91, 68],
    'home': [27, 91, 72],
    'end': [27, 91, 70],
    'pgup': [27, 91, 53, 126],
    'pgdn': [27, 91, 54, 126],
    'ctrl+a': [1],
    'ctrl+c': [3],
    'ctrl+d': [4],
    'ctrl+e': [5],
    'ctrl+k': [11],
    'ctrl+l': [12],
    'ctrl+r': [18],
    'ctrl+u': [21],
    'ctrl+w': [23],
    'ctrl+z': [26],
  };

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    if (_closed) return Stream.error(const HerdrTransportException('Local runtime closed', fatal: true));
    _wantsPaneUpdates = subscriptions.any((s) => s['type'] == 'pane.updated' || s['type'] == 'pane_updated');
    final controller = StreamController<Map<String, dynamic>>();
    late final StreamSubscription<Map<String, dynamic>> inner;
    controller.onListen = () {
      // The snapshot came before the subscription: one ack closes the gap,
      // exactly as a real herdr subscription does.
      controller.add(const {'event': subscriptionStartedEvent});
      inner = _events.stream.listen(controller.add, onError: controller.addError, onDone: controller.close);
    };
    controller.onCancel = () => inner.cancel();
    return controller.stream;
  }

  @override
  void setBackground(bool background) {
    // The foreground service owns the runtime. Going behind the app must not
    // stop a shell the person left running; no polling is done here either.
  }

  @override
  void reset() {
    // There is no network to presume dead. The native service owns the PTY
    // and decides when it has really ended; [events] then errors.
  }

  @override
  bool get supportsFiles => false;

  RemoteFileException _unsupportedFile(String operation) =>
      RemoteFileException(RemoteFileErrorKind.unsupported, 'The local runtime has no file channel ($operation)');

  @override
  Future<RemoteStat> statFile(String path) => Future.error(_unsupportedFile('stat'));

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => Future.error(_unsupportedFile('list'));

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) =>
      Future.error(_unsupportedFile('read'));

  @override
  Future<String> realPath(String path) => Future.error(_unsupportedFile('realpath'));

  @override
  Future<void> makeDirs(String path) => Future.error(_unsupportedFile('mkdir'));

  @override
  Future<void> removeFile(String path) => Future.error(_unsupportedFile('rm'));

  @override
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) {
    throw _unsupportedFile('upload');
  }

  @override
  Future<ExecChannel> openExec(String command, {bool zipped = false}) =>
      Future.error(const HerdrTransportException('The local runtime has no exec channel', fatal: true));

  @override
  Future<WebBridgeInfo> openWebBridge(WebBridgeSpec spec) =>
      Future.error(const HerdrTransportException('The local runtime has no web bridge', fatal: true));

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _output?.cancel();
    if (!_events.isClosed) await _events.close();
    await _platform.stop(paneId);
    _platform.dispose();
  }
}

/// Kept out of `dart:developer` so this file imports nothing Flutter-specific.
void debugPrintLocal(String message) {
  // ignore: avoid_print
  print(message);
}
