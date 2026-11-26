import 'package:material_ui/material_ui.dart';

import '../core/shell.dart';
import '../core/workspace.dart';
import 'app_model.dart';
import 'console.dart';
import 'overview.dart';
import 'theme.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final history = model.workspace.runs;
    return PageFrame(
      glowHeight: 360,
      padding: const EdgeInsets.all(32),
      children: [
        const Text('Activity', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        if (model.runs.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionHeader('This session', icon: Icons.bolt_rounded),
          const SizedBox(height: 12),
          for (final run in model.runs.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => model.go(AppRoute.ship(run.plan.app.id)),
                  child: Surface(
                    radius: 14,
                    padding: const EdgeInsets.all(12),
                    child: MiniRun(run: run),
                  ),
                ),
              ),
            ),
        ],
        const SizedBox(height: 24),
        const SectionHeader('History', icon: Icons.history_rounded),
        const SizedBox(height: 12),
        if (history.isEmpty)
          Surface(
            child: Text('Releases you run from here are listed with their logs.', style: TextStyle(color: t.text2)),
          )
        else
          Surface(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                for (final (i, r) in history.indexed) ...[HistoryRow(record: r), if (i < history.length - 1) Divider(height: 1, color: t.hairline)],
              ],
            ),
          ),
      ],
    );
  }
}

class HistoryRow extends StatelessWidget {
  const HistoryRow({super.key, required this.record});
  final RunRecord record;

  @override
  Widget build(BuildContext context) {
    final model = ModelScope.of(context);
    final t = context.tokens;
    final (label, icon, color) = switch (record.outcome) {
      'succeeded' => ('Shipped', Icons.check_circle_rounded, Palette.mint),
      'rehearsed' => ('Rehearsed', Icons.theater_comedy_rounded, Palette.violet),
      'failed' => ('Stopped at ${record.failedStep ?? '?'}', Icons.report_rounded, Palette.ember),
      _ => ('Cancelled', Icons.stop_circle_outlined, t.text2),
    };
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Sensitive(
            radius: 8,
            child: AppIcon(url: model.iconUrl(record.appId, 64), name: record.appName, size: 30),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Sensitive(
                        child: Text(
                          record.appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                    Text(
                      ' ${record.version} (${record.build})',
                      style: const TextStyle(fontWeight: FontWeight.w500, fontFeatures: tabular),
                    ),
                  ],
                ),
                Text(
                  shortDateTime(record.started) + (record.finished == null ? '' : ' · ${clock(record.finished!.difference(record.started))}'),
                  style: TextStyle(fontSize: 12, color: t.text2),
                ),
              ],
            ),
          ),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 13.5)),
          if (record.logPath != null) ...[
            const SizedBox(width: 8),
            IconBtn(Icons.description_outlined, tooltip: 'Open the log', onPressed: () => Shell.open(record.logPath!)),
          ],
        ],
      ),
    );
  }
}
