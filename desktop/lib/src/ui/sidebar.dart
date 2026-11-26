import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/asc.dart';
import '../core/release_run.dart';
import '../core/workspace.dart';
import 'app_model.dart';
import '../core/play.dart';
import 'theme.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final route = model.route;
    // The ship page belongs to its app's row.
    final selected = route.kind == RouteKind.ship ? AppRoute.app(route.id!) : route;
    return Container(
      color: t.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 10, 10),
            child: Row(
              children: [
                const BrandGlyph(size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Release Desk', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                      Text('${modKey}K to jump anywhere', style: TextStyle(fontSize: 11, color: t.text2)),
                    ],
                  ),
                ),
                IconBtn(
                  switch (model.themeMode) {
                    ThemeMode.dark => Icons.dark_mode_outlined,
                    ThemeMode.light => Icons.light_mode_outlined,
                    _ => Icons.contrast,
                  },
                  tooltip:
                      'Appearance: ${switch (model.themeMode) {
                        ThemeMode.dark => 'dark',
                        ThemeMode.light => 'light',
                        _ => 'follows the system',
                      }}',
                  onPressed: model.cycleTheme,
                  size: 16,
                ),
                IconBtn(
                  model.privacy ? Icons.visibility_off : Icons.visibility_outlined,
                  color: model.privacy ? Palette.indigo : null,
                  tooltip: model.privacy
                      ? 'Privacy mode is on: names, ids and paths are blurred (⇧${modKey}P)'
                      : 'Privacy mode: blur names, ids and paths (⇧${modKey}P)',
                  onPressed: model.togglePrivacy,
                  size: 16,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
              children: [
                _NavRow(
                  icon: Icons.grid_view_rounded,
                  title: 'Overview',
                  selected: selected == const AppRoute.overview(),
                  onTap: () => model.go(const AppRoute.overview()),
                ),
                _NavRow(
                  icon: Icons.monitor_heart_outlined,
                  title: 'Activity',
                  selected: selected == const AppRoute.activity(),
                  onTap: () => model.go(const AppRoute.activity()),
                  trailing: model.runningCount > 0
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: Palette.cyan.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(99)),
                          child: Text('${model.runningCount}', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
                        )
                      : null,
                ),
                for (final account in model.workspace.accounts) ...[
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: Row(
                      children: [
                        ProviderMark(account.provider, size: 11, color: t.text2),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Sensitive(
                            radius: 4,
                            child: Text(
                              account.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final team in account.teams) ..._teamRows(context, model, account, team, selected),
                ],
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Text(
                    'Connect',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: t.text2),
                  ),
                ),
                _NavRow(
                  iconWidget: Icon(Icons.apple, size: 17, color: t.text),
                  title: 'App Store Connect',
                  onTap: () => model.connect(StoreProvider.apple),
                ),
                _NavRow(iconWidget: const PlayMark(size: 16), title: 'Google Play', onTap: () => model.connect(StoreProvider.google)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _teamRows(BuildContext context, AppModel model, Account account, Team team, AppRoute selected) {
    final t = context.tokens;
    final state = model.teams[team.id];
    final open = !collapsed.contains(team.id);
    return [
      GestureDetector(
        onSecondaryTapDown: (d) => _teamMenu(context, model, team, d.globalPosition),
        child: _NavRow(
          selected: selected == AppRoute.team(team.id),
          onTap: () => model.go(AppRoute.team(team.id)),
          leading: GestureDetector(
            onTap: () => setState(() => open ? collapsed.add(team.id) : collapsed.remove(team.id)),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedRotation(
                turns: open ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.chevron_right_rounded, size: 16, color: t.text3),
              ),
            ),
          ),
          iconWidget: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.groups_2_outlined, size: 17, color: t.text2),
              if (team.credential.isGoogle) const Positioned(right: -4, bottom: -4, child: PlayMark(size: 9)),
            ],
          ),
          titleWidget: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Sensitive(
                radius: 5,
                child: Text(team.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ),
              Sensitive(
                radius: team.teamId == null ? 0 : 4,
                child: Text(
                  [?team.teamId, if (state != null) counted(state.apps.length, 'app')].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: t.text2),
                ),
              ),
            ],
          ),
          trailing: state?.loading == true
              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6))
              : state?.error != null
              ? Tooltip(
                  message: state!.error!,
                  child: Icon(Icons.warning_amber_rounded, size: 14, color: waitingColor),
                )
              : null,
        ),
      ),
      if (open)
        for (final app in state?.apps ?? const <StoreApp>[]) _appRow(context, model, app, selected),
    ];
  }

  Widget _appRow(BuildContext context, AppModel model, StoreApp app, AppRoute selected) {
    Widget? dot;
    final st = model.apps[app.id];
    if (model.activeRun(app.id) != null) {
      dot = Pulse(child: Icon(Icons.send_rounded, size: 11, color: Palette.cyan));
    } else if (app.isPlay) {
      if (st?.error != null) {
        dot = Icon(Icons.key_outlined, size: 12, color: waitingColor);
      } else {
        PlayRelease? r;
        for (final tr in st?.tracks ?? const <PlayTrack>[]) {
          if (tr.track == 'production' && tr.releases.isNotEmpty) r = tr.releases.first;
        }
        r ??= (st?.tracks ?? const <PlayTrack>[]).where((tr) => tr.releases.isNotEmpty).map((tr) => tr.releases.first).firstOrNull;
        if (r != null) dot = _Dot(releaseTone(r).color(context));
      }
    } else if (st != null && st.builds.isNotEmpty) {
      final b = st.builds.first;
      dot = _Dot(describeState(b.externalState ?? b.processingState).tone.color(context));
    }
    return _NavRow(
      indent: 26,
      selected: selected == AppRoute.app(app.id),
      onTap: () => model.go(AppRoute.app(app.id)),
      iconWidget: Sensitive(
        radius: 4,
        child: AppIcon(url: model.iconUrl(app.id, 64), name: app.name, size: 18),
      ),
      titleWidget: Sensitive(
        radius: 5,
        child: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
      ),
      trailing: dot,
    );
  }

  Future<void> _teamMenu(BuildContext context, AppModel model, Team team, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'refresh', height: 34, child: Text('Refresh')),
        PopupMenuItem(value: 'remove', height: 34, child: Text('Remove…')),
      ],
    );
    if (!context.mounted) return;
    if (choice == 'refresh') unawaited(model.refreshTeam(team));
    if (choice == 'remove') await confirmRemoveTeam(context, model, team);
  }
}

