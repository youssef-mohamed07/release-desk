import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/asc.dart';
import '../core/errors.dart';
import '../core/flutter_project.dart';
import '../core/github.dart';
import '../core/release_run.dart';
import '../core/shell.dart';
import '../core/workspace.dart';
import 'app_model.dart';
import 'console.dart';
import 'overview.dart';
import 'play_pages.dart';
import 'theme.dart';

/// Ship an update: link the source folder once, compose the release, launch
/// it, and watch it fly.
class ShipPage extends StatelessWidget {
  const ShipPage({super.key, required this.appId});
  final String appId;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final app = model.app(appId);
    if (app == null) return const Center(child: Text('Loading app…'));
    final run = model.latestRun(appId);
    if (run != null && !model.composing.contains(appId)) {
      return LaunchConsole(
        key: ValueKey(run.id),
        run: run,
        onNew: () {
          model.composing.add(appId);
          model.go(AppRoute.ship(appId));
        },
      );
    }
    final link = model.workspace.link(appId);
    if (link == null) return LinkProjectPanel(key: ValueKey('link-$appId'), app: app);
    return app.isPlay
        ? PlayComposer(key: ValueKey('play-${link.path}'), app: app, link: link)
        : IosComposer(key: ValueKey('ios-${link.path}'), app: app, link: link);
  }
}

// MARK: - Link a project

class LinkProjectPanel extends StatefulWidget {
  const LinkProjectPanel({super.key, required this.app});
  final StoreApp app;

  @override
  State<LinkProjectPanel> createState() => _LinkProjectPanelState();
}

class _LinkProjectPanelState extends State<LinkProjectPanel> {
  List<FlutterProject> candidates = [];
  bool scanning = true;
  final path = TextEditingController();
  String? error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final model = ModelScope.read(context);
    final roots = ProjectScanner.roots(model.workspace.links.map((l) => l.path));
    final id = widget.app.bundleId;
    try {
      final found = await Isolate.run(() => ProjectScanner.projects(roots));
      candidates = found.where((p) => p.iosBundleId == id || p.androidPackage == id).toList();
    } catch (_) {}
    if (mounted) setState(() => scanning = false);
  }

  void _use(String dir) {
    final model = ModelScope.read(context);
    try {
      final proj = FlutterProject.inspect(dir);
      final builds = [proj.iosBundleId, proj.androidPackage].whereType<String>().toList();
      if (builds.isNotEmpty && !builds.contains(widget.app.bundleId)) {
        setState(() => error = 'That project builds ${builds.join(' and ')}, not ${widget.app.bundleId}.');
      } else {
        model.link(widget.app.id, dir);
      }
    } catch (e) {
      setState(() => error = describeError(e));
    }
  }

  String _expand(String s) {
    final t = s.trim();
    if (t.startsWith('~')) return p.join(Shell.home, t.substring(t.length > 1 ? 2 : 1));
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final app = widget.app;
    return Stack(
      children: [
        Positioned(left: 0, right: 0, top: 0, height: 520, child: AmbientGlow(url: model.iconUrl(app.id), intensity: 0.5, height: 520)),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Sensitive(
                    radius: 14,
                    child: AppIcon(url: model.iconUrl(app.id, 512), name: app.name, size: 96),
                  ),
                  const SizedBox(height: 26),
                  const Text(
                    'Where is this app built from?',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pick its Flutter project. Release Desk remembers it, and links the same app on the other store too.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.text2, fontSize: 14),
                  ),
                  const SizedBox(height: 26),
                  if (scanning)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8)),
                        const SizedBox(width: 10),
                        Text('Looking through your project folders…', style: TextStyle(color: t.text2)),
                      ],
                    ),
                  for (final c in candidates)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _CandidateRow(project: c, onTap: () => _use(c.root)),
                    ),
                  if (!scanning && candidates.isEmpty)
                    Text('No Flutter project in your project folders builds ${app.bundleId}.', style: TextStyle(color: t.text2)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Field(controller: path, isMono: true, hint: 'Paste or type a folder path', onSubmitted: (s) => _use(_expand(s))),
                      ),
                      const SizedBox(width: 8),
                      SoftButton(label: 'Use', onPressed: () => path.text.trim().isEmpty ? null : _use(_expand(path.text))),
                      const SizedBox(width: 8),
                      SoftButton(
                        label: 'Choose…',
                        icon: Icons.folder_open_rounded,
                        onPressed: () async {
                          final dir = await getDirectoryPath(confirmButtonText: 'Use this folder');
                          if (dir != null) _use(dir);
                        },
                      ),
                    ],
                  ),
                  if (error != null) ...[const SizedBox(height: 10), Text(error!, style: TextStyle(color: Palette.ember, fontSize: 13))],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CandidateRow extends StatefulWidget {
  const _CandidateRow({required this.project, required this.onTap});
  final FlutterProject project;
  final VoidCallback onTap;

  @override
  State<_CandidateRow> createState() => _CandidateRowState();
}

