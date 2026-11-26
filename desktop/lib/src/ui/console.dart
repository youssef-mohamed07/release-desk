import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart' hide StepState;
import 'package:url_launcher/url_launcher.dart';

import '../core/release_run.dart';
import '../core/shell.dart';
import 'app_model.dart';
import 'sidebar.dart';
import 'theme.dart';

IconData stepIcon(StepId id) => switch (id) {
  StepId.prepare => Icons.checklist_rounded,
  StepId.cloudBuild => Icons.cloud_outlined,
  StepId.processing => Icons.settings_suggest_outlined,
  StepId.notes => Icons.chat_bubble_outline_rounded,
  StepId.groups => Icons.groups_outlined,
  StepId.review => Icons.verified_user_outlined,
  StepId.live => Icons.flight_takeoff_rounded,
  StepId.bundle => Icons.inventory_2_outlined,
  StepId.checkSigning => Icons.draw_outlined,
  StepId.playRelease => Icons.rocket_launch_outlined,
};

Color stepTone(StepState s) => switch (s.status) {
  StepStatus.pending => Colors.white.withValues(alpha: 0.2),
  StepStatus.running => Palette.cyan,
  StepStatus.done => Palette.mint,
  StepStatus.warning => waitingColor,
  StepStatus.skipped => Colors.white.withValues(alpha: 0.3),
  StepStatus.failed => Palette.ember,
};

/// Rebuilds every second while [active] (clocks).
class Ticker1s extends StatefulWidget {
  const Ticker1s({super.key, required this.builder, this.active = true});
  final WidgetBuilder builder;
  final bool active;

  @override
  State<Ticker1s> createState() => _Ticker1sState();
}

class _Ticker1sState extends State<Ticker1s> {
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.active && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// A release in flight: the track of stations on the left, the live log on
/// the right, over a slow mesh that takes the colour of how it is going.
class LaunchConsole extends StatefulWidget {
  const LaunchConsole({super.key, required this.run, required this.onNew});
  final ReleaseRun run;
  final VoidCallback onNew;

