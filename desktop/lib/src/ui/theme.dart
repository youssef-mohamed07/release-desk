import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/asc.dart';
import '../core/workspace.dart';

Color _rgb(double r, double g, double b, [double a = 1]) => Color.from(alpha: a, red: r, green: g, blue: b);

/// The colours of the macOS app.
abstract final class Palette {
  static final ink = _rgb(0.05, 0.06, 0.11);
  static final indigo = _rgb(0.29, 0.31, 0.95);
  static final violet = _rgb(0.55, 0.33, 0.98);
  static final cyan = _rgb(0.20, 0.78, 0.98);
  static final mint = _rgb(0.20, 0.84, 0.62);
  static final ember = _rgb(1.0, 0.38, 0.36);
  static final playGreen = _rgb(0.0, 0.62, 0.45);
  static final googleBlue = _rgb(0.26, 0.52, 0.96);
  static final play = LinearGradient(colors: [_rgb(0.0, 0.82, 0.53), _rgb(0.0, 0.62, 0.95)], begin: Alignment.topLeft, end: Alignment.bottomRight);
  static final brand = LinearGradient(colors: [indigo, violet, cyan], begin: Alignment.topLeft, end: Alignment.bottomRight);
}

extension ToneColor on StateTone {
  Color color(BuildContext context) => switch (this) {
    StateTone.good => _rgb(0.20, 0.80, 0.55),
    StateTone.active => _rgb(0.30, 0.62, 1.0),
    StateTone.waiting => _rgb(1.0, 0.66, 0.22),
    StateTone.bad => _rgb(1.0, 0.36, 0.40),
    StateTone.muted => context.tokens.text2,
  };
}

final waitingColor = _rgb(1.0, 0.66, 0.22);

/// Surface and text colours for light and dark.
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.dark,
    required this.bg,
    required this.sidebar,
    required this.cardFill,
    required this.cardEdgeTop,
    required this.cardEdgeBottom,
    required this.cardShadow,
    required this.text,
    required this.text2,
    required this.text3,
    required this.hairline,
    required this.fieldFill,
    required this.chipFill,
  });

  final bool dark;
  final Color bg, sidebar, cardFill, cardEdgeTop, cardEdgeBottom, cardShadow, text, text2, text3, hairline, fieldFill, chipFill;

  static final darkTokens = Tokens(
    dark: true,
    bg: _rgb(0.055, 0.063, 0.098),
    sidebar: _rgb(0.075, 0.082, 0.12),
    cardFill: const Color(0x0BFFFFFF),
    cardEdgeTop: const Color(0x29FFFFFF),
    cardEdgeBottom: const Color(0x08FFFFFF),
    cardShadow: const Color(0x00000000),
    text: const Color(0xEDFFFFFF),
    text2: const Color(0x8CFFFFFF),
    text3: const Color(0x52FFFFFF),
    hairline: const Color(0x14FFFFFF),
    fieldFill: const Color(0x0DFFFFFF),
    chipFill: const Color(0x14FFFFFF),
  );

  static final lightTokens = Tokens(
    dark: false,
    bg: _rgb(0.965, 0.969, 0.984),
    sidebar: _rgb(0.925, 0.933, 0.957),
    cardFill: const Color(0xB8FFFFFF),
    cardEdgeTop: const Color(0xE6FFFFFF),
    cardEdgeBottom: const Color(0x4DFFFFFF),
    cardShadow: const Color(0x0F000000),
    text: _rgb(0.08, 0.09, 0.12),
    text2: const Color(0x85000000),
    text3: const Color(0x4D000000),
    hairline: const Color(0x14000000),
    fieldFill: const Color(0x0A000000),
    chipFill: const Color(0x0F000000),
  );

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(Tokens? other, double t) => t < 0.5 || other == null ? this : other;
}

extension TokensX on BuildContext {
  Tokens get tokens => Theme.of(this).extension<Tokens>() ?? Tokens.lightTokens;
}

final bool isMac = Platform.isMacOS;

/// "⌘" on macOS, "Ctrl+" elsewhere.
String get modKey => isMac ? '⌘' : 'Ctrl+';