class _CandidateRowState extends State<_CandidateRow> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final proj = widget.project;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: hover ? 1.01 : 1,
          duration: const Duration(milliseconds: 160),
          child: Surface(
            radius: 16,
            padding: const EdgeInsets.all(14),
            tint: hover ? (t.dark ? Colors.white.withValues(alpha: 0.08) : Colors.white) : null,
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 26, color: Palette.cyan),
                const SizedBox(width: 12),
                Expanded(
                  child: Sensitive(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tildePath(proj.root), style: mono(13, color: t.text)),
                        const SizedBox(height: 2),
                        Text(
                          '${proj.name} · ${proj.version}+${proj.buildNumber} · iOS ${proj.iosBundleId ?? '–'} · Android ${proj.androidPackage ?? '–'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: t.text2),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Text('Use this', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                const Icon(Icons.arrow_forward_rounded, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// MARK: - Shared pieces

/// The composer's frame: header, two columns of cards, and the launch bar.
class _ComposerFrame extends StatelessWidget {
  const _ComposerFrame({required this.glowUrl, required this.header, required this.left, required this.right, required this.bar, this.banners = const []});
  final String? glowUrl;
  final Widget header;
  final List<Widget> banners;
  final List<Widget> left;
  final List<Widget> right;
  final Widget bar;

  @override
  Widget build(BuildContext context) {
    List<Widget> spaced(List<Widget> ws) => [
      for (final (i, w) in ws.indexed) ...[if (i > 0) const SizedBox(height: 20), w],
    ];
    return Stack(
      children: [
        Positioned(left: 0, right: 0, top: 0, height: 460, child: AmbientGlow(url: glowUrl, intensity: 0.45, height: 460)),
        LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 980;
            return ListView(
              padding: const EdgeInsets.fromLTRB(32, 26, 32, 130),
              children: [
                header,
                for (final b in banners) ...[const SizedBox(height: 16), b],
                const SizedBox(height: 22),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 410,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(left)),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(right)),
                      ),
                    ],
                  )
                else
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced([...left, ...right])),
              ],
            );
          },
        ),
        Positioned(left: 26, right: 26, bottom: 18, child: bar),
      ],
    );
  }
}

class _ComposerHeader extends StatelessWidget {
  const _ComposerHeader({required this.app, required this.link, required this.project, required this.platformTag, this.play = false});
  final StoreApp app;
  final ProjectLink link;
  final FlutterProject? project;
  final Widget platformTag;
  final bool play;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    return Row(
      children: [
        Sensitive(
          radius: 10,
          child: AppIcon(url: model.iconUrl(app.id), name: app.name, size: 64),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Ship ', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                  Flexible(
                    child: Sensitive(
                      radius: 10,
                      child: Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                      ),
                    ),
                  ),
                  if (play) ...[const SizedBox(width: 8), const PlayMark(size: 20)],
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  Tag(tildePath(link.path), icon: Icons.folder_outlined, isMono: true, sensitive: true),
                  if (project != null) Tag('pubspec ${project!.version}+${project!.buildNumber}', icon: Icons.description_outlined, isMono: true),
                  platformTag,
                ],
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          icon: Icon(Icons.more_horiz_rounded, color: context.tokens.text2),
          onSelected: (v) {
            if (v == 'change') model.unlink(app.id);
            if (v == 'reveal') Shell.open(link.path);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'change', height: 34, child: Text('Change project folder…')),
            PopupMenuItem(value: 'reveal', height: 34, child: Text('Open the folder')),
          ],
        ),
      ],
    );
  }
}

class _BigNumberField extends StatelessWidget {
  const _BigNumberField({required this.label, required this.controller, this.width = 130, this.digitsOnly = false, this.onChanged});
  final String label;
  final TextEditingController controller;
  final double width;
  final bool digitsOnly;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: t.text2)),
        const SizedBox(height: 4),
        SizedBox(
          width: width,
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            inputFormatters: digitsOnly ? [FilteringTextInputFormatter.digitsOnly] : null,
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: t.text, fontFeatures: tabular),
            decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
          ),
        ),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.onUp, required this.onDown});
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(color: t.chipFill, borderRadius: BorderRadius.circular(7)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onUp,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Icon(Icons.keyboard_arrow_up_rounded, size: 16, color: t.text2),
            ),
          ),
          InkWell(
            onTap: onDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: t.text2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Release notes per language, RTL where the language is.
class _NotesCard extends StatelessWidget {
  const _NotesCard({
    required this.title,
    required this.locales,
    required this.controllers,
    required this.limit,
    required this.onChanged,
    this.action,
    this.footer,
  });
  final String title;
  final List<String> locales;
  final Map<String, TextEditingController> controllers;
  final int limit;
  final VoidCallback onChanged;
  final Widget? action;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CardTitle(title, Icons.chat_bubble_rounded, trailing: action),
          for (final locale in locales) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Text(localeName(locale), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Text(locale, style: mono(11.5, color: t.text3)),
                const Spacer(),
                Text(
                  '${controllers[locale]!.text.length}/$limit',
                  style: TextStyle(fontSize: 11, color: controllers[locale]!.text.length > limit ? Colors.orange : t.text3, fontFeatures: tabular),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Sensitive(
              radius: 5,
              child: Field(
                controller: controllers[locale]!,
                minLines: 6,
                maxLines: 14,
                textDirection: locale.startsWith('ar') ? TextDirection.rtl : TextDirection.ltr,
                onChanged: (_) => onChanged(),
              ),
            ),
          ],
          if (footer != null) ...[const SizedBox(height: 10), Text(footer!, style: TextStyle(fontSize: 12, color: t.text3))],
        ],
      ),
    );
  }
}

