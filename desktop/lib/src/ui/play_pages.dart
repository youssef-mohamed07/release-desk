import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/asc.dart';
import '../core/play.dart';
import '../core/workspace.dart';
import 'app_model.dart';
import 'overview.dart';
import 'sidebar.dart';
import 'theme.dart';

/// A Play app: its tracks side by side, newest release on top of each.
class PlayAppPage extends StatelessWidget {
  const PlayAppPage({super.key, required this.app});
  final StoreApp app;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final state = model.apps[app.id] ?? AppState();
    final team = model.teamOfApp(app.id);
    final link = model.workspace.link(app.id);
    PlayRelease? top;
    for (final tr in state.tracks) {
      for (final r in tr.releases) {
        if (top == null || r.maxCode > top.maxCode) top = r;
      }
    }
    final tracks = [...state.tracks]
      ..sort((a, b) {
        final ea = a.releases.isEmpty ? 1 : 0, eb = b.releases.isEmpty ? 1 : 0;
        return ea != eb ? ea - eb : a.order - b.order;
      });
    return PageFrame(
      glowUrl: model.iconUrl(app.id),
      glowHeight: 520,
      toolbar: Row(
        children: [IconBtn(Icons.refresh_rounded, tooltip: 'Refresh', onPressed: () => unawaited(model.refreshApp(app.id)))],
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Sensitive(
              radius: 14,
              child: AppIcon(url: model.iconUrl(app.id, 512), name: app.name, size: 104),
            ),
            const SizedBox(width: 22),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Sensitive(
                          radius: 12,
                          child: Text(
                            app.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const PlayMark(size: 22),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    children: [
                      Tag(app.bundleId, icon: Icons.inventory_2_outlined, isMono: true, sensitive: true),
                      if (team != null) Tag(team.name, icon: Icons.people_outline, sensitive: true),
                      if (state.play?.defaultLanguage != null) Tag(state.play!.defaultLanguage!, icon: Icons.language),
                      if (link != null) Tag(tildePath(link.path), icon: Icons.folder_outlined, isMono: true, sensitive: true),
                    ],
                  ),
                  if (top != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('Highest', style: TextStyle(color: t.text2, fontSize: 13.5)),
                        const SizedBox(width: 8),
                        Text(
                          top.name.isEmpty ? top.versionCodes.join(', ') : top.name,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, fontFeatures: tabular),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                PrimaryButton(
                  label: model.activeRun(app.id) != null ? 'Shipping…' : 'Ship to Google Play',
                  icon: Icons.send_rounded,
                  color: Palette.playGreen,
                  onPressed: () => model.go(AppRoute.ship(app.id)),
                ),
                const SizedBox(height: 10),
                LinkText('Open Play Console', icon: Icons.open_in_new_rounded, onTap: () => launchUrl(Uri.parse('https://play.google.com/console/developers'))),
              ],
            ),
          ],
        ),
        if (state.error != null && team != null) ...[
          const SizedBox(height: 26),
          AccessCard(message: state.error!, team: team, retry: () => unawaited(model.refreshApp(app.id))),
        ],
        const SizedBox(height: 28),
        SectionHeader('Tracks', subtitle: state.tracks.isEmpty ? null : '${state.tracks.length}', icon: Icons.alt_route_rounded),
        const SizedBox(height: 14),
        if (state.tracks.isEmpty)
          Surface(
            child: Text(
              state.loading ? 'Loading…' : (state.error == null ? 'No releases on any track yet.' : 'Tracks show up once Play lets this account in.'),
              style: TextStyle(color: t.text2),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final tr in tracks)
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: TrackColumn(track: tr),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Explains a Play permission problem and how to fix it.
class AccessCard extends StatelessWidget {
  const AccessCard({super.key, required this.message, required this.team, required this.retry});
  final String message;
  final Team team;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isAccess = message.contains('has no access');
    return Surface(
      border: waitingColor.withValues(alpha: 0.35),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isAccess ? Icons.key_outlined : Icons.warning_rounded, size: 24, color: waitingColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isAccess ? 'No access to this app' : 'Play answered with a problem', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Sensitive(
                  radius: 4,
                  child: SelectableText(message, style: TextStyle(fontSize: 13.5, color: t.text2)),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    LinkText(
                      'Open Play Console users',
                      size: 12,
                      onTap: () => launchUrl(Uri.parse('https://play.google.com/console/developers/users-and-permissions')),
                    ),
                    const Spacer(),
                    SoftButton(label: 'Check again', small: true, onPressed: retry),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TrackColumn extends StatelessWidget {
  const TrackColumn({super.key, required this.track});
  final PlayTrack track;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (icon, color) = switch (track.track) {
      'internal' => (Icons.business_outlined, Palette.indigo),
      'alpha' => (Icons.shield_outlined, Palette.violet),
      'beta' => (Icons.groups_outlined, Palette.cyan),
      'production' => (Icons.public_rounded, Palette.mint),
      _ => (Icons.alt_route_rounded, Palette.indigo),
    };
    return SizedBox(
      width: 290,
      child: Surface(
        radius: 18,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(track.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Text(track.track, style: mono(11, color: t.text3)),
              ],
            ),
            const SizedBox(height: 12),
            if (track.releases.isEmpty) Text('Nothing here yet', style: TextStyle(fontSize: 13.5, color: t.text2)),
            for (final r in track.releases)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: t.text.withValues(alpha: 0.035), borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            r.name.isEmpty ? 'Release' : r.name,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFeatures: tabular),
                          ),
                        ),
                        Flexible(child: ToneText(r.statusLabel, releaseTone(r))),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Version code ${r.versionCodes.join(', ')}', style: mono(11.5, color: t.text2)),
                    if (r.userFraction != null && r.status == 'inProgress') ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: r.userFraction, minHeight: 4, color: Palette.cyan, backgroundColor: t.hairline),
                      ),
                    ],
                    if (r.notes.values.any((n) => n.isNotEmpty)) ...[
                      const SizedBox(height: 8),
                      Sensitive(
                        radius: 4,
                        child: Text(
                          r.notes.values.firstWhere((n) => n.isNotEmpty),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: t.text2),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The small summary a Play app shows on overview cards.
class TrackStrip extends StatelessWidget {
  const TrackStrip({super.key, required this.tracks, this.error});
  final List<PlayTrack> tracks;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (error != null && tracks.isEmpty) {
      return Row(
        children: [
          Icon(Icons.key_outlined, size: 14, color: waitingColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              error!.contains('has no access') ? 'Waiting for Play access' : 'Play answered with a problem',
              style: TextStyle(fontSize: 12, color: waitingColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    if (tracks.isEmpty) return Text('No releases yet', style: TextStyle(fontSize: 13.5, color: t.text2));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, tr) in tracks.take(4).indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr.title.replaceAll(' testing', ''),
                  maxLines: 1,
                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: t.text2),
                ),
                const SizedBox(height: 2),
                Text(
                  tr.releases.isEmpty ? '–' : (tr.releases.first.name.isEmpty ? (tr.releases.first.versionCodes.firstOrNull ?? '–') : tr.releases.first.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, fontFeatures: tabular),
                ),
                const SizedBox(height: 3),
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: tr.releases.isEmpty ? t.text2.withValues(alpha: 0.2) : releaseTone(tr.releases.first).color(context),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
