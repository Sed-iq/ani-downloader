/// Windows 2000 style widgets: 3D-face gray, two-tone bevels, a navy title bar and
/// a chunked progress bar, sized up for touch.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class Win {
  static const face = Color(0xFFD4D0C8);
  static const light = Color(0xFFFFFFFF);
  static const midlight = Color(0xFFDFDFDF);
  static const shadow = Color(0xFF808080);
  static const dark = Color(0xFF404040);
  static const text = Color(0xFF000000);
  static const disabled = Color(0xFF808080);
  static const highlight = Color(0xFF0A246A);
  static const titleEnd = Color(0xFFA6CAF0);
  static const base = Color(0xFFFFFFFF);
}

enum Edge { raised, sunken, pressed, field, etched }

/// Two 1px rings of light and shadow, the Win2k 3D edge.
class Bevel extends StatelessWidget {
  const Bevel({super.key, this.edge = Edge.raised, this.color = Win.face, this.padding, required this.child});
  final Edge edge;
  final Color color;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BevelPainter(edge),
    child: Container(margin: const EdgeInsets.all(2), color: color, padding: padding, child: child),
  );
}

class _BevelPainter extends CustomPainter {
  _BevelPainter(this.edge);
  final Edge edge;

  @override
  void paint(Canvas canvas, Size size) {
    // (outer top-left, outer bottom-right, inner top-left, inner bottom-right)
    final (otl, obr, itl, ibr) = switch (edge) {
      Edge.raised => (Win.light, Win.dark, Win.midlight, Win.shadow),
      Edge.sunken || Edge.field => (Win.shadow, Win.light, Win.dark, Win.midlight),
      Edge.pressed => (Win.dark, Win.dark, Win.shadow, Win.shadow),
      Edge.etched => (Win.shadow, Win.light, Win.light, Win.shadow),
    };
    void ring(double inset, Color tl, Color br) {
      final r = Rect.fromLTWH(inset, inset, size.width - 2 * inset, size.height - 2 * inset);
      final p = Paint()..strokeWidth = 1;
      canvas.drawRect(Rect.fromLTWH(r.left, r.top, r.width - 1, 1), p..color = tl);
      canvas.drawRect(Rect.fromLTWH(r.left, r.top, 1, r.height - 1), p..color = tl);
      canvas.drawRect(Rect.fromLTWH(r.left, r.bottom - 1, r.width, 1), p..color = br);
      canvas.drawRect(Rect.fromLTWH(r.right - 1, r.top, 1, r.height), p..color = br);
    }

    ring(0, otl, obr);
    ring(1, itl, ibr);
  }

  @override
  bool shouldRepaint(_BevelPainter old) => old.edge != edge;
}

/// A push button: raised, sunken while held, gray text when disabled.
class ClassicButton extends StatefulWidget {
  const ClassicButton({super.key, required this.label, this.onPressed, this.minWidth = 88, this.bold = false});
  final String label;
  final VoidCallback? onPressed;
  final double minWidth;
  final bool bold; // the dialog's default button

  @override
  State<ClassicButton> createState() => _ClassicButtonState();
}

class _ClassicButtonState extends State<ClassicButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final label = Text(
      widget.label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: enabled ? Win.text : Win.disabled,
        fontWeight: widget.bold ? FontWeight.bold : FontWeight.normal,
        shadows: enabled ? null : const [Shadow(color: Win.light, offset: Offset(1, 1))],
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: enabled
            ? (_) {
                setState(() => _down = false);
                HapticFeedback.selectionClick();
                widget.onPressed!();
              }
            : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: widget.minWidth, minHeight: 44),
          child: Bevel(
            edge: _down ? Edge.pressed : Edge.raised,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              widthFactor: 1,
              child: Transform.translate(offset: _down ? const Offset(1, 1) : Offset.zero, child: label),
            ),
          ),
        ),
      ),
    );
  }
}

/// A navy-gradient caption with an optional back button.
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, required this.title, this.onBack});
  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    decoration: const BoxDecoration(gradient: LinearGradient(colors: [Win.highlight, Win.titleEnd])),
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Row(
      children: [
        if (onBack != null) ...[
          SizedBox(width: 34, height: 30, child: _CaptionButton(onTap: onBack!)),
          const SizedBox(width: 8),
        ] else ...[
          const Icon(Icons.download_for_offline, color: Win.light, size: 20),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Win.light, fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
      ],
    ),
  );
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Back',
    child: GestureDetector(
      onTap: onTap,
      child: const Bevel(
        child: Center(child: Icon(Icons.arrow_back, size: 18, color: Win.text)),
      ),
    ),
  );
}

/// A white, sunken text field.
class ClassicField extends StatelessWidget {
  const ClassicField({super.key, required this.controller, this.hint, this.enabled = true, this.onSubmitted});
  final TextEditingController controller;
  final String? hint;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => Bevel(
    edge: Edge.field,
    color: enabled ? Win.base : Win.face,
    child: SizedBox(
      height: 40,
      child: TextField(
        controller: controller,
        enabled: enabled,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        cursorColor: Win.text,
        style: const TextStyle(color: Win.text, fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Win.disabled),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        ),
      ),
    ),
  );
}

