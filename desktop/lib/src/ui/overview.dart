import 'dart:async';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import '../core/asc.dart';
import '../core/play.dart';
import '../core/release_run.dart';
import '../core/workspace.dart';
import 'app_model.dart';
import 'console.dart';
import 'play_pages.dart';
import 'sidebar.dart';
import 'theme.dart';

/// Set by demos and screenshot tests to greet a stand-in person.
String? debugUserNameOverride;

/// A scrolling page over a soft glow, with an optional toolbar on top.
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.children, this.glowUrl, this.glowIntensity = 0.55, this.glowHeight = 460, this.toolbar, this.padding});
  final List<Widget> children;
  final String? glowUrl;
  final double glowIntensity;
  final double glowHeight;
  final Widget? toolbar;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: glowHeight,
          child: AmbientGlow(url: glowUrl, intensity: glowIntensity, height: glowHeight),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (toolbar != null) Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 0), child: toolbar!),
            Expanded(
              child: ListView(padding: padding ?? const EdgeInsets.fromLTRB(34, 26, 34, 40), children: children),
            ),
          ],
        ),
      ],
    );
  }
}

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    if (model.workspace.accounts.isEmpty) return const WelcomeView();
    final q = query.text.trim().toLowerCase();
    final running = model.runs.where((r) => r.phase == RunPhase.running).toList();
    return PageFrame(
      glowHeight: 420,
      toolbar: Row(
        children: [
          IconBtn(Icons.refresh_rounded, tooltip: 'Refresh (${modKey}R)', onPressed: () => unawaited(model.refreshAll())),
          const SizedBox(width: 8),
          SizedBox(
            width: 320,
            child: Field(controller: query, hint: 'Find an app or bundle id', onChanged: (_) => setState(() {})),
          ),
        ],
      ),
      children: [
        _header(context, model),
        if (running.isNotEmpty) ...[
          const SizedBox(height: 28),
          const SectionHeader('Shipping now', icon: Icons.send_rounded),
          const SizedBox(height: 12),
          for (final run in running)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _Clickable(
                onTap: () => model.go(AppRoute.ship(run.plan.app.id)),
                child: Surface(
                  radius: 14,
                  padding: const EdgeInsets.all(12),
                  child: MiniRun(run: run),
                ),
              ),
            ),
        ],
        for (final pair in model.allTeams) ...[const SizedBox(height: 28), _teamGrid(context, model, pair.account, pair.team, q)],
      ],
    );
  }

  Widget _header(BuildContext context, AppModel model) {
    final appsCount = model.teams.values.fold<int>(0, (a, s) => a + s.apps.length);
    final teamCount = model.allTeams.length;
    final testing = model.apps.values
        .where((s) => s.builds.isNotEmpty && (s.builds.first.externalState == 'IN_BETA_TESTING' || s.builds.first.internalState == 'IN_BETA_TESTING'))
        .length;
    final h = DateTime.now().hour;
    final part = h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
    final raw = debugUserNameOverride ?? Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? '';
    final first = raw.split(RegExp(r'[ ._-]')).first;
    final name = first.isEmpty ? '' : first[0].toUpperCase() + first.substring(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(name.isEmpty ? part : '$part, ', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            if (name.isNotEmpty)
              Flexible(
                child: Sensitive(
                  radius: 10,
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          children: [
            Stat('$appsCount', appsCount == 1 ? 'app' : 'apps'),
            Stat('$teamCount', teamCount == 1 ? 'team' : 'teams'),
            Stat('$testing', 'on TestFlight'),
            if (model.runningCount > 0) Stat('${model.runningCount}', 'shipping now', tint: Palette.cyan),
          ],
        ),
      ],
    );
  }

  Widget _teamGrid(BuildContext context, AppModel model, Account account, Team team, String q) {
    final t = context.tokens;
    final state = model.teams[team.id];
    final apps = (state?.apps ?? const <StoreApp>[])
        .where((a) => q.isEmpty || a.name.toLowerCase().contains(q) || a.bundleId.toLowerCase().contains(q))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ProviderMark(account.provider, size: 15),
            const SizedBox(width: 8),
            Flexible(
              child: Sensitive(
                child: Text(team.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ),
            ),
            if (team.teamId != null) ...[
              const SizedBox(width: 8),
              Sensitive(
                child: Text(team.teamId!, style: mono(13, color: t.text2)),
              ),
            ],
            const SizedBox(width: 8),
            Flexible(
              child: Sensitive(
                child: Text(
                  '· ${account.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: t.text3),
                ),
              ),
            ),
            const Spacer(),
            if (state?.loading == true) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8)),
          ],
        ),
        if (state?.error != null) ...[const SizedBox(height: 10), WarningLine(state!.error!)],
        const SizedBox(height: 14),
        AppGrid(apps: apps),
      ],
    );
  }
}