  @override
  State<LaunchConsole> createState() => _LaunchConsoleState();
}

class _LaunchConsoleState extends State<LaunchConsole> {
  StepId? focus;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildTheme(Brightness.dark),
      child: ListenableBuilder(
        listenable: widget.run,
        builder: (context, _) {
          final run = widget.run;
          final palette = switch (run.phase) {
            RunPhase.succeeded => MeshPalette.success,
            RunPhase.failed => MeshPalette.failure,
            RunPhase.cancelled => MeshPalette.idle,
            _ => MeshPalette.running,
          };
          return Stack(
            children: [
              Positioned.fill(child: MeshBackdrop(palette: palette)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context, run),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(26, 0, 26, 24),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 330,
                            child: LaunchTrack(run: run, focus: focus, onFocus: (s) => setState(() => focus = focus == s ? null : s)),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: ConsoleView(run: run, focus: focus, onClearFocus: () => setState(() => focus = null)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, ReleaseRun run) {
    final model = ModelScope.of(context);
    final plan = run.plan;
    final chips = <Widget>[
      PhaseBadge(run: run),
      if (plan.rehearsal) const _DarkChip('Rehearsal', Icons.theater_comedy_outlined),
      for (final g in plan.groups) _DarkChip(g.name, g.isInternal ? Icons.apartment_rounded : Icons.public_rounded, sensitive: true),
      if (plan.play != null)
        _DarkChip(
          '${plan.play!.track} · ${plan.play!.status == 'inProgress' ? '${((plan.play!.userFraction ?? 0) * 100).round()}%' : plan.play!.status}',
          Icons.alt_route_rounded,
        ),
      if (plan.startAt != null) const _DarkChip('Resumed', Icons.refresh_rounded),
      if (plan.cloud != null) const _DarkChip('GitHub Actions', Icons.cloud_outlined),
      if (plan.submitForReview && plan.groups.any((g) => !g.isInternal) && !plan.rehearsal) const _DarkChip('Beta review', Icons.verified_user_outlined),
    ];
    final actions = _actions(context, model, run);
    return LayoutBuilder(
      builder: (context, box) {
        // Wide windows keep the buttons on the header line; narrower ones
        // move them to a line of their own.
        final wide = box.maxWidth >= 1250;
        final top = Row(
          children: [
            Sensitive(
              radius: 10,
              child: AppIcon(url: model.iconUrl(plan.app.id), name: plan.app.name, size: 58),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Sensitive(
                          radius: 10,
                          child: Text(
                            plan.app.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '${plan.version} (${plan.build})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.6), fontFeatures: tabular),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 6, children: chips),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Ticker1s(
              active: run.phase == RunPhase.running,
              builder: (_) => Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    clock(run.elapsed),
                    style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: Colors.white, fontFeatures: tabular, height: 1.1),
                  ),
                  Text(run.phase == RunPhase.running ? 'elapsed' : 'total', style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5))),
                ],
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 52,
              height: 52,
              child: ProgressRing(progress: run.progress, phase: run.phase),
            ),
            if (wide) ...[const SizedBox(width: 16), Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: actions)],
          ],
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 18),
          child: wide
              ? top
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    top,
                    const SizedBox(height: 14),
                    Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
                  ],
                ),
        );
      },
    );
  }

  List<Widget> _actions(BuildContext context, AppModel model, ReleaseRun run) {
    final out = <Widget>[];
    void add(Widget w) => out.add(w);

    if (run.cloudRunUrl != null) {
      add(SoftButton(label: 'On GitHub', icon: Icons.open_in_new_rounded, onDark: true, onPressed: () => launchUrl(Uri.parse(run.cloudRunUrl!))));
    }
    if (run.phase == RunPhase.running) {
      add(SoftButton(label: 'Stop', icon: Icons.stop_rounded, onDark: true, destructive: true, onPressed: () => _confirmStop(context, run)));
      return out;
    }
    if (run.phase == RunPhase.succeeded && !run.plan.rehearsal) {
      final link = run.plan.groups.where((g) => g.publicLinkEnabled && g.publicLink != null).firstOrNull?.publicLink;
      if (link != null) add(SoftButton(label: 'Copy TestFlight link', icon: Icons.link_rounded, onDark: true, onPressed: () => copyText(link)));
    }
    add(
      SoftButton(
        label: run.artifact == null ? 'Show log' : 'Show bundle',
        icon: Icons.folder_outlined,
        onDark: true,
        onPressed: () => Shell.reveal(run.artifact ?? run.logFile.path),
      ),
    );
    if (run.phase == RunPhase.failed || run.phase == RunPhase.cancelled) {
      add(
        SoftButton(
          label: model.canResumeFromProcessing(run) ? 'Resume from Apple processing' : 'Try again',
          icon: Icons.refresh_rounded,
          onDark: true,
          onPressed: () async {
            try {
              await model.resume(run);
            } catch (e) {
              model.say('$e');
            }
          },
        ),
      );
    }
    add(PrimaryButton(label: 'New release', icon: Icons.add_rounded, large: false, onPressed: widget.onNew));
    return out;
  }

  Future<void> _confirmStop(BuildContext context, ReleaseRun run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop this release?'),
        content: const Text('The current step is interrupted. Anything already sent to Apple, Google or GitHub stays there.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Stop', style: TextStyle(color: Palette.ember)),
          ),
        ],
      ),
    );
    if (ok == true) run.cancel();
  }
}

class _DarkChip extends StatelessWidget {
  const _DarkChip(this.text, this.icon, {this.sensitive = false});
  final String text;
  final IconData icon;
  final bool sensitive;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.7)),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white.withValues(alpha: 0.7)),
          const SizedBox(width: 5),
          Flexible(child: sensitive ? Sensitive(radius: 5, child: label) : label),
        ],
      ),
    );
  }
}