/// A sunken 13px checkbox with a black tick, padded to a touch target.
class ClassicCheck extends StatelessWidget {
  const ClassicCheck({super.key, required this.value, this.enabled = true});
  final bool value;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 22,
    height: 22,
    child: Bevel(
      edge: Edge.sunken,
      color: enabled ? Win.base : Win.face,
      child: value ? Icon(Icons.check, size: 16, color: enabled ? Win.text : Win.disabled) : const SizedBox.expand(),
    ),
  );
}

/// A sunken bar filled with navy blocks, like the Win2k progress control.
class ChunkedProgress extends StatelessWidget {
  const ChunkedProgress({super.key, required this.value, this.height = 18});
  final double value; // 0-1
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Bevel(
      edge: Edge.sunken,
      padding: const EdgeInsets.all(1),
      child: CustomPaint(painter: _ChunkPainter(value.clamp(0, 1)), size: Size.infinite),
    ),
  );
}

class _ChunkPainter extends CustomPainter {
  _ChunkPainter(this.value);
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final chunk = (size.height * 0.6).clamp(5.0, 9.0), gap = 2.0;
    final paint = Paint()..color = Win.highlight;
    final fill = size.width * value;
    for (var x = 0.0; x + 1 < fill; x += chunk + gap) {
      canvas.drawRect(Rect.fromLTWH(x, 0, (chunk).clamp(0, fill - x), size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_ChunkPainter old) => old.value != value;
}

/// A sunken white panel for lists.
class ListPanel extends StatelessWidget {
  const ListPanel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Bevel(
    edge: Edge.sunken,
    color: Win.base,
    child: ClipRect(child: child),
  );
}

/// The status bar: a sunken message cell, and a progress cell while one is given.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.message, this.progress});
  final String message;
  final double? progress;

  @override
  Widget build(BuildContext context) => Container(
    color: Win.face,
    padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
    child: Row(
      children: [
        Expanded(
          child: Bevel(
            edge: Edge.sunken,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Text(message, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ),
        ),
        if (progress != null) ...[
          const SizedBox(width: 3),
          SizedBox(width: 110, child: ChunkedProgress(value: progress!, height: 28)),
        ],
      ],
    ),
  );
}

/// A Win2k message box: caption, icon, text, buttons. Returns the pressed label.
Future<String?> showClassicDialog(
  BuildContext context, {
  required String title,
  required String message,
  IconData icon = Icons.info,
  Color iconColor = Win.highlight,
  List<String> buttons = const ['OK'],
  bool dismissible = true,
}) => showDialog<String>(
  context: context,
  barrierDismissible: dismissible,
  barrierColor: Colors.black26,
  builder: (context) => PopScope(
    canPop: dismissible,
    child: Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      shape: const RoundedRectangleBorder(),
      child: ClassicWindowFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TitleBar(title: title),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 36, color: iconColor),
                  const SizedBox(width: 14),
                  Expanded(child: Text(message, style: const TextStyle(fontSize: 15, height: 1.35))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, label) in buttons.indexed)
                    ClassicButton(label: label, bold: i == 0, onPressed: () => Navigator.of(context).pop(label)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// The raised outer frame of a window or dialog.
class ClassicWindowFrame extends StatelessWidget {
  const ClassicWindowFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Bevel(padding: const EdgeInsets.all(2), child: child);
}

/// A drop-down list in the Win2k combo box style. [labels] parallel [values].
class ClassicCombo<T> extends StatelessWidget {
  const ClassicCombo({
    super.key,
    required this.values,
    required this.labels,
    required this.value,
    required this.onChanged,
    this.width = 104,
  });
  final List<T> values;
  final List<String> labels;
  final T value;
  final ValueChanged<T>? onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null && values.isNotEmpty;
    final index = values.indexOf(value);
    return SizedBox(
      width: width,
      height: 44,
      child: Builder(
        builder: (context) => GestureDetector(
          onTap: enabled ? () => _open(context) : null,
          child: Bevel(
            edge: Edge.field,
            color: enabled ? Win.base : Win.face,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      index >= 0 ? labels[index] : '',
                      maxLines: 1,
                      style: TextStyle(fontSize: 15, color: enabled ? Win.text : Win.disabled),
                    ),
                  ),
                ),
                SizedBox(
                  width: 26,
                  child: Bevel(
                    child: Center(
                      child: Icon(Icons.arrow_drop_down, size: 22, color: enabled ? Win.text : Win.disabled),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showMenu<T>(
      context: context,
      color: Win.base,
      elevation: 2,
      shape: const RoundedRectangleBorder(side: BorderSide(color: Win.text)),
      constraints: BoxConstraints(minWidth: width, maxWidth: width),
      position: RelativeRect.fromLTRB(at.dx, at.dy - values.length * 44, overlay.size.width - at.dx - width, 0),
      items: [
        for (final (i, v) in values.indexed)
          PopupMenuItem<T>(
            value: v,
            height: 44,
            child: Text(labels[i], style: const TextStyle(fontSize: 15, color: Win.text)),
          ),
      ],
    );
    if (picked != null) onChanged!(picked);
  }
}
