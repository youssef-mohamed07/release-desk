import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/workspace.dart';
import 'app_model.dart';
import 'theme.dart';

class _Item {
  const _Item({required this.id, required this.title, required this.subtitle, this.icon, this.appId, this.provider, required this.run});
  final String id;
  final String title;
  final String subtitle;
  final IconData? icon;
  final String? appId;
  final StoreProvider? provider;
  final void Function(AppModel) run;
}

/// ⌘K / Ctrl+K: type a few letters of an app or an action and press return.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key});

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final query = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  int selection = 0;

  @override
  void dispose() {
    query.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  List<_Item> _items(AppModel model) {
    final all = <_Item>[];
    for (final (account: account, team: team) in model.allTeams) {
      final store = account.provider == StoreProvider.apple ? 'App Store' : 'Google Play';
      for (final app in model.teams[team.id]?.apps ?? const []) {
        all.add(
          _Item(
            id: 'ship-${app.id}',
            title: 'Ship ${app.name}',
            subtitle: '$store · ${team.name}',
            appId: app.id,
            provider: account.provider,
            run: (m) => m.go(AppRoute.ship(app.id)),
          ),
        );
        all.add(
          _Item(
            id: 'open-${app.id}',
            title: app.name,
            subtitle: '${app.bundleId} · $store · ${team.name}',
            appId: app.id,
            provider: account.provider,
            run: (m) => m.go(AppRoute.app(app.id)),
          ),
        );
      }
      all.add(
        _Item(
          id: 'team-${team.id}',
          title: team.name,
          subtitle: '${account.name} · ${team.teamId ?? ''}',
          icon: Icons.groups_2_outlined,
          provider: account.provider,
          run: (m) => m.go(AppRoute.team(team.id)),
        ),
      );
    }
    all.addAll([
      _Item(id: 'overview', title: 'Overview', subtitle: 'Every app on every team', icon: Icons.grid_view_rounded, run: (m) => m.go(const AppRoute.overview())),
      _Item(
        id: 'activity',
        title: 'Activity',
        subtitle: 'Releases and their logs',
        icon: Icons.monitor_heart_outlined,
        run: (m) => m.go(const AppRoute.activity()),
      ),
      _Item(
        id: 'connect-apple',
        title: 'Connect App Store Connect',
        subtitle: 'Add a team with its API key',
        icon: Icons.apple,
        run: (m) => m.connect(StoreProvider.apple),
      ),
      _Item(
        id: 'connect-google',
        title: 'Connect Google Play',
        subtitle: 'Sign in with a Google account',
        icon: Icons.play_arrow_rounded,
        run: (m) => m.connect(StoreProvider.google),
      ),
      _Item(id: 'refresh', title: 'Refresh everything', subtitle: 'Ask both stores again', icon: Icons.refresh_rounded, run: (m) => unawaited(m.refreshAll())),
      _Item(
        id: 'privacy',
        title: model.privacy ? 'Turn privacy mode off' : 'Turn privacy mode on',
        subtitle: 'Blur names, ids, paths and logs',
        icon: Icons.visibility_off_outlined,
        run: (m) => m.togglePrivacy(),
      ),
    ]);
    final words = query.text.toLowerCase().split(' ').where((w) => w.isNotEmpty).toList();
    // Nothing typed: apps first, then the places.
    if (words.isEmpty) return all.where((i) => !i.id.startsWith('ship-')).toList();
    int score(_Item i) {
      final t = i.title.toLowerCase();
      var s = 0;
      if (t.startsWith(words.first)) s += 4;
      if (words.first == 'ship' && i.id.startsWith('ship-')) s += 6;
      if (i.appId != null) s += 1;
      return s;
    }

    final matches = all.where((i) => words.every((w) => '${i.title} ${i.subtitle}'.toLowerCase().contains(w))).toList();
    matches.sort((a, b) => score(b) - score(a));
    return matches;
  }

  void _pick(AppModel model, List<_Item> list) {
    if (selection < 0 || selection >= list.length) return;
    final item = list[selection];
    model.setPalette(false);
    item.run(model);
  }

  void _move(int by, int count) {
    if (count == 0) return;
    setState(() => selection = (selection + by).clamp(0, count - 1));
    final y = selection * 48.0;
    if (scroll.hasClients) {
      final pos = scroll.position;
      if (y < pos.pixels) scroll.jumpTo(y);
      if (y + 48 > pos.pixels + pos.viewportDimension) scroll.jumpTo((y + 48 - pos.viewportDimension).clamp(0, pos.maxScrollExtent));
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final list = _items(model);
    final shown = list.take(60).toList();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => model.setPalette(false),
            child: Container(color: Colors.black.withValues(alpha: 0.25)),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 90),
            child: SizedBox(
              width: 640,
              child: Glass(
                radius: 22,
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: [
                            Icon(Icons.search_rounded, size: 22, color: t.text2),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Focus(
                                onKeyEvent: (node, e) {
                                  if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
                                  if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                                    _move(1, shown.length);
                                    return KeyEventResult.handled;
                                  }
                                  if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                                    _move(-1, shown.length);
                                    return KeyEventResult.handled;
                                  }
                                  if (e.logicalKey == LogicalKeyboardKey.escape) {
                                    model.setPalette(false);
                                    return KeyEventResult.handled;
                                  }
                                  return KeyEventResult.ignored;
                                },
                                child: TextField(
                                  controller: query,
                                  focusNode: focus,
                                  autofocus: true,
                                  onChanged: (_) => setState(() => selection = 0),
                                  onSubmitted: (_) => _pick(model, shown),
                                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: t.text),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: 'Ship, open, connect…',
                                    hintStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: t.text3),
                                  ),
                                ),
                              ),
                            ),
                            Text('esc', style: mono(11, color: t.text3)),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: t.hairline),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 380),
                        child: shown.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text('Nothing matches “${query.text}”', style: TextStyle(color: t.text2)),
                              )
                            : ListView.builder(
                                controller: scroll,
                                shrinkWrap: true,
                                padding: const EdgeInsets.all(8),
                                itemExtent: 48,
                                itemCount: shown.length,
                                itemBuilder: (context, i) => _row(context, model, shown[i], i == selection, () {
                                  setState(() => selection = i);
                                  _pick(model, shown);
                                }),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, AppModel model, _Item item, bool selected, VoidCallback onTap) {
    final t = context.tokens;
    final sensitive = item.appId != null || item.id.startsWith('team-');
    final app = item.appId == null ? null : model.app(item.appId!);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(color: selected ? Palette.indigo.withValues(alpha: 0.18) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              if (app != null)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Sensitive(
                      radius: 6,
                      child: AppIcon(url: model.iconUrl(app.id, 64), name: app.name, size: 28),
                    ),
                    if (item.id.startsWith('ship-'))
                      Positioned(
                        right: -5,
                        bottom: -5,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Palette.indigo,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1),
                          ),
                          child: const Icon(Icons.send_rounded, size: 8, color: Colors.white),
                        ),
                      ),
                  ],
                )
              else
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(color: t.chipFill, borderRadius: BorderRadius.circular(7)),
                  child: Icon(item.icon ?? Icons.circle_outlined, size: 16, color: t.text),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Sensitive(
                      radius: sensitive ? 5 : 0,
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ),
                    Sensitive(
                      radius: sensitive ? 4 : 0,
                      child: Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: t.text2),
                      ),
                    ),
                  ],
                ),
              ),
              if (item.provider != null) ProviderMark(item.provider!, size: 12, color: t.text2),
              if (selected) ...[const SizedBox(width: 8), Icon(Icons.keyboard_return_rounded, size: 14, color: t.text2)],
            ],
          ),
        ),
      ),
    );
  }
}