class PhaseBadge extends StatelessWidget {
  const PhaseBadge({super.key, required this.run});
  final ReleaseRun run;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (run.phase) {
      RunPhase.ready => ('Ready', Colors.white54),
      RunPhase.running => (run.current == null ? 'Starting…' : '${run.current!.title}…', Palette.cyan),
      RunPhase.succeeded => (run.plan.rehearsal ? 'Rehearsal passed' : 'Shipped', Palette.mint),
      RunPhase.failed => ('Stopped at ${run.failedStep?.id.title ?? 'a step'}', Palette.ember),
      RunPhase.cancelled => ('Cancelled', Colors.white54),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color, blurRadius: 5)],
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.progress, required this.phase});
  final double progress;
  final RunPhase phase;

  @override
  Widget build(BuildContext context) {
    final color = phase == RunPhase.failed ? Palette.ember : (phase == RunPhase.succeeded ? Palette.mint : Palette.cyan);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: progress),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => CustomPaint(
        painter: _RingPainter(v, color),
        child: Center(
          child: Text(
            '${(progress * 100).round()}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white, fontFeatures: tabular),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.color);
  final double v;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 3;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );
    if (v <= 0) return;
    final rect = Rect.fromCircle(center: c, radius: r);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [color.withValues(alpha: 0.4), color],
        startAngle: 0,
        endAngle: math.pi * 2 * v.clamp(0.01, 1),
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * v, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.v != v || old.color != color;
}

// MARK: - Track

class LaunchTrack extends StatelessWidget {
  const LaunchTrack({super.key, required this.run, required this.focus, required this.onFocus});
  final ReleaseRun run;
  final StepId? focus;
  final ValueChanged<StepId> onFocus;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        gradient: LinearGradient(
          colors: [Colors.white.withValues(alpha: 0.07), Colors.white.withValues(alpha: 0.02)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final (i, s) in run.steps.indexed)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onFocus(s.id),
                child: Station(step: s, last: i == run.steps.length - 1, next: i + 1 < run.steps.length ? run.steps[i + 1] : null, focused: focus == s.id),
              ),
            ),
        ],
      ),
    );
  }
}

class Station extends StatelessWidget {
  const Station({super.key, required this.step, required this.last, this.next, required this.focused});
  final RunStep step;
  final bool last;
  final RunStep? next;
  final bool focused;

  String? get subtitle => switch (step.state.status) {
    StepStatus.running || StepStatus.done => step.detail,
    StepStatus.failed || StepStatus.warning || StepStatus.skipped => step.state.message,
    StepStatus.pending => null,
  };

  Color get subtitleColor => switch (step.state.status) {
    StepStatus.failed => Palette.ember,
    StepStatus.warning => waitingColor,
    _ => Colors.white.withValues(alpha: 0.55),
  };

  @override
  Widget build(BuildContext context) {
    final pending = step.state.status == StepStatus.pending;
    final nextTone = next == null ? null : stepTone(next!.state);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: focused ? Colors.white.withValues(alpha: 0.07) : Colors.transparent, borderRadius: BorderRadius.circular(12)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              children: [
                StepNode(step: step),
                if (!last)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: SizedBox(
                        width: 2.5,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(2)),
                              ),
                            ),
                            Positioned.fill(
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween(end: step.state.isFinished ? 1 : 0),
                                  duration: const Duration(milliseconds: 450),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, v, _) => FractionallySizedBox(
                                    heightFactor: v,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(2),
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            stepTone(step.state),
                                            (nextTone ?? stepTone(step.state)).withValues(alpha: next?.state.status == StepStatus.pending ? 0.25 : 1),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 7, bottom: last ? 4 : 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            step.id.title,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: pending ? Colors.white.withValues(alpha: 0.45) : Colors.white),
                          ),
                        ),
                        Ticker1s(
                          active: step.state.status == StepStatus.running,
                          builder: (_) => Text(
                            step.started == null ? '' : clock((step.finished ?? DateTime.now()).difference(step.started!)),
                            style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5), fontFeatures: tabular),
                          ),
                        ),
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Sensitive(
                        radius: 4,
                        child: Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: subtitleColor),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A station's light: outlined while pending, a spinning ring while running,