class _LaunchBar extends StatelessWidget {
  const _LaunchBar({
    required this.app,
    required this.version,
    required this.number,
    required this.destination,
    required this.rehearsal,
    required this.onLaunch,
    this.error,
    this.color,
  });
  final StoreApp app;
  final String version;
  final int number;
  final String destination;
  final bool rehearsal;
  final VoidCallback? onLaunch;
  final String? error;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Glass(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Sensitive(
                        child: Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    Text(
                      ' $version ($number)',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: tabular),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Sensitive(
                  radius: 4,
                  child: Text(
                    destination,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.text2),
                  ),
                ),
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Palette.ember),
              ),
            ),
          ],
          const SizedBox(width: 16),
          Tooltip(
            message: '$modKey${isMac ? '' : ''}Return',
            child: PrimaryButton(
              label: rehearsal ? 'Rehearse' : 'Launch',
              icon: rehearsal ? Icons.play_circle_outline_rounded : Icons.send_rounded,
              color: rehearsal ? Palette.violet : (color ?? Palette.indigo),
              onPressed: onLaunch,
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirm(BuildContext context, {required String title, required String message, required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 440, child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

/// The composer's ⌘/Ctrl+Return launches.
Widget _launchShortcut({required Widget child, required VoidCallback? onLaunch}) => CallbackShortcuts(
  bindings: {SingleActivator(LogicalKeyboardKey.enter, meta: isMac, control: !isMac): () => onLaunch?.call()},
  child: FocusScope(child: child),
);

// MARK: - Build on GitHub

/// The "Build on GitHub" checklist: signed in, workflow on the default
/// branch, secrets set. Buttons fix each one.
class CloudBuildCard extends StatefulWidget {
  const CloudBuildCard({super.key, required this.app, required this.link, required this.target, required this.onChanged, this.header});
  final StoreApp app;
  final ProjectLink link;
  final CloudTarget target;
  final void Function(GitHubRepo? repo, bool ready) onChanged;
  final Widget? header;

  @override
  State<CloudBuildCard> createState() => _CloudBuildCardState();
}

class _CloudBuildCardState extends State<CloudBuildCard> {
  bool busy = false;
  GitHubRepo? repo;
  bool detected = false;
  String? user;
  bool? workflow;
  Set<String>? secrets;
  String? error;
  String? wrote;
  String? flutterVersion;

  bool get secretsOk => secrets != null && widget.target.secretNames.every(secrets!.contains);
  bool get ready => user != null && workflow == true && secretsOk;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  void _report() => widget.onChanged(repo, ready);

  Future<void> _check() async {
    final model = ModelScope.read(context);
    setState(() {
      busy = true;
      error = null;
    });
    final s = await model.cloudStatus(widget.link.path, widget.target, known: repo, flutterVersion: flutterVersion);
    detected = true;
    repo = s.repo;
    user = s.user;
    workflow = s.workflow;
    secrets = s.secrets;
    error = s.error;
    flutterVersion = s.flutterVersion;
    if (!mounted) return;
    setState(() => busy = false);
    _report();
  }

  Future<void> _writeWorkflow() async {
    final model = ModelScope.read(context);
    final r = repo;
    if (r == null) return;
    final root = r.repoRoot(widget.link.path);
    final file = File(p.join(root, '.github', 'workflows', widget.target.workflowFile));
    final yaml = widget.target.yaml(
      projectDir: r.projectDir,
      exportOptions: widget.link.recipe.exportOptions,
      entitlements: widget.link.recipe.entitlements,
      teamId: model.teamOfApp(widget.app.id)?.teamId,
      flutterVersion: flutterVersion,
    );
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(yaml);
      setState(() => wrote = file.path);
    } catch (e) {
      setState(() => error = describeError(e));
    }
  }

  Future<void> _setSecrets() async {
    final model = ModelScope.read(context);
    final r = repo;
    if (r == null) return;
    final privacy = PrivacyScope.of(context);
    final ios = widget.target == CloudTarget.ios;
    final ok = await _confirm(
      context,
      title: "Set the repository's secrets?",
      message: ios
          ? "Release Desk puts this team's App Store Connect key into ${privacy ? 'the repository' : r.fullName}'s Actions secrets with the GitHub CLI. Anyone who can change its workflows can then use the key."
          : "Release Desk puts the upload key from android/key.properties into ${privacy ? 'the repository' : r.fullName}'s Actions secrets with the GitHub CLI. Anyone who can change its workflows can then sign with it.",
      action: 'Set secrets',
    );
    if (!ok || !mounted) return;
    setState(() => busy = true);
    try {
      await model.setCloudSecrets(widget.app.id, r, widget.target, widget.link.path);
      secrets = await model.github.secretsPresent(r);
    } catch (e) {
      error = describeError(e);
    }
    if (!mounted) return;
    setState(() => busy = false);
    _report();
  }

  Future<void> _useToken() async {
    final model = ModelScope.read(context);
    final ctl = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Use a GitHub token'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A fine-grained token with Actions (read and write), Secrets (read) and Contents (read) on the repository. It is kept in your system keychain.',
              ),
              const SizedBox(height: 12),
              Field(controller: ctl, obscure: true, autofocus: true, hint: 'github_pat_…', onSubmitted: (v) => Navigator.pop(c, v)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (token == null || token.trim().isEmpty) return;
    try {
      await model.saveGitHubToken(token);
    } catch (e) {
      model.say(describeError(e));
    }
    if (mounted) await _check();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ios = widget.target == CloudTarget.ios;
    final r = repo;
    final missing = secrets == null ? <String>[] : widget.target.secretNames.where((s) => !secrets!.contains(s)).toList();
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          widget.header ?? const CardTitle('Build on GitHub', Icons.cloud_outlined),
          const SizedBox(height: 12),
          if (busy && r == null)
            Row(
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8)),
                const SizedBox(width: 10),
                Text('Looking at the repository…', style: TextStyle(color: t.text2)),
              ],
            )
          else if (r != null) ...[
            Row(
              children: [
                Icon(Icons.code_rounded, size: 16, color: t.text2),
                const SizedBox(width: 6),
                Expanded(
                  child: Sensitive(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: r.fullName,
                            style: mono(12.5, color: t.text),
                          ),
                          TextSpan(
                            text: ' · ${r.projectDir}',
                            style: mono(12.5, color: t.text2),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                IconBtn(Icons.open_in_new_rounded, size: 15, tooltip: 'Open Actions on GitHub', onPressed: () => launchUrl(Uri.parse(r.actionsUrl))),
              ],
            ),
            const SizedBox(height: 8),
            _CheckRow(
              ok: user != null,
              title: user == null ? 'Sign in to GitHub' : 'Signed in to GitHub as $user',
              sensitiveTitle: user != null,
              hint: user == null ? 'Run gh auth login in a terminal, then check again. Or save a token.' : null,
              accessory: user == null ? SoftButton(label: 'Use a token…', small: true, onPressed: _useToken) : null,
            ),
            _CheckRow(
              ok: workflow == true,
              title: 'Workflow on the default branch',
              hint: wrote != null && workflow != true
                  ? 'Added to the project. Commit and push it, then check again.'
                  : (workflow == false ? '.github/workflows/${widget.target.workflowFile}' : null),
              accessory: workflow == true || workflow == null
                  ? null
                  : SoftButton(
                      label: wrote == null ? 'Add to project' : 'Show file',
                      small: true,
                      onPressed: wrote == null ? _writeWorkflow : () => Shell.reveal(wrote!),
                    ),
            ),
            _CheckRow(
              ok: secretsOk,
              title: 'Secrets ${widget.target.secretNames.join(', ')}',
              hint: missing.isEmpty ? null : 'Missing: ${missing.join(', ')}',
              accessory: secrets == null || secretsOk
                  ? null
                  : SoftButton(label: ios ? "Set from this team's key" : 'Set from android/key.properties', small: true, onPressed: busy ? null : _setSecrets),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    ios
                        ? "Windows and Linux can't build iOS apps, so a GitHub macOS runner archives, signs and uploads; this computer does the TestFlight steps. macOS minutes on private repositories cost more than Linux ones."
                        : 'A GitHub Linux runner builds and signs the bundle; this computer downloads it and releases it on Play, so no Google sign-in goes to GitHub.',
                    style: TextStyle(fontSize: 12, color: t.text2),
                  ),
                ),
                busy
                    ? const Padding(
                        padding: EdgeInsets.all(6),
                        child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8)),
                      )
                    : IconBtn(Icons.refresh_rounded, size: 16, tooltip: 'Check again', onPressed: _check),
              ],
            ),
          ] else
            Text(error ?? (detected ? 'This project has no GitHub remote (origin).' : ''), style: TextStyle(fontSize: 13.5, color: t.text2)),
          if (error != null && r != null) ...[const SizedBox(height: 8), WarningLine(error!)],
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.ok, required this.title, this.hint, this.accessory, this.sensitiveTitle = false});
  final bool ok;
  final String title;
  final String? hint;
  final Widget? accessory;
  final bool sensitiveTitle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 18, color: ok ? Palette.mint : t.text3),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Sensitive(
                  radius: sensitiveTitle ? 5 : 0,
                  child: Text(title, style: const TextStyle(fontSize: 13.5)),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(hint!, style: TextStyle(fontSize: 12, color: t.text2)),
                  ),
              ],
            ),
          ),
          if (accessory != null) ...[const SizedBox(width: 8), accessory!],
        ],
      ),
    );
  }
}