String get monoFamily => Platform.isMacOS ? 'Menlo' : (Platform.isWindows ? 'Consolas' : 'DejaVu Sans Mono');
const monoFallback = [
  'SF Mono',
  'Menlo',
  'Cascadia Mono',
  'Consolas',
  'JetBrains Mono',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Noto Sans Mono',
  'Ubuntu Mono',
  'Courier New',
];

TextStyle mono(double size, {Color? color, FontWeight weight = FontWeight.w400}) =>
    TextStyle(fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: size, color: color, fontWeight: weight, height: 1.35);

const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme(Brightness b) {
  final t = b == Brightness.dark ? Tokens.darkTokens : Tokens.lightTokens;
  final scheme = ColorScheme.fromSeed(seedColor: Palette.indigo, brightness: b).copyWith(primary: Palette.indigo, surface: t.bg, onSurface: t.text);
  final base = ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    visualDensity: VisualDensity.compact,
    fontFamilyFallback: debugFontFamilyFallback,
  );
  return base.copyWith(
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    dividerColor: t.hairline,
    extensions: [t],
    splashFactory: NoSplash.splashFactory,
    textTheme: base.textTheme
        .apply(bodyColor: t.text, displayColor: t.text)
        .copyWith(
          bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13.5, color: t.text),
          bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, color: t.text2),
        ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: TextStyle(fontSize: 12, color: t.dark ? Colors.black : Colors.white),
      decoration: BoxDecoration(
        color: t.dark ? Colors.white.withValues(alpha: 0.92) : Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Palette.indigo : t.hairline.withValues(alpha: t.dark ? 0.25 : 0.18),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: Palette.cyan,
      thumbColor: Colors.white,
      inactiveTrackColor: t.hairline,
      overlayShape: SliderComponentShape.noOverlay,
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: Palette.indigo, selectionColor: Palette.indigo.withValues(alpha: 0.3)),
    dialogTheme: DialogThemeData(
      backgroundColor: t.dark ? _rgb(0.09, 0.10, 0.14) : _rgb(0.98, 0.98, 0.99),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: t.dark ? _rgb(0.16, 0.17, 0.23) : _rgb(0.12, 0.13, 0.18)),
    popupMenuTheme: PopupMenuThemeData(
      color: t.dark ? _rgb(0.12, 0.13, 0.18) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.all(t.text3.withValues(alpha: 0.4)),
    ),
  );
}

// MARK: - Privacy mode

/// Privacy mode blurs whatever identifies a person, a team or an app: names,
/// icons, emails, ids, paths, notes and logs. For screen sharing and videos.
class PrivacyScope extends InheritedWidget {
  const PrivacyScope({super.key, required this.on, required super.child});
  final bool on;

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PrivacyScope>()?.on ?? false;

  @override
  bool updateShouldNotify(PrivacyScope old) => old.on != on;
}

/// Blurred while privacy mode is on.
class Sensitive extends StatelessWidget {
  const Sensitive({super.key, required this.child, this.radius = 6});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final on = PrivacyScope.of(context) && radius > 0;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: on ? radius : 0),
      duration: const Duration(milliseconds: 250),
      child: child,
      builder: (context, v, child) => ImageFiltered(
        enabled: v > 0.05,
        imageFilter: ui.ImageFilter.blur(sigmaX: math.max(v * 0.75, 0.01), sigmaY: math.max(v * 0.75, 0.01), tileMode: TileMode.decal),
        child: child!,
      ),
    );
  }
}

// MARK: - Surfaces

/// The surface content cards sit on: a faint fill and a top-lit hairline.
class Surface extends StatelessWidget {
  const Surface({super.key, required this.child, this.radius = 16, this.padding = const EdgeInsets.all(16), this.tint, this.border});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? tint;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final r = BorderRadius.circular(radius);
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        color: tint ?? t.cardFill,
        boxShadow: t.dark ? null : [BoxShadow(color: t.cardShadow, blurRadius: 18, offset: const Offset(0, 6))],
      ),
      foregroundDecoration: _GradientBorder(radius: radius, top: border ?? t.cardEdgeTop, bottom: border ?? t.cardEdgeBottom),
      padding: padding,
      child: child,
    );
  }
}

