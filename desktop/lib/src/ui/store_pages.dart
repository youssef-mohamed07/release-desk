import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_gallery.dart';
import '../core/asc.dart';
import '../core/store_languages.dart';
import 'app_model.dart';
import 'overview.dart';
import 'theme.dart';

/// AppGallery's release states, in colour.
StateTone agcTone(AgcApp a) => switch (a.releaseState) {
  0 => StateTone.good,
  3 || 4 || 5 || 12 => StateTone.active,
  7 => StateTone.waiting,
  1 || 8 || 9 || 13 => StateTone.bad,
  _ => StateTone.muted,
};

/// Partner Center's submission states, in words and colour.
({String label, StateTone tone}) describeMicrosoft(String? raw) => switch (raw) {
  null => (label: '—', tone: StateTone.muted),
  'Published' => (label: 'Published', tone: StateTone.good),
  'PendingCommit' => (label: 'Draft', tone: StateTone.waiting),
  'CommitStarted' || 'PreProcessing' => (label: 'Processing', tone: StateTone.active),
  'Certification' => (label: 'In certification', tone: StateTone.active),
  'Release' || 'Publishing' || 'PendingPublication' => (label: 'Publishing', tone: StateTone.active),
  final String s when s.endsWith('Failed') => (label: s.replaceAll('Failed', ' failed'), tone: StateTone.bad),
  'Canceled' => (label: 'Canceled', tone: StateTone.muted),
  final String s => (label: s, tone: StateTone.muted),
};

/// The page of an app on Huawei AppGallery.
class AgcAppPage extends StatelessWidget {
  const AgcAppPage({super.key, required this.app});
  final StoreApp app;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final state = model.apps[app.id] ?? AppState();
    final a = state.agc;
    final langs = a == null ? const <String>[] : (a.newFeatures.keys.toList()..sort());
    return PageFrame(
      glowUrl: model.iconUrl(app.id),
      glowIntensity: 0.4,
      glowHeight: 420,
      toolbar: Row(
        children: [IconBtn(Icons.refresh_rounded, tooltip: 'Refresh', onPressed: () => unawaited(model.refreshApp(app.id)))],
      ),
      children: [
        _StoreHero(
          app: app,
          mark: const AppGalleryMark(size: 22),
          status: a == null
              ? null
              : Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      a.version ?? 'No version',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, fontFeatures: tabular),
                    ),
                    ToneText(a.stateTitle, agcTone(a)),
                    if (a.versionOnShelf != null) Text('· ${a.versionOnShelf} on sale', style: TextStyle(color: t.text2, fontSize: 13.5)),
                  ],
                ),
          links: [
            LinkText(
              'AppGallery Connect',
              icon: Icons.open_in_new_rounded,
              onTap: () => launchUrl(Uri.parse('https://developer.huawei.com/consumer/en/service/josp/agc/index.html')),
            ),
          ],
        ),
        if (state.error != null) ...[const SizedBox(height: 20), WarningLine(state.error!)],
        if (a != null) ...[
          if ((a.reviewNote ?? '').isNotEmpty) ...[
            const SizedBox(height: 28),
            const SectionHeader('Review notes', icon: Icons.chat_bubble_outline_rounded),
            const SizedBox(height: 10),
            Surface(
              child: Sensitive(radius: 5, child: SelectableText(a.reviewNote!, style: const TextStyle(fontSize: 13.5))),
            ),
          ],
          if (a.phasedState != null) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Icon(Icons.bar_chart_rounded, size: 16, color: t.text2),
                const SizedBox(width: 6),
                Text('Phased release: ${a.phasedState!.toLowerCase()}', style: TextStyle(color: t.text2)),
              ],
            ),
          ],
          const SizedBox(height: 28),
          SectionHeader("What's new", subtitle: langs.isEmpty ? null : '${langs.length}', icon: Icons.chat_bubble_rounded),
          const SizedBox(height: 10),
          if (langs.isEmpty) Text("No What's new on the version being prepared.", style: TextStyle(color: t.text2)),
          for (final lang in langs)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${StoreLanguages.name(lang.replaceAll('_', '-'))}  ·  $lang', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Sensitive(
                      radius: 5,
                      child: SelectableText(
                        a.newFeatures[lang] ?? '',
                        style: const TextStyle(fontSize: 13.5),
                        textDirection: StoreLanguages.isRightToLeft(lang.replaceAll('_', '-')) ? TextDirection.rtl : TextDirection.ltr,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ] else if (state.error == null) ...[
          const SizedBox(height: 28),
          Surface(
            child: Text(state.loading ? 'Loading…' : 'AppGallery has not shown this app yet.', style: TextStyle(color: t.text2)),
          ),
        ],
      ],
    );
  }
}