Future<void> confirmRemoveTeam(BuildContext context, AppModel model, Team team) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Remove ${PrivacyScope.of(c) ? 'this team' : team.name}?'),
      content: const SizedBox(
        width: 420,
        child: Text("Release Desk forgets this team, its apps' project folders, and deletes its key from your keychain. Nothing changes on the store."),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: Text('Remove team and its key', style: TextStyle(color: Palette.ember)),
        ),
      ],
    ),
  );
  if (ok == true) await model.removeTeam(team);
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class Pulse extends StatefulWidget {
  const Pulse({super.key, required this.child});
  final Widget child;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: Tween(begin: 0.35, end: 1.0).animate(c), child: widget.child);
}

class _NavRow extends StatefulWidget {
  const _NavRow({
    this.icon,
    this.iconWidget,
    this.title,
    this.titleWidget,
    this.selected = false,
    required this.onTap,
    this.trailing,
    this.leading,
    this.indent = 0,
  });
  final IconData? icon;
  final Widget? iconWidget;
  final String? title;
  final Widget? titleWidget;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? leading;
  final double indent;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bg = widget.selected
        ? (t.dark ? Colors.white.withValues(alpha: 0.10) : Colors.black.withValues(alpha: 0.07))
        : (hover ? (t.dark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.035)) : Colors.transparent);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: EdgeInsets.fromLTRB(8 + widget.indent - (widget.leading != null ? 4 : 0), 6, 8, 6),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 2)],
              SizedBox(
                width: 20,
                child: Center(child: widget.iconWidget ?? Icon(widget.icon, size: 17, color: widget.selected ? t.text : t.text2)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child:
                    widget.titleWidget ??
                    Text(
                      widget.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500),
                    ),
              ),
              if (widget.trailing != null) ...[const SizedBox(width: 6), widget.trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// A release's colour: live green, rolling out blue, draft amber, halted red.
StateTone releaseTone(PlayRelease r) => switch (r.status) {
  'completed' => StateTone.good,
  'inProgress' => StateTone.active,
  'draft' => StateTone.waiting,
  'halted' => StateTone.bad,
  _ => StateTone.muted,
};

String runStatusLine(ReleaseRun run) => switch (run.phase) {
  RunPhase.running => '${run.current?.title ?? 'Starting'} · ${clock(run.elapsed)}',
  RunPhase.succeeded => run.plan.rehearsal ? 'Rehearsal passed' : 'Shipped in ${clock(run.elapsed)}',
  RunPhase.failed => run.failure ?? 'Failed',
  RunPhase.cancelled => 'Cancelled',
  RunPhase.ready => 'Ready',
};
