import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/workspace.dart';
import 'activity.dart';
import 'app_model.dart';
import 'app_page.dart';
import 'command_palette.dart';
import 'connect.dart';
import 'overview.dart';
import 'ship.dart';
import 'sidebar.dart';
import 'theme.dart';

class ReleaseDeskApp extends StatelessWidget {
  const ReleaseDeskApp({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => MaterialApp(
        title: 'Release Desk',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: model.themeMode,
        // Above the navigator, so dialogs see the model and privacy mode too.
        builder: (context, child) => ModelScope(
          model: model,
          child: PrivacyScope(on: model.privacy, child: child!),
        ),
        home: const RootView(),
      ),
    );
  }
}

class RootView extends StatefulWidget {
  const RootView({super.key});

  @override
  State<RootView> createState() => _RootViewState();
}

class _RootViewState extends State<RootView> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _messages;
  StreamSubscription<StoreProvider>? _connects;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final model = ModelScope.read(context);
    _messages = model.messages.stream.listen((m) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 5), width: 560));
    });
    _connects = model.connectRequests.stream.listen((p) {
      if (mounted) showConnectDialog(context, p);
    });
    HardwareKeyboard.instance.addHandler(_onKey);
    unawaited(model.refreshAll());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _messages?.cancel();
    _connects?.cancel();
    super.dispose();
  }

  /// Window-wide shortcuts: ⌘K / Ctrl+K, privacy, refresh, pages.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final kb = HardwareKeyboard.instance;
    final mod = isMac ? kb.isMetaPressed : kb.isControlPressed;
    final model = ModelScope.read(context);
    if (e.logicalKey == LogicalKeyboardKey.escape && model.paletteOpen) {
      model.setPalette(false);
      return true;
    }
    if (!mod || kb.isAltPressed) return false;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.keyK && !kb.isShiftPressed) {
      model.setPalette(!model.paletteOpen);
      return true;
    }
    if (key == LogicalKeyboardKey.keyP && kb.isShiftPressed) {
      model.togglePrivacy();
      return true;
    }
    if (kb.isShiftPressed) return false;
    if (key == LogicalKeyboardKey.keyR) {
      unawaited(model.refreshAll());
      return true;
    }
    if (key == LogicalKeyboardKey.digit1) {
      model.go(const AppRoute.overview());
      return true;
    }
    if (key == LogicalKeyboardKey.digit2) {
      model.go(const AppRoute.activity());
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    return ScaffoldMessenger(
      key: _messenger,
      child: Scaffold(
        backgroundColor: t.bg,
        body: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: 272, child: Sidebar()),
                Container(width: 0.8, color: t.hairline),
                Expanded(
                  child: ClipRect(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: KeyedSubtree(key: ValueKey(model.route), child: _page(model)),
                    ),
                  ),
                ),
              ],
            ),
            if (model.paletteOpen) const Positioned.fill(child: CommandPalette()),
          ],
        ),
      ),
    );
  }

  Widget _page(AppModel model) {
    final r = model.route;
    return switch (r.kind) {
      RouteKind.overview => const OverviewPage(),
      RouteKind.activity => const ActivityPage(),
      RouteKind.team => TeamPage(teamId: r.id!),
      RouteKind.app => AppPage(appId: r.id!),
      RouteKind.ship => ShipPage(appId: r.id!),
    };
  }
}