class WarningLine extends StatelessWidget {
  const WarningLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.warning_rounded, size: 16, color: Colors.orange.shade400),
      const SizedBox(width: 6),
      Expanded(
        child: SelectableText(text, style: TextStyle(fontSize: 13, color: Colors.orange.shade400)),
      ),
    ],
  );
}

/// Cards in as many columns as fit, 270 to 400 points wide.
class AppGrid extends StatelessWidget {
  const AppGrid({super.key, required this.apps});
  final List<StoreApp> apps;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 14.0;
      final cols = ((box.maxWidth + gap) / (270 + gap)).floor().clamp(1, 12);
      final w = ((box.maxWidth - gap * (cols - 1)) / cols).clamp(0.0, 400.0);
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final a in apps)
            SizedBox(
              width: w,
              child: AppCard(app: a),
            ),
        ],
      );
    },
  );
}

class Stat extends StatelessWidget {
  const Stat(this.value, this.label, {super.key, this.tint});
  final String value;
  final String label;
  final Color? tint;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: value,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: tint ?? context.tokens.text, fontFeatures: tabular),
        ),
        TextSpan(
          text: ' $label',
          style: TextStyle(fontSize: 14, color: context.tokens.text2),
        ),
      ],
    ),
  );
}

class _Clickable extends StatelessWidget {
  const _Clickable({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: child),
  );
}

