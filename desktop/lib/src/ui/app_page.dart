import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/asc.dart';
import '../core/store_languages.dart';
import 'app_model.dart';
import 'overview.dart';
import 'play_pages.dart';
import 'theme.dart';

class AppPage extends StatefulWidget {
  const AppPage({super.key, required this.appId});
  final String appId;

  @override
  State<AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<AppPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ModelScope.read(context).refreshApp(widget.appId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final app = model.app(widget.appId);
    if (app == null) return const Center(child: Text('Loading app…'));
    if (app.isPlay) return PlayAppPage(app: app);
    final state = model.apps[app.id] ?? AppState();
    return PageFrame(
      glowUrl: model.iconUrl(app.id),
      glowIntensity: 0.6,
      glowHeight: 520,
      toolbar: Row(
        children: [IconBtn(Icons.refresh_rounded, tooltip: 'Refresh', onPressed: () => unawaited(model.refreshApp(app.id)))],
      ),
      children: [
        _hero(context, model, app, state),
        if (state.error != null) ...[const SizedBox(height: 20), WarningLine(state.error!)],
        const SizedBox(height: 30),
        _builds(context, app, state),
        const SizedBox(height: 30),
        _groups(context, state),
        const SizedBox(height: 30),
        _versions(context, state),
      ],
    );
  }

  Widget _hero(BuildContext context, AppModel model, StoreApp app, AppState state) {
    final t = context.tokens;
    final team = model.teamOfApp(app.id);
    final link = model.workspace.link(app.id);
    final run = model.activeRun(app.id);
    final latest = state.builds.isEmpty ? null : state.builds.first;
    return Row(
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
              Sensitive(
                radius: 12,
                child: Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.6),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  Tag(app.bundleId, icon: Icons.inventory_2_outlined, isMono: true, sensitive: true),
                  if (team != null) Tag(team.name, icon: Icons.people_outline, sensitive: true),
                  if (app.primaryLocale.isNotEmpty) Tag(app.primaryLocale, icon: Icons.language),
                  if (link != null) Tag(tildePath(link.path), icon: Icons.folder_outlined, isMono: true, sensitive: true),
                ],
              ),
              if (latest != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text('Latest', style: TextStyle(color: t.text2, fontSize: 13.5)),
                    Text(
                      '${latest.version} (${latest.number})',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, fontFeatures: tabular),
                    ),
                    StatePill(latest.externalState ?? latest.processingState),
                    Text(relativeTime(latest.uploaded), style: TextStyle(color: t.text2, fontSize: 13.5)),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            PrimaryButton(
              label: run != null ? 'Shipping ${run.plan.version} (${run.plan.build})…' : 'Ship an update',
              icon: Icons.send_rounded,
              onPressed: () => model.go(AppRoute.ship(app.id)),
            ),
            const SizedBox(height: 10),
            LinkText(
              'Open in App Store Connect',
              icon: Icons.open_in_new_rounded,
              onTap: () => launchUrl(Uri.parse('https://appstoreconnect.apple.com/apps/${app.id}/testflight/ios')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _builds(BuildContext context, StoreApp app, AppState state) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('Builds', subtitle: state.builds.isEmpty ? null : '${state.builds.length} most recent', icon: Icons.inventory_2_outlined),
        const SizedBox(height: 14),
        if (state.builds.isEmpty)
          Surface(
            child: Text(state.loading ? 'Loading…' : 'No builds uploaded yet.', style: TextStyle(color: t.text2)),
          )
        else
          SizedBox(
            height: 178,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              itemCount: state.builds.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final b = state.builds[i];
                return BuildTicket(build: b, groups: state.groups, latest: i == 0, onTap: () => showBuildSheet(context, app, b, state.groups));
              },
            ),
          ),
      ],
    );
  }

  Widget _groups(BuildContext context, AppState state) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('TestFlight groups', subtitle: state.groups.isEmpty ? null : '${state.groups.length}', icon: Icons.groups_outlined),
        const SizedBox(height: 14),
        if (state.groups.isEmpty)
          Surface(
            child: Text(state.loading ? 'Loading…' : 'No tester groups yet.', style: TextStyle(color: t.text2)),
          )
        else
          LayoutBuilder(
            builder: (context, box) {
              const gap = 14.0;
              final cols = ((box.maxWidth + gap) / (300 + gap)).floor().clamp(1, 6);
              final w = (box.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final g in state.groups)
                    SizedBox(
                      width: w,
                      child: GroupCard(group: g, builds: state.builds),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _versions(BuildContext context, AppState state) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('App Store versions', icon: Icons.shopping_bag_outlined),
        const SizedBox(height: 14),
        if (state.versions.isEmpty)
          Surface(
            child: Text(state.loading ? 'Loading…' : 'No App Store versions yet.', style: TextStyle(color: t.text2)),
          )
        else ...[
          Surface(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Column(
              children: [
                for (final (i, v) in state.versions.indexed) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: Text(
                            v.version,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, fontFeatures: tabular),
                          ),
                        ),
                        SizedBox(
                          width: 60,
                          child: Text(v.platform == 'IOS' ? 'iOS' : v.platform, style: TextStyle(color: t.text2)),
                        ),
                        StatePill(v.state),
                        const Spacer(),
                        if (v.created != null) Text('Created ${dayMonthYear(v.created)}', style: TextStyle(color: t.text2, fontSize: 13)),
                      ],
                    ),
                  ),
                  if (i < state.versions.length - 1) Divider(height: 1, color: t.hairline),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Submitting a version for App Review is the next slice: Release Desk will check screenshots, the privacy answers and the build before it sends anything.',
            style: TextStyle(fontSize: 12, color: t.text3),
          ),
        ],
      ],
    );
  }
}