class _GradientBorder extends Decoration {
  const _GradientBorder({required this.radius, required this.top, required this.bottom});
  final double radius;
  final Color top, bottom;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _GradientBorderPainter(this);
}

class _GradientBorderPainter extends BoxPainter {
  _GradientBorderPainter(this.d);
  final _GradientBorder d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rect = (offset & size).deflate(0.4);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [d.top, d.bottom]).createShader(rect);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(d.radius)), paint);
  }
}

/// A frosted panel (the launch bar, the command palette).
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 22, this.padding = EdgeInsets.zero, this.tint, this.blur = 24});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? tint;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final r = BorderRadius.circular(radius);
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.dark ? 0.35 : 0.12),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: r,
              color: tint ?? (t.dark ? const Color(0xB3181A24) : const Color(0xC7FFFFFF)),
              border: Border.all(color: t.dark ? const Color(0x1FFFFFFF) : const Color(0x14000000), width: 0.8),
            ),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A small capsule with an icon and a word or two.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.icon, this.isMono = false, this.sensitive = false, this.color});
  final String text;
  final IconData? icon;
  final bool isMono;
  final bool sensitive;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = color ?? t.text2;
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: isMono ? mono(11.5, color: c) : TextStyle(fontSize: 12, color: c),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: t.chipFill, borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 5)],
          Flexible(child: sensitive ? Sensitive(radius: 5, child: label) : label),
        ],
      ),
    );
  }
}

/// A capsule with a dot that says where a build or version stands.
class StatePill extends StatelessWidget {
  const StatePill(this.raw, {super.key, this.compact = false});
  final String? raw;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final d = describeState(raw);
    return ToneText(d.label, d.tone, compact: compact);
  }
}

class ToneText extends StatelessWidget {
  const ToneText(this.text, this.tone, {super.key, this.compact = false});
  final String text;
  final StateTone tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = tone.color(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 3.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              boxShadow: tone == StateTone.active ? [BoxShadow(color: c.withValues(alpha: 0.8), blurRadius: 4)] : null,
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 10.5 : 12,
                fontWeight: FontWeight.w500,
                color: tone == StateTone.muted ? context.tokens.text2 : context.tokens.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.subtitle, this.icon, this.trailing});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 18, color: t.text2), const SizedBox(width: 8)],
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        if (subtitle != null) ...[const SizedBox(width: 8), Text(subtitle!, style: TextStyle(fontSize: 13.5, color: t.text2))],
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// A card title with an icon, like SwiftUI's Label in a headline font.
class CardTitle extends StatelessWidget {
  const CardTitle(this.title, this.icon, {super.key, this.trailing});
  final String title;
  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 17, color: context.tokens.text),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 8), trailing!],
    ],
  );
}

// MARK: - Buttons