/// The page of an app in the Microsoft Store (Partner Center).
class MsAppPage extends StatelessWidget {
  const MsAppPage({super.key, required this.app});
  final StoreApp app;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final state = model.apps[app.id] ?? AppState();
    final m = state.ms;
    final storeId = app.storeId;
    final notes = m == null ? const <String>[] : (m.releaseNotes.keys.toList()..sort());
    return PageFrame(
      glowUrl: model.iconUrl(app.id),
      glowIntensity: 0.4,
      glowHeight: 420,
      toolbar: Row(
        children: [IconBtn(Icons.refresh_rounded, tooltip: 'Refresh', onPressed: () => unawaited(model.refreshApp(app.id)))],
      ),
      children: [
        _StoreHero(
          app: app,
          mark: const WindowsMark(size: 20),
          chips: [Tag(storeId, icon: Icons.tag_rounded, isMono: true, sensitive: true)],
          status: m == null || (m.lastStatus == null && m.pendingStatus == null)
              ? null
              : Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (m.lastStatus != null) ...[
                      Text('Published submission', style: TextStyle(color: t.text2, fontSize: 13.5)),
                      ToneText(describeMicrosoft(m.lastStatus).label, describeMicrosoft(m.lastStatus).tone),
                    ],
                    if (m.pendingStatus != null) ...[
                      Text('· Draft', style: TextStyle(color: t.text2, fontSize: 13.5)),
                      ToneText(describeMicrosoft(m.pendingStatus).label, describeMicrosoft(m.pendingStatus).tone),
                    ],
                  ],
                ),
          links: [
            LinkText(
              'Partner Center',
              icon: Icons.open_in_new_rounded,
              onTap: () => launchUrl(Uri.parse('https://partner.microsoft.com/dashboard/products/$storeId/overview')),
            ),
            LinkText('Store page', icon: Icons.storefront_outlined, onTap: () => launchUrl(Uri.parse('https://apps.microsoft.com/detail/$storeId'))),
          ],
        ),
        if (state.error != null) ...[const SizedBox(height: 20), WarningLine(state.error!)],
        if (m != null) ...[
          const SizedBox(height: 28),
          SectionHeader('Listing languages', subtitle: '${m.listingLanguages.length}', icon: Icons.language),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final l in m.listingLanguages) Tag(l, isMono: true)]),
          const SizedBox(height: 8),
          Text('Release Desk writes What\'s new only in languages the Store listing already has.', style: TextStyle(fontSize: 12, color: t.text2)),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 28),
            const SectionHeader("What's new", icon: Icons.chat_bubble_rounded),
            const SizedBox(height: 10),
            for (final lang in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Surface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        lang,
                        style: mono(12, weight: FontWeight.w600, color: t.text),
                      ),
                      const SizedBox(height: 4),
                      Sensitive(radius: 5, child: SelectableText(m.releaseNotes[lang] ?? '', style: const TextStyle(fontSize: 13.5))),
                    ],
                  ),
                ),
              ),
          ],
          if (m.firstPublished != null) ...[
            const SizedBox(height: 20),
            Text('First published ${dayMonthYear(m.firstPublished)}', style: TextStyle(fontSize: 12, color: t.text2)),
          ],
        ],
      ],
    );
  }
}

/// Icon, name, tags, a status line, the Ship button and store links.
class _StoreHero extends StatelessWidget {
  const _StoreHero({required this.app, required this.mark, this.chips = const [], this.status, this.links = const []});
  final StoreApp app;
  final Widget mark;
  final List<Widget> chips;
  final Widget? status;
  final List<Widget> links;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final team = model.teamOfApp(app.id);
    final link = model.workspace.link(app.id);
    final run = model.activeRun(app.id);
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
                  mark,
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  Tag(app.bundleId, icon: Icons.inventory_2_outlined, isMono: true, sensitive: true),
                  ...chips,
                  if (team != null) Tag(team.name, icon: Icons.people_outline, sensitive: true),
                  if (link != null) Tag(tildePath(link.path), icon: Icons.folder_outlined, isMono: true, sensitive: true),
                ],
              ),
              if (status != null) ...[const SizedBox(height: 8), status!],
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
            for (final l in links) ...[const SizedBox(height: 10), l],
          ],
        ),
      ],
    );
  }
}