// MARK: - iOS

class IosComposer extends StatefulWidget {
  const IosComposer({super.key, required this.app, required this.link});
  final StoreApp app;
  final ProjectLink link;

  @override
  State<IosComposer> createState() => _IosComposerState();
}

class _IosComposerState extends State<IosComposer> {
  FlutterProject? project;
  String? loadError;
  final version = TextEditingController();
  final buildCtl = TextEditingController(text: '1');
  final selected = <String>{};
  late final Map<String, TextEditingController> notes = {for (final l in widget.link.recipe.locales) l: TextEditingController()};
  Map<String, String> previousNotes = {};
  List<String> commits = [];
  bool submitForReview = true;
  bool writeBuildNumber = true;
  bool rehearsal = false;
  bool ready = false;
  String? launchError;
  GitHubRepo? repo;
  bool cloudReady = false;

  int get buildNumber => int.tryParse(buildCtl.text) ?? 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    version.dispose();
    buildCtl.dispose();
    for (final c in notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  AppState _state(AppModel m) => m.apps[widget.app.id] ?? AppState();

  Future<void> _load() async {
    final model = ModelScope.read(context);
    try {
      project = FlutterProject.inspect(widget.link.path, entitlements: widget.link.recipe.entitlements);
    } catch (e) {
      setState(() => loadError = describeError(e));
      return;
    }
    if (!_state(model).detailed) await model.refreshApp(widget.app.id);
    if (!mounted) return;
    final st = _state(model);
    final proj = project!;
    final ascMax = st.builds.fold<int>(0, (a, b) => math.max(a, b.numericNumber));
    version.text = proj.version;
    buildCtl.text = '${math.max(ascMax + 1, proj.buildNumber)}';
    writeBuildNumber = widget.link.recipe.writeBuildNumber;
    submitForReview = widget.link.recipe.submitForReview;
    final remembered = widget.link.recipe.groupIds.toSet().intersection(st.groups.map((g) => g.id).toSet());
    selected
      ..clear()
      ..addAll(remembered.isEmpty ? st.groups.map((g) => g.id) : remembered);
    final draft = model.draft(widget.app.id);
    for (final e in notes.entries) {
      e.value.text = draft[e.key] ?? '';
    }
    setState(() => ready = true);
    final latest = st.builds.isEmpty ? null : st.builds.first;
    if (latest != null) {
      try {
        final c = await model.ascClientForApp(widget.app.id);
        final locs = await c.betaLocalizations(latest.id);
        previousNotes = {for (final l in locs) l.locale: l.whatsNew};
      } catch (_) {}
    }
    commits = await model.commitsSince(proj, latest?.uploaded);
    if (mounted) setState(() {});
  }

  void _notesChanged() {
    ModelScope.read(context).saveDraft(widget.app.id, {for (final e in notes.entries) e.key: e.value.text});
    setState(() {});
  }

  List<AscBetaGroup> _groups(AppState st) => st.groups.where((g) => selected.contains(g.id)).toList();

  bool _taken(AppState st) => st.builds.any((b) => b.version == version.text.trim() && b.numericNumber == buildNumber);

  String _destination(AppState st) {
    if (rehearsal) return 'Rehearsal on GitHub · archive, sign, export';
    final g = _groups(st);
    return [
      'GitHub build',
      g.isEmpty ? 'no tester groups' : g.map((x) => x.name).join(' + '),
      if (submitForReview && g.any((x) => !x.isInternal)) 'beta review',
    ].join(' → ');
  }

  Future<void> _confirmAndLaunch() async {
    final model = ModelScope.read(context);
    final st = _state(model);
    if (!_canLaunch(model, st)) return;
    final privacy = PrivacyScope.of(context);
    final name = privacy ? 'this app' : widget.app.name;
    final where = 'on a GitHub macOS runner (${privacy ? 'the repository' : repo?.fullName ?? ''})';
    final g = _groups(st);
    var msg = rehearsal ? 'Builds $where, signs and exports the IPA. Nothing is uploaded.' : 'Builds $where and uploads it to App Store Connect.';
    if (!rehearsal) {
      if (g.isNotEmpty) {
        final testers = g.map((x) => x.testerCount ?? 0).fold<int>(0, (a, b) => a + b);
        msg += ' Adds it to ${privacy ? '${g.length} tester groups' : g.map((x) => x.name).join(' and ')} ($testers testers).';
      }
      if (notes.values.any((c) => c.text.trim().isNotEmpty)) msg += ' Writes What to Test.';
      if (submitForReview && g.any((x) => !x.isInternal)) msg += ' Submits it for beta app review.';
    }
    final ok = await _confirm(
      context,
      title: '${rehearsal ? 'Rehearse' : 'Ship'} $name ${version.text.trim()} ($buildNumber)?',
      message: msg,
      action: rehearsal ? 'Rehearse' : 'Ship to TestFlight',
    );
    if (ok && mounted) await _launch();
  }

  bool _canLaunch(AppModel model, AppState st) =>
      ready && !_taken(st) && version.text.trim().isNotEmpty && buildNumber > 0 && model.activeRun(widget.app.id) == null && cloudReady && repo != null;

  Future<void> _launch() async {
    final model = ModelScope.read(context);
    final st = _state(model);
    final ordered = _groups(st);
    model.updateRecipe(widget.app.id, (r) {
      r.groupIds = ordered.map((g) => g.id).toList();
      r.submitForReview = submitForReview;
      r.writeBuildNumber = writeBuildNumber;
    });
    final recipe = (model.workspace.link(widget.app.id)?.recipe ?? widget.link.recipe).copy()..writeBuildNumber = writeBuildNumber;
    final plan = ReleasePlan(
      platform: ReleasePlatform.ios,
      app: widget.app,
      projectRoot: project!.root,
      version: version.text.trim(),
      build: buildNumber,
      recipe: recipe,
      teamId: model.teamOfApp(widget.app.id)?.teamId,
      groups: ordered,
      whatsNew: {
        for (final e in notes.entries)
          if (e.value.text.trim().isNotEmpty) e.key: e.value.text,
      },
      submitForReview: submitForReview,
      rehearsal: rehearsal,
      cloud: CloudBuild(repo!, CloudTarget.ios),
    );
    try {
      await model.launch(plan);
      if (!rehearsal) model.saveDraft(widget.app.id, {});
    } catch (e) {
      setState(() => launchError = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final st = _state(model);
    final latest = st.builds.isEmpty ? null : st.builds.first;
    final taken = _taken(st);
    final g = _groups(st);
    final can = _canLaunch(model, st);
    return _launchShortcut(
      onLaunch: _confirmAndLaunch,
      child: _ComposerFrame(
        glowUrl: model.iconUrl(widget.app.id),
        header: _ComposerHeader(
          app: widget.app,
          link: widget.link,
          project: project,
          platformTag: const Tag('iOS · TestFlight', icon: Icons.phone_iphone_rounded),
        ),
        banners: [if (loadError != null) Surface(child: WarningLine(loadError!))],
        left: [
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CardTitle('Release', Icons.tag_rounded),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _BigNumberField(label: 'Version', controller: version, onChanged: (_) => setState(() {})),
                    const SizedBox(width: 18),
                    _BigNumberField(label: 'Build', controller: buildCtl, width: 96, digitsOnly: true, onChanged: (_) => setState(() {})),
                    _Stepper(
                      onUp: () => setState(() => buildCtl.text = '${buildNumber + 1}'),
                      onDown: () => setState(() => buildCtl.text = '${math.max(1, buildNumber - 1)}'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (taken)
                  Text('${version.text} ($buildNumber) is already on App Store Connect.', style: const TextStyle(fontSize: 12, color: Colors.orange))
                else if (latest != null)
                  Text('Last upload: ${latest.version} (${latest.number}), ${relativeTime(latest.uploaded)}.', style: TextStyle(fontSize: 12, color: t.text2)),
                const SizedBox(height: 12),
                ToggleRow(
                  title: 'Write ${version.text}+$buildNumber to pubspec.yaml',
                  caption: 'So the repo says what shipped. Commit it after.',
                  value: writeBuildNumber,
                  onChanged: (v) => setState(() => writeBuildNumber = v),
                ),
              ],
            ),
          ),
          CloudBuildCard(
            app: widget.app,
            link: widget.link,
            target: CloudTarget.ios,
            onChanged: (r, ok) => setState(() {
              repo = r;
              cloudReady = ok;
            }),
          ),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CardTitle('Testers', Icons.groups_rounded),
                const SizedBox(height: 12),
                if (st.groups.isEmpty) Text(st.loading ? 'Loading groups…' : 'This app has no TestFlight groups yet.', style: TextStyle(color: t.text2)),
                for (final grp in st.groups) ...[
                  _GroupToggle(
                    group: grp,
                    on: selected.contains(grp.id),
                    onTap: () => setState(() => selected.contains(grp.id) ? selected.remove(grp.id) : selected.add(grp.id)),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          Surface(
            child: Column(
              children: [
                ToggleRow(
                  title: 'Submit for beta review',
                  caption: 'External testers need it. Later builds of an approved version usually pass in minutes.',
                  value: submitForReview,
                  onChanged: g.any((x) => !x.isInternal) ? (v) => setState(() => submitForReview = v) : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(height: 1, color: t.hairline),
                ),
                ToggleRow(
                  title: 'Rehearsal',
                  caption: 'The GitHub run archives, signs and exports the IPA. Nothing is uploaded.',
                  value: rehearsal,
                  onChanged: (v) => setState(() => rehearsal = v),
                ),
              ],
            ),
          ),
        ],
        right: [
          _NotesCard(
            title: 'What to Test',
            locales: widget.link.recipe.locales,
            controllers: notes,
            limit: 4000,
            onChanged: _notesChanged,
            action: previousNotes.isEmpty
                ? null
                : SoftButton(
                    label: 'Start from build ${latest?.number ?? ''}',
                    small: true,
                    onPressed: () {
                      for (final e in previousNotes.entries) {
                        final c = notes[e.key];
                        if (c != null && c.text.isEmpty) c.text = e.value;
                      }
                      _notesChanged();
                    },
                  ),
          ),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CardTitle(
                  'Changes since build ${latest?.number ?? '–'}',
                  Icons.call_split_rounded,
                  trailing: Text('${commits.length} commits', style: TextStyle(fontSize: 12, color: t.text2)),
                ),
                const SizedBox(height: 10),
                if (commits.isEmpty) Text('No commits since the last upload.', style: TextStyle(fontSize: 13.5, color: t.text2)),
                for (final c in commits)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(color: Palette.violet, shape: BoxShape.circle),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Sensitive(radius: 5, child: SelectableText(c, style: const TextStyle(fontSize: 13.5))),
                        ),
                        IconBtn(
                          Icons.add_circle_outline_rounded,
                          size: 16,
                          tooltip: 'Add to the English notes',
                          onPressed: () {
                            final key = notes.keys.firstWhere((k) => k.startsWith('en'), orElse: () => notes.keys.last);
                            final cur = notes[key]!.text;
                            notes[key]!.text = '$cur${cur.isEmpty || cur.endsWith('\n') ? '' : '\n'}- $c';
                            _notesChanged();
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        bar: _LaunchBar(
          app: widget.app,
          version: version.text,
          number: buildNumber,
          destination: _destination(st),
          rehearsal: rehearsal,
          error: launchError,
          onLaunch: can ? _confirmAndLaunch : null,
        ),
      ),
    );
  }
}

class _GroupToggle extends StatelessWidget {
  const _GroupToggle({required this.group, required this.on, required this.onTap});
  final AscBetaGroup group;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: on ? Palette.mint.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? Palette.mint.withValues(alpha: 0.35) : t.text2.withValues(alpha: 0.15)),
          ),
          child: Row(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  on ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(on),
                  size: 20,
                  color: on ? Palette.mint : t.text2,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Sensitive(
                      radius: 5,
                      child: Text(group.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                    ),
                    Text(
                      group.isInternal ? (group.allBuilds ? 'Internal · gets every build' : 'Internal') : 'External · beta review',
                      style: TextStyle(fontSize: 12, color: t.text2),
                    ),
                  ],
                ),
              ),
              Text(
                '${group.testerCount ?? 0}',
                style: TextStyle(fontSize: 13.5, color: t.text2, fontFeatures: tabular),
              ),
              const SizedBox(width: 4),
              Icon(Icons.person_rounded, size: 13, color: t.text3),
            ],
          ),
        ),
      ),
    );
  }
}