/// The big gradient button (Launch, Ship an update).
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({super.key, required this.label, this.icon, this.onPressed, this.color, this.large = true});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool large;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final c = widget.color ?? Palette.indigo;
    final t = context.tokens;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: hover && enabled ? 1.02 : 1,
          duration: const Duration(milliseconds: 160),
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.45,
            duration: const Duration(milliseconds: 160),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: widget.large ? 26 : 14, vertical: widget.large ? 13 : 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                gradient: enabled
                    ? LinearGradient(
                        colors: [Color.lerp(c, Colors.white, 0.12)!, c, Color.lerp(c, Colors.black, 0.12)!],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: enabled ? null : t.chipFill,
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: c.withValues(alpha: hover ? 0.55 : 0.35),
                          blurRadius: hover ? 22 : 14,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
                border: Border.all(color: Colors.white.withValues(alpha: enabled ? 0.22 : 0.0), width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: widget.large ? 18 : 15, color: enabled ? Colors.white : t.text2),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(fontSize: widget.large ? 15 : 13, fontWeight: FontWeight.w600, color: enabled ? Colors.white : t.text2),
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

/// A quiet capsule button (the "glass" buttons of the macOS app).
class SoftButton extends StatefulWidget {
  const SoftButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.small = false,
    this.destructive = false,
    this.onDark = false,
    this.tooltip,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool small;
  final bool destructive;
  final bool onDark;
  final String? tooltip;

  @override
  State<SoftButton> createState() => _SoftButtonState();
}

class _SoftButtonState extends State<SoftButton> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final enabled = widget.onPressed != null;
    final dark = widget.onDark || t.dark;
    final fg = widget.destructive ? Palette.ember : (widget.onDark ? Colors.white : t.text);
    final fill = dark ? Colors.white.withValues(alpha: hover ? 0.14 : 0.08) : Colors.black.withValues(alpha: hover ? 0.08 : 0.045);
    Widget b = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.4,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(horizontal: widget.small ? 10 : 14, vertical: widget.small ? 5 : 8),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.06), width: 0.8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[Icon(widget.icon, size: widget.small ? 13 : 15, color: fg), if (widget.label.isNotEmpty) const SizedBox(width: 6)],
                if (widget.label.isNotEmpty)
                  Text(
                    widget.label,
                    style: TextStyle(fontSize: widget.small ? 12 : 13, fontWeight: FontWeight.w500, color: fg),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

/// A plain icon button that brightens on hover.
class IconBtn extends StatefulWidget {
  const IconBtn(this.icon, {super.key, this.onPressed, this.tooltip, this.color, this.size = 17});
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final double size;

  @override
  State<IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<IconBtn> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget b = MouseRegion(
      cursor: widget.onPressed != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: hover && widget.onPressed != null ? t.chipFill : Colors.transparent, borderRadius: BorderRadius.circular(8)),
          child: Icon(widget.icon, size: widget.size, color: widget.onPressed == null ? t.text3 : (widget.color ?? t.text2)),
        ),
      ),
    );
    if (widget.tooltip != null) b = Tooltip(message: widget.tooltip!, child: b);
    return b;
  }
}

/// A text link that opens a URL.
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, required this.onTap, this.icon, this.size = 13});
  final String text;
  final VoidCallback onTap;
  final IconData? icon;
  final double size;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.tokens.dark ? _rgb(0.45, 0.62, 1.0) : _rgb(0.16, 0.38, 0.92);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[Icon(widget.icon, size: widget.size + 1, color: c), const SizedBox(width: 5)],
            Text(
              widget.text,
              style: TextStyle(fontSize: widget.size, color: c, decoration: hover ? TextDecoration.underline : null, decorationColor: c),
            ),
          ],
        ),
      ),
    );
  }
}

/// A switch with a title and a caption, as the macOS app's toggles.
class ToggleRow extends StatelessWidget {
  const ToggleRow({super.key, required this.title, this.caption, required this.value, required this.onChanged});
  final String title;
  final String? caption;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Opacity(
      opacity: onChanged == null ? 0.5 : 1,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5)),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(caption!, style: TextStyle(fontSize: 12, color: t.text2)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Transform.scale(
            scale: 0.8,
            child: Switch(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

/// Segmented control in the macOS style.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.items, required this.value, required this.onChanged, this.expand = false});
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final children = [for (final (v, label) in items) _segment(context, label, v == value, () => onChanged(v))];
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: t.dark ? Colors.white.withValues(alpha: 0.07) : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [for (final c in children) expand ? Expanded(child: c) : c],
      ),
    );
  }

  Widget _segment(BuildContext context, String label, bool on, VoidCallback tap) {
    final t = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: tap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? (t.dark ? Colors.white.withValues(alpha: 0.16) : Colors.white) : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: on && !t.dark ? [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 3, offset: const Offset(0, 1))] : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? t.text : t.text2),
          ),
        ),
      ),
    );
  }
}