/// One build as a ticket stub: the build number big, its road below.
class BuildTicket extends StatefulWidget {
  const BuildTicket({super.key, required this.build, required this.groups, this.latest = false, this.onTap});
  final AscBuild build;
  final List<AscBetaGroup> groups;
  final bool latest;
  final VoidCallback? onTap;

  @override
  State<BuildTicket> createState() => _BuildTicketState();
}

class _BuildTicketState extends State<BuildTicket> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final b = widget.build;
    final tone = describeState(b.expired ? 'EXPIRED' : (b.externalState ?? b.processingState)).tone.color(context);
    final names = b.groupIds.map((id) => widget.groups.where((g) => g.id == id).firstOrNull?.name).whereType<String>().toList();
    final daysLeft = b.expires?.difference(DateTime.now()).inDays;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: hover ? 1.02 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: Opacity(
            opacity: b.expired ? 0.55 : 1,
            child: SizedBox(
              width: 280,
              child: Stack(
                children: [
                  Surface(
                    radius: 18,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            ShaderMask(
                              shaderCallback: (r) => LinearGradient(
                                colors: widget.latest ? [t.text, tone] : [t.text, t.text],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ).createShader(r),
                              child: Text(
                                b.number,
                                style: const TextStyle(fontSize: 40, height: 1.05, fontWeight: FontWeight.w800, color: Colors.white, fontFeatures: tabular),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    b.version,
                                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, fontFeatures: tabular),
                                  ),
                                  Text(dayMonth(b.uploaded), style: TextStyle(fontSize: 12, color: t.text2)),
                                ],
                              ),
                            ),
                            if (widget.latest)
                              Text(
                                'LATEST',
                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.8, color: tone),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        BuildLane(item: b),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.people_alt_rounded, size: 12, color: t.text2),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Sensitive(
                                radius: names.isEmpty ? 0 : 4,
                                child: Text(
                                  names.isEmpty ? 'No groups' : names.join(', '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: t.text2),
                                ),
                              ),
                            ),
                            if (daysLeft != null && !b.expired) Text('${daysLeft < 0 ? 0 : daysLeft}d left', style: TextStyle(fontSize: 10.5, color: t.text3)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 1,
                    top: 18,
                    bottom: 18,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(color: tone, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GroupCard extends StatefulWidget {
  const GroupCard({super.key, required this.group, required this.builds});
  final AscBetaGroup group;
  final List<AscBuild> builds;

  @override
  State<GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<GroupCard> {
  bool copied = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = widget.group;
    AscBuild? inGroup = widget.builds.where((b) => b.groupIds.contains(g.id)).firstOrNull;
    if (inGroup == null && g.allBuilds && widget.builds.isNotEmpty) inGroup = widget.builds.first;
    final c = g.isInternal ? Palette.indigo : Palette.mint;
    return Surface(
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: c.withValues(alpha: 0.18), shape: BoxShape.circle),
                child: Icon(g.isInternal ? Icons.apartment_rounded : Icons.public_rounded, size: 17, color: c),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Sensitive(
                      radius: 5,
                      child: Text(
                        g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      g.isInternal ? (g.allBuilds ? 'Internal · every build' : 'Internal') : 'External · needs beta review',
                      style: TextStyle(fontSize: 12, color: t.text2),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    g.testerCount?.toString() ?? '–',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, fontFeatures: tabular),
                  ),
                  Text('testers', style: TextStyle(fontSize: 10.5, color: t.text2)),
                ],
              ),
            ],
          ),
          if (inGroup != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Now testing', style: TextStyle(fontSize: 13.5, color: t.text2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${inGroup.version} (${inGroup.number})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, fontFeatures: tabular),
                  ),
                ),
                Flexible(child: StatePill(g.isInternal ? inGroup.internalState : inGroup.externalState, compact: true)),
              ],
            ),
          ],
          if (g.publicLink != null && g.publicLinkEnabled) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.link_rounded, size: 15, color: t.text2),
                const SizedBox(width: 6),
                Expanded(
                  child: Sensitive(
                    child: Text(
                      g.publicLink!.replaceFirst('https://', ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(11.5, color: t.text2),
                    ),
                  ),
                ),
                SoftButton(
                  label: copied ? 'Copied' : 'Copy',
                  small: true,
                  onPressed: () async {
                    await copyText(g.publicLink!);
                    setState(() => copied = true);
                    await Future<void>.delayed(const Duration(milliseconds: 1500));
                    if (mounted) setState(() => copied = false);
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> showBuildSheet(BuildContext context, StoreApp app, AscBuild build, List<AscBetaGroup> groups) => showDialog<void>(
  context: context,
  builder: (_) => BuildSheet(app: app, build: build, groups: groups),
);

class BuildSheet extends StatefulWidget {
  const BuildSheet({super.key, required this.app, required this.build, required this.groups});
  final StoreApp app;
  final AscBuild build;
  final List<AscBetaGroup> groups;

  @override
  State<BuildSheet> createState() => _BuildSheetState();
}

class _BuildSheetState extends State<BuildSheet> {
  List<AscBetaLocalization> notes = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await ModelScope.read(context).ascClientForApp(widget.app.id);
      notes = await c.betaLocalizations(widget.build.id);
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final b = widget.build;
    final names = b.groupIds.map((id) => widget.groups.where((g) => g.id == id).firstOrNull?.name).whereType<String>().join(', ');
    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: t.text2, fontSize: 13.5)),
          ),
          Flexible(child: value),
        ],
      ),
    );
    return Dialog(
      child: SizedBox(
        width: 620,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Sensitive(
                    radius: 8,
                    child: AppIcon(url: b.iconUrl(128), name: widget.app.name, size: 48),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Sensitive(
                                child: Text(
                                  widget.app.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${b.version} (${b.number})',
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, fontFeatures: tabular),
                            ),
                          ],
                        ),
                        Text('Uploaded ${shortDateTime(b.uploaded)} · min iOS ${b.minOS ?? '?'}', style: TextStyle(color: t.text2)),
                      ],
                    ),
                  ),
                  SoftButton(label: 'Done', onPressed: () => Navigator.pop(context)),
                ],
              ),
              const SizedBox(height: 18),
              BuildLane(item: b),
              const SizedBox(height: 14),
              row('Processing', Align(alignment: Alignment.centerLeft, child: StatePill(b.processingState))),
              row('Internal', Align(alignment: Alignment.centerLeft, child: StatePill(b.internalState))),
              row('External', Align(alignment: Alignment.centerLeft, child: StatePill(b.externalState))),
              row('Beta review', Align(alignment: Alignment.centerLeft, child: StatePill(b.reviewState))),
              row('Groups', Sensitive(radius: 4, child: Text(names.isEmpty ? 'None' : names))),
              row(
                'Encryption',
                Text(b.usesNonExemptEncryption == false ? 'Exempt' : (b.usesNonExemptEncryption == true ? 'Uses non-exempt' : 'From Info.plist')),
              ),
              const SizedBox(height: 10),
              Divider(color: t.hairline),
              const SizedBox(height: 8),
              const Text('What to Test', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              Expanded(
                child: ListView(
                  children: [
                    for (final n in notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Surface(
                          radius: 12,
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                n.locale,
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.text2),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: double.infinity,
                                child: Sensitive(
                                  child: SelectableText(
                                    n.whatsNew.isEmpty ? '—' : n.whatsNew,
                                    textDirection: StoreLanguages.isRightToLeft(n.locale) ? TextDirection.rtl : TextDirection.ltr,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