// MARK: - Android

class PlayComposer extends StatefulWidget {
  const PlayComposer({super.key, required this.app, required this.link});
  final StoreApp app;
  final ProjectLink link;

  @override
  State<PlayComposer> createState() => _PlayComposerState();
}

class _PlayComposerState extends State<PlayComposer> {
  FlutterProject? project;
  String? loadError;
  final version = TextEditingController();
  final buildCtl = TextEditingController(text: '1');
  String track = 'internal';
  String status = 'completed';
  double rollout = 0.2;
  static const locales = ['en-US', 'ar'];
  final notes = {for (final l in locales) l: TextEditingController()};
  bool writeBuildNumber = true;
  bool rehearsal = false;
  bool ready = false;
  bool onGitHub = false;
  GitHubRepo? repo;
  bool cloudReady = false;
  String? launchError;

  int get buildNumber => int.tryParse(buildCtl.text) ?? 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    version.dispose();
    buildCtl.dispose();
    for (final c in notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  AppState _state(AppModel m) => m.apps[widget.app.id] ?? AppState();

  int _highest(AppState st) {
    var h = 0;
    for (final tr in st.tracks) {
      for (final r in tr.releases) {
        h = math.max(h, r.maxCode);
      }
    }
    return h;
  }

  List<(String, String)> _tracks(AppState st) => [
    ('internal', 'Internal'),
    ('alpha', 'Closed'),
    ('beta', 'Open'),
    ('production', 'Production'),
    for (final tr in st.tracks)
      if (!const ['internal', 'alpha', 'beta', 'production'].contains(tr.track)) (tr.track, tr.title),
  ];

  Future<void> _load() async {
    final model = ModelScope.read(context);
    try {
      project = FlutterProject.inspect(widget.link.path);
    } catch (e) {
      setState(() => loadError = describeError(e));
      return;
    }
    if (!_state(model).detailed) await model.refreshApp(widget.app.id);
    if (!mounted) return;
    final st = _state(model);
    version.text = project!.version;
    buildCtl.text = '${math.max(_highest(st) + 1, project!.buildNumber)}';
    writeBuildNumber = widget.link.recipe.writeBuildNumber;
    track = widget.link.recipe.playTrack ?? 'internal';
    status = widget.link.recipe.playStatus ?? 'completed';
    onGitHub = widget.link.recipe.androidBuildOn == 'github';
    final draft = model.draft(widget.app.id);
    for (final e in notes.entries) {
      e.value.text = draft[e.key] ?? '';
    }
    setState(() => ready = true);
  }

  void _notesChanged() {
    ModelScope.read(context).saveDraft(widget.app.id, {for (final e in notes.entries) e.key: e.value.text});
    setState(() {});
  }

  String get _statusText => switch (status) {
    'inProgress' => 'Staged rollout ${(rollout * 100).round()}%',
    'draft' => 'Draft',
    _ => 'Full rollout',
  };

  bool _canLaunch(AppModel model, AppState st) =>
      ready &&
      version.text.trim().isNotEmpty &&
      buildNumber > 0 &&
      model.activeRun(widget.app.id) == null &&
      (rehearsal || buildNumber > _highest(st)) &&
      (!onGitHub || (cloudReady && repo != null));

  Future<void> _confirmAndLaunch() async {
    final model = ModelScope.read(context);
    final st = _state(model);
    if (!_canLaunch(model, st)) return;
    final privacy = PrivacyScope.of(context);
    final name = privacy ? 'this app' : widget.app.name;
    final trackName = _tracks(st).where((x) => x.$1 == track).firstOrNull?.$2 ?? track;
    final where = onGitHub ? 'on a GitHub runner' : 'on this computer';
    final ok = await _confirm(
      context,
      title: rehearsal ? 'Rehearse $name ${version.text.trim()} ($buildNumber)?' : 'Release $name ${version.text.trim()} ($buildNumber) on Google Play?',
      message: rehearsal
          ? 'Builds the app bundle $where${onGitHub ? '' : ' and checks its signature'}. Nothing is uploaded.'
          : 'Builds the app bundle $where, uploads it and releases it to the $trackName track as ${_statusText.toLowerCase()}.',
      action: rehearsal ? 'Rehearse' : 'Release',
    );
    if (ok && mounted) await _launch();
  }

  Future<void> _launch() async {
    final model = ModelScope.read(context);
    model.updateRecipe(widget.app.id, (r) {
      r.playTrack = track;
      r.playStatus = status;
      r.writeBuildNumber = writeBuildNumber;
      r.androidBuildOn = onGitHub ? 'github' : null;
    });
    final recipe = (model.workspace.link(widget.app.id)?.recipe ?? widget.link.recipe).copy()..writeBuildNumber = writeBuildNumber;
    final plan = ReleasePlan(
      platform: ReleasePlatform.android,
      app: widget.app,
      projectRoot: project!.root,
      version: version.text.trim(),
      build: buildNumber,
      recipe: recipe,
      whatsNew: {
        for (final e in notes.entries)
          if (e.value.text.trim().isNotEmpty) e.key: e.value.text,
      },
      rehearsal: rehearsal,
      cloud: onGitHub ? CloudBuild(repo!, CloudTarget.android) : null,
      play: PlayTarget(track: track, status: status, userFraction: status == 'inProgress' ? rollout : null),
    );
    try {
      await model.launch(plan);
      if (!rehearsal) model.saveDraft(widget.app.id, {});
    } catch (e) {
      setState(() => launchError = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final st = _state(model);
    final highest = _highest(st);
    final team = model.teamOfApp(widget.app.id);
    final tracks = _tracks(st);
    final current = st.tracks.where((x) => x.track == track && x.releases.isNotEmpty).firstOrNull?.releases.first;
    final trackName = tracks.where((x) => x.$1 == track).firstOrNull?.$2 ?? track;
    return _launchShortcut(
      onLaunch: _confirmAndLaunch,
      child: _ComposerFrame(
        glowUrl: model.iconUrl(widget.app.id),
        header: _ComposerHeader(
          app: widget.app,
          link: widget.link,
          project: project,
          play: true,
          platformTag: const Tag('Android · Google Play', icon: Icons.android_rounded),
        ),
        banners: [
          if (loadError != null) Surface(child: WarningLine(loadError!)),
          if (st.error != null && team != null) AccessCard(message: st.error!, team: team, retry: () => unawaited(model.refreshApp(widget.app.id))),
          if (project != null && !project!.hasUploadKey && !onGitHub)
            Surface(
              child: Row(
                children: [
                  Icon(Icons.key_off_outlined, color: waitingColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This project has no android/key.properties, so release builds are signed with the debug key and Play refuses them. A rehearsal still works.',
                      style: TextStyle(color: waitingColor),
                    ),
                  ),
                ],
              ),
            ),
        ],
        left: [
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CardTitle('Release', Icons.tag_rounded),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _BigNumberField(label: 'Version name', controller: version, onChanged: (_) => setState(() {})),
                    const SizedBox(width: 18),
                    _BigNumberField(label: 'Version code', controller: buildCtl, width: 120, digitsOnly: true, onChanged: (_) => setState(() {})),
                    _Stepper(
                      onUp: () => setState(() => buildCtl.text = '${buildNumber + 1}'),
                      onDown: () => setState(() => buildCtl.text = '${math.max(1, buildNumber - 1)}'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  st.error != null && st.tracks.isEmpty
                      ? "Play has not shown this app's version codes yet."
                      : (highest > 0 ? 'Highest on Play: $highest.' : 'No version code on Play yet.'),
                  style: TextStyle(fontSize: 12, color: buildNumber <= highest ? Colors.orange : t.text2),
                ),
                const SizedBox(height: 12),
                ToggleRow(
                  title: 'Write ${version.text}+$buildNumber to pubspec.yaml',
                  caption: 'So the repo says what shipped. Commit it after.',
                  value: writeBuildNumber,
                  onChanged: (v) => setState(() => writeBuildNumber = v),
                ),
              ],
            ),
          ),
          if (onGitHub)
            CloudBuildCard(
              app: widget.app,
              link: widget.link,
              target: CloudTarget.android,
              header: _buildOnHeader(),
              onChanged: (r, ok) => setState(() {
                repo = r;
                cloudReady = ok;
              }),
            )
          else
            Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildOnHeader(),
                  const SizedBox(height: 10),
                  Text('Flutter and the Android SDK on this computer build and sign the bundle.', style: TextStyle(fontSize: 12, color: t.text2)),
                ],
              ),
            ),
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CardTitle('Track', Icons.alt_route_rounded),
                const SizedBox(height: 14),
                Segmented<String>(items: tracks, value: track, expand: true, onChanged: (v) => setState(() => track = v)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('Rollout', style: TextStyle(fontSize: 13, color: t.text2)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Segmented<String>(
                        items: const [('completed', 'Full'), ('inProgress', 'Staged'), ('draft', 'Draft')],
                        value: status,
                        expand: true,
                        onChanged: (v) => setState(() => status = v),
                      ),
                    ),
                  ],
                ),
                if (status == 'inProgress')
                  Row(
                    children: [
                      Expanded(
                        child: Slider(value: rollout, min: 0.01, max: 0.99, divisions: 98, onChanged: (v) => setState(() => rollout = v)),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text('${(rollout * 100).round()}%', style: const TextStyle(fontFeatures: tabular)),
                      ),
                    ],
                  ),
                if (current != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Now on this track: ${current.name.isEmpty ? current.versionCodes.join(', ') : current.name} · ${current.statusLabel}',
                    style: TextStyle(fontSize: 12, color: t.text2),
                  ),
                ],
              ],
            ),
          ),
          Surface(
            child: ToggleRow(
              title: 'Rehearsal',
              caption: onGitHub
                  ? 'Build the app bundle on GitHub and download it. Nothing is uploaded.'
                  : 'Build the app bundle and check its signature. Nothing is uploaded.',
              value: rehearsal,
              onChanged: (v) => setState(() => rehearsal = v),
            ),
          ),
        ],
        right: [
          _NotesCard(
            title: "What's new",
            locales: locales,
            controllers: notes,
            limit: 500,
            onChanged: _notesChanged,
            footer: 'Play allows 500 characters per language.',
          ),
        ],
        bar: _LaunchBar(
          app: widget.app,
          version: version.text,
          number: buildNumber,
          destination: rehearsal
              ? 'Rehearsal · build${onGitHub ? ' on GitHub' : ' and check signing'}'
              : '${onGitHub ? 'GitHub build' : 'Upload'} → $trackName · $_statusText',
          rehearsal: rehearsal,
          error: launchError,
          color: Palette.playGreen,
          onLaunch: _canLaunch(model, st) ? _confirmAndLaunch : null,
        ),
      ),
    );
  }

  Widget _buildOnHeader() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const CardTitle('Build on', Icons.handyman_outlined),
      const SizedBox(height: 12),
      Segmented<bool>(
        items: const [(false, 'This computer'), (true, 'GitHub Actions')],
        value: onGitHub,
        expand: true,
        onChanged: (v) {
          setState(() {
            onGitHub = v;
            if (!v) cloudReady = false;
          });
          ModelScope.read(context).updateRecipe(widget.app.id, (r) => r.androidBuildOn = v ? 'github' : null);
        },
      ),
    ],
  );
}