/// A rounded text field on a faint fill.
class Field extends StatelessWidget {
  const Field({
    super.key,
    required this.controller,
    this.hint,
    this.isMono = false,
    this.onSubmitted,
    this.minLines = 1,
    this.maxLines = 1,
    this.textDirection,
    this.onChanged,
    this.autofocus = false,
    this.focusNode,
    this.obscure = false,
    this.textAlign = TextAlign.start,
  });
  final TextEditingController controller;
  final String? hint;
  final bool isMono;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int minLines;
  final int? maxLines;
  final TextDirection? textDirection;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool obscure;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = isMono ? mono(12.5, color: t.text) : TextStyle(fontSize: 13.5, color: t.text, height: 1.4);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      obscureText: obscure,
      minLines: minLines,
      maxLines: obscure ? 1 : maxLines,
      textAlign: textAlign,
      textDirection: textDirection,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: style,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: style.copyWith(color: t.text3),
        filled: true,
        fillColor: t.fieldFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Palette.indigo.withValues(alpha: 0.7), width: 1.2),
        ),
      ),
    );
  }
}

// MARK: - Marks and icons

/// The Release Desk mark: a paper plane on a gradient tile.
class BrandGlyph extends StatelessWidget {
  const BrandGlyph({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.28),
      gradient: LinearGradient(
        colors: [Palette.indigo, Palette.violet, Palette.cyan],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        stops: const [0, 0.55, 1],
      ),
      boxShadow: [BoxShadow(color: Palette.violet.withValues(alpha: 0.45), blurRadius: size * 0.35, offset: Offset(0, size * 0.08))],
    ),
    alignment: Alignment.center,
    child: Transform.rotate(
      angle: -0.5,
      child: Icon(Icons.send_rounded, size: size * 0.52, color: Colors.white),
    ),
  );
}

/// Google Play's mark: a play triangle in Play's green-to-blue.
class PlayMark extends StatelessWidget {
  const PlayMark({super.key, this.size = 14});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: ShaderMask(
      shaderCallback: (r) => Palette.play.createShader(r),
      child: Icon(Icons.play_arrow_rounded, size: size * 1.15, color: Colors.white),
    ),
  );
}

class ProviderMark extends StatelessWidget {
  const ProviderMark(this.provider, {super.key, this.size = 14, this.color});
  final StoreProvider provider;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      provider == StoreProvider.apple ? Icon(Icons.apple, size: size, color: color ?? context.tokens.text) : PlayMark(size: size);
}

/// Google's "G", drawn from four arcs in its colours.
class GoogleG extends StatelessWidget {
  const GoogleG({super.key, this.size = 18});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
    child: CustomPaint(painter: _GPainter()),
  );
}

class _GPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rect = Rect.fromCircle(center: Offset(s / 2, s / 2), radius: s * 0.3);
    final w = s * 0.16;
    void arc(double from, double sweep, Color c) => canvas.drawArc(
      rect,
      from * 2 * math.pi,
      sweep * 2 * math.pi,
      false,
      Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = w,
    );
    arc(0.0, 0.25, _rgb(0.20, 0.66, 0.33));
    arc(0.25, 0.12, _rgb(0.98, 0.74, 0.02));
    arc(0.37, 0.28, _rgb(0.92, 0.26, 0.21));
    arc(0.65, 0.22, _rgb(0.26, 0.52, 0.96));
    canvas.drawRect(Rect.fromLTWH(s / 2, s / 2 - w / 2, s * 0.3 + w / 2, w), Paint()..color = _rgb(0.26, 0.52, 0.96));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// An app icon from the store, or a tile with its first letter.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.url, this.name = '', this.size = 40});
  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(size * 0.2237);
    final placeholder = _placeholder();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: size > 50 ? 0.25 : 0.12),
            blurRadius: size > 50 ? 22 : 3,
            offset: Offset(0, size > 50 ? 6 : 1),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: r,
        border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: r,
        child: url == null
            ? placeholder
            : Image.network(
                url!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
                frameBuilder: (context, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 250), child: frame == null ? placeholder : child),
              ),
      ),
    );
  }

  Widget _placeholder() {
    const hues = [223.0, 259.0, 187.0, 306.0, 29.0, 162.0];
    final h = hues[name.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff) % hues.length];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [HSVColor.fromAHSV(1, h, 0.55, 0.75).toColor(), HSVColor.fromAHSV(1, (h + 29) % 360, 0.7, 0.5).toColor()],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '' : name.characters.first.toUpperCase(),
        style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.9)),
      ),
    );
  }
}

