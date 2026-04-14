/// Web-specific Element Call screen.
/// Uses HtmlElementView with a direct Element Call iframe (no wrapper).
/// Communication via postMessage between Flutter window and Element Call.
library;

import 'dart:async';
import 'dart:ui_web' as ui_web;

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:universal_html/html.dart' as html;

import '../../utils/callkit/call_store.dart';
import '../../utils/callkit/group_call.dart';
import '../../utils/element_call/call_connection_state.dart';
import '../../utils/widget_api/element_call/element_call_widget.dart';
import '../../utils/widget_api/element_call/participants_tracker.dart';
import '../../utils/widget_api/transport/web_transport.dart';
import '../../utils/widget_api/widget_driver.dart';
import '../../config/app_config.dart';
import '../../utils/widget_api/widget_settings.dart';

class WebCallScreen extends StatefulWidget {
  final String roomId;
  const WebCallScreen({super.key, required this.roomId});

  @override
  State<WebCallScreen> createState() => _WebCallScreenState();
}

class _WebCallScreenState extends State<WebCallScreen> {
  late Room? room;
  GroupCall? _groupCall;
  bool _isLoading = true;
  String? _error;
  bool _isClosing = false;

  late final String _viewId;
  html.IFrameElement? _iframe;
  WebWidgetTransport? _transport;
  WidgetDriver? _driver;
  ParticipantsTracker? _participantsTracker;
  WidgetSettings? _settings;

  StreamSubscription? _connectionStateSub;

  @override
  void initState() {
    super.initState();
    _viewId = 'ec-iframe-${DateTime.now().millisecondsSinceEpoch}';
    room = Matrix.of(context).client.getRoomById(widget.roomId);
    if (room == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeCall());
  }

  Future<void> _initializeCall() async {
    try {
      Logs().i('WebCallScreen: Initializing call for room ${room!.id}');

      final client = room!.client;
      final deviceId = client.deviceID ?? 'UNKNOWN';

      final theme = switch (ThemeController.of(context).themeMode) {
        ThemeMode.system => null,
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      };

      // parentUrl = current app URL so Element Call sends postMessage
      // to the correct origin (our Flutter window)
      final parentUrl = html.window.location.origin;
      Logs().i('WebCallScreen: parentUrl=$parentUrl');

      // Create widget settings (generates Element Call URL)
      _settings = ElementCallWidget.create(
        baseUrl: AppConfig.elementCallBaseUrl,
        parentUrl: parentUrl,
        room: room!,
        deviceId: deviceId,
        theme: theme,
      );

      Logs().i('WebCallScreen: Element Call URL: ${_settings!.url}');

      // Get or create GroupCall for state management
      final extra = GoRouterState.of(context).extra;
      final callKitUuid = extra is Map<String, dynamic>
          ? extra['callKitUuid'] as String?
          : null;

      _groupCall = CallStore.instance.getOrCreateCall(
        room: room!,
        client: client,
        autoReconnect: false,
        baseUrl: AppConfig.elementCallBaseUrl,
        parentUrl: parentUrl,
        callKitUuid: callKitUuid,
        theme: theme,
      );

      _connectionStateSub = _groupCall!.onConnectionStateChanged
          .listen(_onConnectionStateChanged);

      // Create iframe pointing directly to Element Call
      _iframe = html.IFrameElement()
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow =
            'microphone; camera; encrypted-media; autoplay; display-capture; clipboard-write; clipboard-read; screen-wake-lock;'
        ..src = _settings!.url;

      // Register as platform view
      ui_web.platformViewRegistry.registerViewFactory(
        _viewId,
        (int viewId) => _iframe!,
      );

      setState(() => _isLoading = false);

      // Wait for Element Call to load, then start Widget API handshake
      _iframe!.onLoad.first.then((_) {
        Logs().i('WebCallScreen: iframe loaded, starting Widget API');
        _startWidgetApi();
      });
    } catch (e, stack) {
      Logs().e('WebCallScreen: Init error', e, stack);
      setState(() {
        _error = 'Failed to initialize: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _startWidgetApi() async {
    if (_iframe == null || _settings == null || !mounted) return;

    try {
      // Create direct transport to Element Call iframe
      _transport = WebWidgetTransport(
        _iframe!,
        targetOrigin: AppConfig.elementCallBaseUrl,
      );
      await _transport!.initialize();

      // Create Widget API driver
      _driver = WidgetDriver(
        settings: _settings!,
        transport: _transport!,
        client: room!.client,
        room: room!,
        onJoin: () {
          Logs().i('WebCallScreen: Element Call joined');
          _groupCall?.onWidgetJoined();
        },
        onClose: () {
          Logs().i('WebCallScreen: Element Call closed');
          _groupCall?.hangup();
        },
        onHangup: () {
          Logs().i('WebCallScreen: Element Call hangup');
          _groupCall?.hangup();
        },
      );

      await _driver!.initialize();

      // Create call.member state in room
      await _groupCall!.createCallMembership();

      // Track participants
      _participantsTracker = ParticipantsTracker(room!);
      _groupCall!.startMembershipRefreshTimer();
      _groupCall!.setConnectionState(CallConnectionState.connecting);

      Logs().i('WebCallScreen: Widget API started successfully');
    } catch (e, stack) {
      Logs().e('WebCallScreen: Widget API error', e, stack);
      setState(() => _error = 'Failed to start call: $e');
    }
  }

  void _onConnectionStateChanged(CallConnectionState state) {
    Logs().i('WebCallScreen: Connection state: $state');
    if (state == CallConnectionState.disconnected && mounted && !_isClosing) {
      _isClosing = true;
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    Logs().i('WebCallScreen: Disposing');
    _connectionStateSub?.cancel();
    _driver?.dispose();
    _transport?.dispose();
    _participantsTracker?.dispose();
    _groupCall?.hangup().catchError(
      (e) => Logs().e('WebCallScreen: Hangup error', e),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
        ),
      );
    }

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Connecting...')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Call Error')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: HtmlElementView(viewType: _viewId),
      ),
    );
  }
}
