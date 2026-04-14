import 'dart:async';
import 'dart:convert';

import 'package:matrix/matrix.dart';
import 'package:universal_html/html.dart' as html;

import 'widget_transport.dart';

/// Web transport using direct postMessage to Element Call iframe.
/// No wrapper iframe needed - communicates directly with Element Call.
class WebWidgetTransport implements WidgetTransport {
  final html.IFrameElement _iframe;
  final String _targetOrigin;
  final StreamController<String> _incomingController =
      StreamController.broadcast();

  bool _disposed = false;
  StreamSubscription? _messageSub;

  /// [iframe] - direct reference to the Element Call iframe element.
  /// [targetOrigin] - Element Call base URL for postMessage security.
  WebWidgetTransport(
    this._iframe, {
    String targetOrigin = 'https://call.element.io',
  }) : _targetOrigin = targetOrigin;

  Future<void> initialize() async {
    Logs().i('WebWidgetTransport: Initializing, listening on window.onMessage');
    _messageSub = html.window.onMessage.listen((event) {
      if (_disposed) return;
      if (event.data == null) return;

      final data = event.data;

      // Log ALL incoming postMessages for debugging
      Logs().i('WebWidgetTransport: RAW message received, origin=${event.origin}, type=${data.runtimeType}');

      if (data is! Map) return;

      final api = data['api'];
      if (api == null) return;

      // Accept both fromWidget requests and toWidget responses
      final isFromWidget = api == 'fromWidget';
      final isResponse = data.containsKey('response');

      if (isFromWidget || isResponse) {
        final message = jsonEncode(data);
        Logs().i('WebWidgetTransport: Widget API message: action=${data['action']}');
        _incomingController.add(message);
      }
    });
  }

  @override
  Stream<String> get incoming => _incomingController.stream;

  @override
  Future<void> send(String message) async {
    if (_disposed) return;

    Logs().d('WebWidgetTransport: Sending: $message');

    if (_iframe.contentWindow != null) {
      final parsed = jsonDecode(message);
      _iframe.contentWindow!.postMessage(parsed, _targetOrigin);
    } else {
      Logs().w('WebWidgetTransport: iframe contentWindow is null');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _messageSub?.cancel();
    _incomingController.close();
  }
}