/// The app's own icon, blurred into a soft light source behind a page.
class AmbientGlow extends StatelessWidget {
  const AmbientGlow({super.key, this.url, this.intensity = 0.55, this.height = 460, this.blur = 70});
  final String? url;
  final double intensity;
  final double height;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth.isFinite ? box.maxWidth : 1000.0;
          final Widget glow;
          if (url != null) {
            glow = Positioned(
              left: -w * 0.05,
              top: -w * 0.16,
              width: w * 0.9,
              height: w * 0.5,
              child: Opacity(
                opacity: (t.dark ? intensity : intensity * 0.7).clamp(0.0, 1.0),
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.decal),
                  child: ColorFiltered(
                    colorFilter: _saturation(1.6),
                    child: Image.network(
                      url!,
                      fit: BoxFit.fill,
                      cacheWidth: 48,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => const SizedBox(),
                    ),
                  ),
                ),
              ),
            );
          } else {
            glow = Positioned(
              left: w * 0.1,
              top: -height * 0.45,
              width: w * 0.8,
              height: height * 0.75,
              child: Opacity(
                opacity: t.dark ? 0.28 : 0.2,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: blur * 1.4, sigmaY: blur * 1.4, tileMode: TileMode.decal),
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: Palette.brand, borderRadius: BorderRadius.circular(9999)),
                  ),
                ),
              ),
            );
          }
          return SizedBox(
            height: height,
            width: w,
            child: Stack(clipBehavior: Clip.hardEdge, children: [glow]),
          );
        },
      ),
    );
  }

  static ColorFilter _saturation(double s) {
    final inv = 1 - s;
    final r = 0.213 * inv, g = 0.715 * inv, b = 0.072 * inv;
    return ColorFilter.matrix([r + s, g, b, 0, 0, r, g + s, b, 0, 0, r, g, b + s, 0, 0, 0, 0, 0, 1, 0]);
  }
}

// MARK: - Words for time

String relativeTime(DateTime? d) {
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.isNegative) return 'now';
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  if (diff.inDays < 7) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  if (diff.inDays < 30) return '${diff.inDays ~/ 7} wk ago';
  if (diff.inDays < 365) return '${diff.inDays ~/ 30} mo ago';
  return '${diff.inDays ~/ 365} yr ago';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String dayMonth(DateTime? d) => d == null ? '' : '${d.toLocal().day} ${_months[d.toLocal().month - 1]}';

String dayMonthYear(DateTime? d) => d == null ? '' : '${dayMonth(d)} ${d.toLocal().year}';

String shortDateTime(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  return '${dayMonth(l)}, ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String clock(Duration t) {
  final s = t.inSeconds < 0 ? 0 : t.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${two(s ~/ 60)}:${two(s % 60)}';
}

String hhmmss(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// Set by demos and screenshot tests to show paths under a stand-in home.
String? debugHomeOverride;

/// Set by screenshot tests, whose fonts lack symbols such as ⌘ and →.
List<String>? debugFontFamilyFallback;

String tildePath(String path) {
  final home = debugHomeOverride ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && home.isNotEmpty && path.startsWith(home)) return '~${path.substring(home.length)}';
  return path;
}

String localeName(String id) =>
    const {
      'ar-SA': 'Arabic (Saudi Arabia)',
      'ar': 'Arabic',
      'en-US': 'English (United States)',
      'en-GB': 'English (United Kingdom)',
      'en': 'English',
      'fr-FR': 'French (France)',
      'de-DE': 'German (Germany)',
      'es-ES': 'Spanish (Spain)',
      'tr-TR': 'Turkish (Türkiye)',
    }[id] ??
    id;

Future<void> copyText(String s) => Clipboard.setData(ClipboardData(text: s));