/// filled when done.
class StepNode extends StatefulWidget {
  const StepNode({super.key, required this.step});
  final RunStep step;

  @override
  State<StepNode> createState() => _StepNodeState();
}

class _StepNodeState extends State<StepNode> with SingleTickerProviderStateMixin {
  late final spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StepNode old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final running = widget.step.state.status == StepStatus.running;
    if (running && !spin.isAnimating) spin.repeat();
    if (!running && spin.isAnimating) spin.stop();
  }

  @override
  void dispose() {
    spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.step;
    final tone = stepTone(s.state);
    final icon = stepIcon(s.id);
    final Widget inner = switch (s.state.status) {
      StepStatus.pending => Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.5),
            ),
          ),
          Icon(icon, size: 15, color: Colors.white.withValues(alpha: 0.35)),
        ],
      ),
      StepStatus.running => Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(shape: BoxShape.circle, color: Palette.cyan.withValues(alpha: 0.16)),
          ),
          RotationTransition(
            turns: spin,
            child: CustomPaint(size: const Size(34, 34), painter: _SpinPainter()),
          ),
          Pulse(child: Icon(icon, size: 15, color: Palette.cyan)),
        ],
      ),
      StepStatus.done => Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: Palette.mint),
        child: Icon(Icons.check_rounded, size: 18, color: Palette.ink, weight: 800),
      ),
      StepStatus.warning => Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: waitingColor),
        child: Icon(Icons.priority_high_rounded, size: 17, color: Palette.ink),
      ),
      StepStatus.skipped => Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(size: const Size(34, 34), painter: _DashedCircle()),
          Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: Colors.white.withValues(alpha: 0.4)),
        ],
      ),
      StepStatus.failed => Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: Palette.ember),
        child: const Icon(Icons.close_rounded, size: 17, color: Colors.white),
      ),
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: s.state.status == StepStatus.pending
            ? null
            : [BoxShadow(color: tone.withValues(alpha: 0.6), blurRadius: s.state.status == StepStatus.running ? 16 : 9)],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, a) => ScaleTransition(
          scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
          child: FadeTransition(opacity: a, child: child),
        ),
        child: KeyedSubtree(key: ValueKey(s.state.status), child: inner),
      ),
    );
  }
}