class AppCard extends StatefulWidget {
  const AppCard({super.key, required this.app});
  final StoreApp app;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final app = widget.app;
    final st = model.apps[app.id];
    final latest = (st?.builds.isNotEmpty ?? false) ? st!.builds.first : null;
    final run = model.activeRun(app.id);
    final big = TextStyle(fontSize: 14, fontWeight: FontWeight.w700, fontFeatures: tabular, color: t.text);
    Widget body;
    if (app.isPlay) {
      PlayRelease? top;
      for (final tr in st?.tracks ?? const <PlayTrack>[]) {
        for (final r in tr.releases) {
          if (top == null || r.maxCode > top.maxCode) top = r;
        }
      }
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(top?.name ?? ' ', style: big)),
              const PlayMark(size: 12),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: TrackStrip(tracks: st?.tracks ?? const [], error: st?.error),
          ),
        ],
      );
    } else if (latest != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('${latest.version} (${latest.number})', style: big)),
              Text(relativeTime(latest.uploaded), style: TextStyle(fontSize: 12, color: t.text2)),
            ],
          ),
          const SizedBox(height: 12),
          BuildLane(item: latest),
        ],
      );
    } else {
      final loading = model.teams.values.any((s) => s.loading);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loading ? 'Loading builds…' : 'No builds yet', style: TextStyle(fontSize: 13.5, color: t.text2)),
          const SizedBox(height: 12),
          const BuildLane(item: null),
        ],
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: () => model.go(AppRoute.app(app.id)),
        child: AnimatedScale(
          scale: hover ? 1.012 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: hover ? 1 : 0.6,
                    duration: const Duration(milliseconds: 220),
                    child: AmbientGlow(url: model.iconUrl(app.id, 64), intensity: 0.45, height: 200, blur: 38),
                  ),
                ),
                Surface(
                  radius: 18,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Sensitive(
                            radius: 10,
                            child: AppIcon(url: model.iconUrl(app.id), name: app.name, size: 52),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Sensitive(
                                  child: Text(
                                    app.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Sensitive(
                                  child: Text(
                                    app.bundleId,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono(11.5, color: t.text2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (run != null)
                            Tooltip(
                              message: 'Shipping ${run.plan.version} (${run.plan.build})',
                              child: Pulse(child: Icon(Icons.send_rounded, size: 16, color: Palette.cyan)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      body,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Five lights for the road a build takes: upload, processing, internal
/// testers, beta review, external testers.
class BuildLane extends StatelessWidget {
  const BuildLane({super.key, required this.item, this.labels = true});
  final AscBuild? item;
  final bool labels;

  static const stages = ['Uploaded', 'Processed', 'Internal', 'Review', 'External'];

  List<StateTone> get lit {
    final b = item;
    if (b == null) return List.filled(5, StateTone.muted);
    final s = [StateTone.good, StateTone.muted, StateTone.muted, StateTone.muted, StateTone.muted];
    switch (b.processingState) {
      case 'VALID':
        s[1] = StateTone.good;
      case 'PROCESSING':
        s[1] = StateTone.active;
      case 'FAILED' || 'INVALID':
        s[1] = StateTone.bad;
    }
    if (b.expired) return s.map((x) => x == StateTone.good ? StateTone.muted : x).toList();
    switch (b.internalState) {
      case 'IN_BETA_TESTING':
        s[2] = StateTone.good;
      case 'PROCESSING' || 'READY_FOR_BETA_TESTING':
        s[2] = StateTone.active;
      case 'MISSING_EXPORT_COMPLIANCE':
        s[2] = StateTone.waiting;
    }
    switch (b.reviewState ?? b.externalState) {
      case 'APPROVED' || 'BETA_APPROVED' || 'IN_BETA_TESTING':
        s[3] = StateTone.good;
      case 'WAITING_FOR_REVIEW' || 'IN_REVIEW' || 'WAITING_FOR_BETA_REVIEW' || 'IN_BETA_REVIEW':
        s[3] = StateTone.active;
      case 'REJECTED' || 'BETA_REJECTED':
        s[3] = StateTone.bad;
      case 'READY_FOR_BETA_SUBMISSION':
        s[3] = StateTone.waiting;
    }
    if (b.externalState == 'IN_BETA_TESTING') s[4] = StateTone.good;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l = lit;
    final off = t.text2.withValues(alpha: 0.22);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth / stages.length;
        return SizedBox(
          height: labels ? 34 : 15,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < stages.length - 1; i++)
                Positioned(
                  left: w * i + w / 2 + 9,
                  width: (w - 18).clamp(0, double.infinity),
                  top: 6.75,
                  height: 1.5,
                  child: Container(
                    decoration: BoxDecoration(
                      color: l[i + 1] == StateTone.muted ? t.text2.withValues(alpha: 0.18) : l[i + 1].color(context).withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              for (var i = 0; i < stages.length; i++)
                Positioned(
                  left: w * i,
                  width: w,
                  top: 0,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 15,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (l[i] == StateTone.active)
                              Container(
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: l[i].color(context).withValues(alpha: 0.45), width: 2),
                                ),
                              ),
                            Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: l[i] == StateTone.muted ? off : l[i].color(context),
                                boxShadow: l[i] == StateTone.muted ? null : [BoxShadow(color: l[i].color(context).withValues(alpha: 0.6), blurRadius: 5)],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (labels) ...[
                        const SizedBox(height: 5),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              stages[i],
                              maxLines: 1,
                              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w500, color: l[i] == StateTone.muted ? t.text3 : t.text2),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class TeamPage extends StatelessWidget {
  const TeamPage({super.key, required this.teamId});
  final String teamId;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final pair = model.workspace.team(teamId);
    if (pair == null) return const Center(child: Text('Team not found'));
    final (account: account, team: team) = pair;
    final state = model.teams[team.id];
    final subtitle = <String>{
      if (team.teamId != null) 'Team ${team.teamId}',
      team.credential.summary,
      if (!team.credential.summary.endsWith(account.name)) account.name,
    }.join(' · ');
    return PageFrame(
      glowHeight: 380,
      children: [
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: t.chipFill, borderRadius: BorderRadius.circular(14)),
              alignment: Alignment.center,
              child: ProviderMark(account.provider, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Sensitive(
                    radius: 10,
                    child: Text(team.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                  ),
                  const SizedBox(height: 4),
                  Sensitive(
                    child: Text(subtitle, style: TextStyle(color: t.text2)),
                  ),
                ],
              ),
            ),
            SoftButton(label: 'Refresh', icon: Icons.refresh_rounded, onPressed: state?.loading == true ? null : () => unawaited(model.refreshTeam(team))),
            const SizedBox(width: 8),
            SoftButton(
              label: 'Remove',
              icon: Icons.delete_outline_rounded,
              destructive: true,
              tooltip: 'Forget this team and delete its key from the keychain',
              onPressed: () => confirmRemoveTeam(context, model, team),
            ),
          ],
        ),
        if (state?.error != null) ...[const SizedBox(height: 18), WarningLine(state!.error!)],
        if (team.credential.isGoogle) ...[const SizedBox(height: 18), PackagesEditor(team: team)],
        const SizedBox(height: 22),
        AppGrid(apps: state?.apps ?? const []),
      ],
    );
  }
}

/// The Play apps a developer account shows, by package name.
class PackagesEditor extends StatefulWidget {
  const PackagesEditor({super.key, required this.team});
  final Team team;

  @override
  State<PackagesEditor> createState() => _PackagesEditorState();
}

class _PackagesEditorState extends State<PackagesEditor> {
  final adding = TextEditingController();

  @override
  void dispose() {
    adding.dispose();
    super.dispose();
  }

  void _add() {
    final model = ModelScope.read(context);
    final pkg = adding.text.trim();
    if (!pkg.contains('.') || widget.team.packages.contains(pkg)) return;
    model.setPackages([...widget.team.packages, pkg], widget.team);
    adding.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    return Surface(
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.add_box_outlined, size: 18, color: t.text2),
              const SizedBox(width: 10),
              Expanded(
                child: Field(
                  controller: adding,
                  isMono: true,
                  hint: 'Add an app by package name, e.g. com.example.app',
                  onSubmitted: (_) => _add(),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              SoftButton(label: 'Add', onPressed: adding.text.contains('.') ? _add : null),
            ],
          ),
          if (widget.team.packages.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final pkg in widget.team.packages)
                  Container(
                    padding: const EdgeInsets.fromLTRB(9, 3, 4, 3),
                    decoration: BoxDecoration(color: t.chipFill, borderRadius: BorderRadius.circular(99)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Sensitive(
                          radius: 4,
                          child: Text(pkg, style: mono(11.5, color: t.text2)),
                        ),
                        const SizedBox(width: 2),
                        IconBtn(
                          Icons.close_rounded,
                          size: 12,
                          tooltip: 'Remove $pkg',
                          onPressed: () => model.setPackages(widget.team.packages.where((x) => x != pkg).toList(), widget.team),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The first screen: no accounts yet.
class WelcomeView extends StatefulWidget {
  const WelcomeView({super.key});

  @override
  State<WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends State<WelcomeView> {
  bool appear = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => appear = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    return Theme(
      data: buildTheme(Brightness.dark),
      child: Builder(
        builder: (context) {
          return Stack(
            children: [
              const Positioned.fill(child: MeshBackdrop(palette: MeshPalette.idle)),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedScale(
                        scale: appear ? 1 : 0.8,
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.elasticOut,
                        child: AnimatedOpacity(opacity: appear ? 1 : 0, duration: const Duration(milliseconds: 400), child: const BrandGlyph(size: 92)),
                      ),
                      const SizedBox(height: 30),
                      const Text(
                        'Every release, one desk.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -0.8, color: Colors.white),
                      ),
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: Text(
                          'Connect your store accounts. Release Desk keeps each team apart, shows every app, build and tester group, and ships updates from your computer or GitHub Actions to testers\' phones.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17, color: Colors.white.withValues(alpha: 0.6), height: 1.4),
                        ),
                      ),
                      const SizedBox(height: 30),
                      Wrap(
                        spacing: 18,
                        runSpacing: 18,
                        alignment: WrapAlignment.center,
                        children: [
                          ProviderTile(
                            title: 'App Store Connect',
                            subtitle: 'API key (.p8) per team',
                            icon: const Icon(Icons.apple, size: 28, color: Colors.white),
                            onTap: () => model.connect(StoreProvider.apple),
                          ),
                          ProviderTile(
                            title: 'Google Play',
                            subtitle: 'Sign in with your Google account',
                            icon: const PlayMark(size: 28),
                            onTap: () => model.connect(StoreProvider.google),
                          ),
                        ],
                      ),
                      const SizedBox(height: 30),
                      Text(
                        'Keys go to your system keychain. Nothing leaves this computer except calls to Apple, Google and GitHub.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13.5, color: Colors.white.withValues(alpha: 0.35)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ProviderTile extends StatefulWidget {
  const ProviderTile({super.key, required this.title, required this.subtitle, required this.icon, required this.onTap});
  final String title;
  final String subtitle;
  final Widget icon;
  final VoidCallback onTap;

  @override
  State<ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<ProviderTile> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: hover ? 1.03 : 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          child: Glass(
            radius: 22,
            tint: Colors.white.withValues(alpha: hover ? 0.12 : 0.07),
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: 270,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      widget.icon,
                      const Spacer(),
                      AnimatedOpacity(
                        opacity: hover ? 1 : 0.4,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Text(widget.subtitle, style: TextStyle(fontSize: 13.5, color: Colors.white.withValues(alpha: 0.6))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
