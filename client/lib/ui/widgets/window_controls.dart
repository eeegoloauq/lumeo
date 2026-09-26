import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

import '../../platform/window.dart';
import '../theme.dart';

/// The buttons a title bar would have carried, in the bar the client draws.
///
/// Minimise, maximise and close, and nothing else: the name and the icon the
/// desktop needs are on the window itself, not printed above the artwork. They
/// stay monochrome — the one accent belongs to Play and the fill bar — and a
/// hover ground rather than a colour is what tells them apart from the
/// wordmark on the other side of the bar.
class WindowControls extends StatelessWidget {
  const WindowControls({super.key});

  @override
  Widget build(BuildContext context) {
    final window = AppWindow.instance;
    return ListenableBuilder(
      listenable: window,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Button(
            glyph: _Glyph.minimize,
            tooltip: context.l10n.commonMinimise,
            onPressed: window.minimize,
          ),
          _Button(
            glyph: window.maximized ? _Glyph.restore : _Glyph.maximize,
            tooltip: window.maximized
                ? context.l10n.commonRestore
                : context.l10n.commonMaximise,
            onPressed: window.toggleMaximize,
          ),
          _Button(
            glyph: _Glyph.close,
            tooltip: context.l10n.commonClose,
            onPressed: window.close,
          ),
        ],
      ),
    );
  }
}

/// Everywhere a press-and-move should move the window instead of doing
/// nothing: the empty run of the bar, and the wordmark that sits in it.
///
/// The drag begins on [onPanStart] rather than on the press, so a press that
/// never moves is still a click on what is underneath — which is how the
/// wordmark keeps working as the way home. A double click is what it is on
/// every other title bar.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => AppWindow.instance.startDrag(),
      onDoubleTap: AppWindow.instance.toggleMaximize,
      child: child ?? const SizedBox.expand(),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

class _Button extends StatefulWidget {
  const _Button({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
  });

  final _Glyph glyph;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_Button> createState() => _ButtonState();
}

class _ButtonState extends State<_Button> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 34,
            height: 30,
            alignment: Alignment.center,
            // Square, not round: the bar is the only straight-edged surface in
            // the interface and a pill here would read as a control belonging
            // to the page under it.
            decoration: BoxDecoration(
              color: _hovered ? Palette.raised : Colors.transparent,
              borderRadius: BorderRadius.circular(Shape.control),
            ),
            child: CustomPaint(
              size: const Size.square(15),
              painter: _GlyphPainter(
                widget.glyph,
                _hovered ? Palette.text : Palette.dim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // A 15x15 grid scaled once, as in the player's icons: stroke weights stay
    // in proportion whatever the bar decides these are worth.
    canvas.save();
    canvas.scale(size.width / 15, size.height / 15);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.square;
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(const Offset(2, 7.5), const Offset(13, 7.5), stroke);
      case _Glyph.maximize:
        canvas.drawRect(const Rect.fromLTRB(2.5, 2.5, 12.5, 12.5), stroke);
      case _Glyph.restore:
        // The window behind is drawn as two arms rather than a full square, so
        // the two rectangles do not read as a grid at this size.
        canvas.drawRect(const Rect.fromLTRB(2, 4.5, 10.5, 13), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(4.5, 2.5)
            ..lineTo(13, 2.5)
            ..lineTo(13, 10.5),
          stroke,
        );
      case _Glyph.close:
        canvas.drawLine(const Offset(3, 3), const Offset(12, 12), stroke);
        canvas.drawLine(const Offset(12, 3), const Offset(3, 12), stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