class _SpinPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..shader = SweepGradient(colors: [Palette.cyan.withValues(alpha: 0), Palette.cyan, Palette.violet]).createShader(rect);
    canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.25, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DashedCircle extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.25);
    final r = size.width / 2 - 0.75;
    const dashes = 14;
    for (var i = 0; i < dashes; i++) {
      final a = i * 2 * math.pi / dashes;
      canvas.drawArc(Rect.fromCircle(center: size.center(Offset.zero), radius: r), a, math.pi / dashes, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// MARK: - Console

class ConsoleView extends StatefulWidget {
  const ConsoleView({super.key, required this.run, required this.focus, required this.onClearFocus});
  final ReleaseRun run;
  final StepId? focus;
  final VoidCallback onClearFocus;

  @override
  State<ConsoleView> createState() => _ConsoleViewState();
}

class _ConsoleViewState extends State<ConsoleView> {
  final scroll = ScrollController();
  bool follow = true;
  bool showOutput = true;
  int _lastCount = -1;

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void _followIfNeeded(int count) {
    if (!follow || count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.run.lines.where((l) => (widget.focus == null || l.step == widget.focus) && (showOutput || l.kind != LogKind.output)).toList();
    _followIfNeeded(visible.length);
    return Container(
      decoration: BoxDecoration(
        color: Palette.ink.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 10, 9),
            child: Row(
              children: [
                Icon(Icons.terminal_rounded, size: 17, color: Colors.white.withValues(alpha: 0.6)),
                const SizedBox(width: 10),
                Text(
                  widget.focus == null ? 'Live log' : '${widget.focus!.title} log',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                if (widget.focus != null) ...[
                  const SizedBox(width: 10),
                  SoftButton(label: 'All steps', small: true, onDark: true, onPressed: widget.onClearFocus),
                ],
                const Spacer(),
                _MiniSwitch(label: 'Tool output', value: showOutput, onChanged: (v) => setState(() => showOutput = v)),
                const SizedBox(width: 12),
                _MiniSwitch(label: 'Follow', value: follow, onChanged: (v) => setState(() => follow = v)),
                const SizedBox(width: 6),
                IconBtn(
                  Icons.open_in_new_rounded,
                  size: 15,
                  color: Colors.white70,
                  tooltip: 'Open the full log',
                  onPressed: () => Shell.open(widget.run.logFile.path),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.all(14),
                itemCount: visible.length,
                itemBuilder: (context, i) => LogRow(line: visible[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.8))),
      SizedBox(
        height: 22,
        child: FittedBox(
          child: Switch(value: value, onChanged: onChanged),
        ),
      ),
    ],
  );
}

class LogRow extends StatelessWidget {
  const LogRow({super.key, required this.line});
  final LogLine line;

  static const _hues = {
    StepId.prepare: 216.0,
    StepId.cloudBuild: 259.0,
    StepId.processing: 180.0,
    StepId.notes: 43.0,
    StepId.groups: 137.0,
    StepId.review: 108.0,
    StepId.live: 151.0,
    StepId.bundle: 288.0,
    StepId.checkSigning: 310.0,
    StepId.playRelease: 198.0,
  };

  @override
  Widget build(BuildContext context) {
    final color = switch (line.kind) {
      LogKind.output => Colors.white.withValues(alpha: 0.62),
      LogKind.info => Colors.white.withValues(alpha: 0.92),
      LogKind.success => Palette.mint,
      LogKind.warning => waitingColor,
      LogKind.error => Palette.ember,
    };
    final stepColor = HSVColor.fromAHSV(0.75, _hues[line.step] ?? 216, 0.55, 1).toColor();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.75),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hhmmss(line.time), style: mono(11.5, color: Colors.white.withValues(alpha: 0.28))),
          const SizedBox(width: 10),
          SizedBox(
            width: 82,
            child: Text(
              line.step.name,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: mono(11.5, color: stepColor),
            ),
          ),
          Expanded(
            child: Sensitive(
              radius: 4,
              child: Text(
                line.text,
                style: mono(11.5, color: color, weight: line.kind == LogKind.output ? FontWeight.w400 : FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A run in a line: icon, version, step and a thin progress bar.
class MiniRun extends StatelessWidget {
  const MiniRun({super.key, required this.run});
  final ReleaseRun run;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final tint = switch (run.phase) {
      RunPhase.succeeded => Palette.mint,
      RunPhase.failed => Palette.ember,
      _ => Palette.cyan,
    };
    return ListenableBuilder(
      listenable: run,
      builder: (context, _) => Row(
        children: [
          Sensitive(
            radius: 8,
            child: AppIcon(url: model.iconUrl(run.plan.app.id, 64), name: run.plan.app.name, size: 32),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Sensitive(
                        child: Text(
                          run.plan.app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                    Text(
                      ' ${run.plan.version} (${run.plan.build})',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, fontFeatures: tabular),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Ticker1s(
                  active: run.phase == RunPhase.running,
                  builder: (_) => Text(
                    runStatusLine(run),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: t.text2),
                  ),
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: run.progress, minHeight: 3, color: tint, backgroundColor: t.hairline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// MARK: - Background

enum MeshPalette { idle, running, success, failure }

Color _c(double r, double g, double b) => Color.from(alpha: 1, red: r, green: g, blue: b);

/// A slowly breathing gradient. Indigo while working, green when it lands,
/// red when it stops.
class MeshBackdrop extends StatefulWidget {
  const MeshBackdrop({super.key, required this.palette});
  final MeshPalette palette;

  static List<Color> colors(MeshPalette p) => switch (p) {
    MeshPalette.idle => [_c(0.13, 0.12, 0.32), _c(0.10, 0.16, 0.36), _c(0.30, 0.22, 0.62), _c(0.07, 0.20, 0.33), _c(0.08, 0.10, 0.24)],
    MeshPalette.running => [_c(0.10, 0.14, 0.40), _c(0.06, 0.22, 0.40), _c(0.22, 0.24, 0.70), _c(0.05, 0.32, 0.48), _c(0.12, 0.10, 0.34)],
    MeshPalette.success => [_c(0.04, 0.24, 0.22), _c(0.05, 0.30, 0.28), _c(0.10, 0.55, 0.42), _c(0.06, 0.30, 0.40), _c(0.04, 0.20, 0.18)],
    MeshPalette.failure => [_c(0.30, 0.07, 0.10), _c(0.24, 0.06, 0.16), _c(0.55, 0.14, 0.18), _c(0.25, 0.08, 0.24), _c(0.18, 0.05, 0.10)],
  };

  @override
  State<MeshBackdrop> createState() => _MeshBackdropState();
}

class _MeshBackdropState extends State<MeshBackdrop> with TickerProviderStateMixin {
  late final time = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
  final watch = Stopwatch()..start();
  late final blend = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200), value: 1);
  late List<Color> from = MeshBackdrop.colors(widget.palette);
  late List<Color> to = from;

  @override
  void didUpdateWidget(MeshBackdrop old) {
    super.didUpdateWidget(old);
    if (old.palette != widget.palette) {
      from = _current();
      to = MeshBackdrop.colors(widget.palette);
      blend.forward(from: 0);
    }
  }

  List<Color> _current() {
    final v = Curves.easeInOut.transform(blend.value);
    return [for (var i = 0; i < to.length; i++) Color.lerp(from[i], to[i], v)!];
  }

  @override
  void dispose() {
    time.dispose();
    blend.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([time, blend]),
        builder: (context, _) => CustomPaint(painter: _MeshPainter(watch.elapsedMilliseconds / 1000.0, _current()), size: Size.infinite),
      ),
    ),
  );
}

class _MeshPainter extends CustomPainter {
  _MeshPainter(this.t, this.colors);
  final double t;
  final List<Color> colors;

  static final _ink = _c(0.03, 0.04, 0.09);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = _ink);
    double w(double speed, double phase, [double amp = 0.12]) => math.sin(t * speed + phase) * amp;
    // Where the five colours of the 3×3 mesh sit: top, left, centre, right, bottom.
    final points = [
      Offset(0.5 + w(0.21, 0), 0.0 + w(0.13, 2, 0.05)),
      Offset(0.0 + w(0.11, 1, 0.05), 0.5 + w(0.17, 1)),
      Offset(0.5 + w(0.23, 2, 0.18), 0.5 + w(0.19, 3, 0.18)),
      Offset(1.0 + w(0.12, 4, 0.05), 0.5 + w(0.15, 4)),
      Offset(0.5 + w(0.2, 5), 1.0 + w(0.16, 6, 0.05)),
    ];
    final radii = [0.62, 0.62, 0.72, 0.62, 0.62];
    final longest = math.max(size.width, size.height);
    for (var i = 0; i < points.length; i++) {
      final c = Offset(points[i].dx * size.width, points[i].dy * size.height);
      final r = radii[i] * longest;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [colors[i], colors[i].withValues(alpha: 0)],
            stops: const [0, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: 0.15));
  }

  @override
  bool shouldRepaint(_MeshPainter old) => old.t != t || old.colors != colors;
}
