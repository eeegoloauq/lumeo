import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// A row that scrolls sideways the way a desktop expects.
///
/// A plain wheel keeps scrolling the page, because a row that swallows it
/// leaves the page stuck wherever the pointer happens to rest. Sideways
/// movement comes from the three things that mean it: an arrow at each end,
/// shown on hover and only where there is something left in that direction;
/// shift and the wheel, which is the desktop convention; and a trackpad's own
/// horizontal gesture, which Flutter already delivers.
class HorizontalStrip extends StatefulWidget {
  const HorizontalStrip({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: 48),
    this.controller,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double separatorWidth;
  final EdgeInsets padding;
  final ScrollController? controller;

  @override
  State<HorizontalStrip> createState() => _HorizontalStripState();
}

class _HorizontalStripState extends State<HorizontalStrip> {
  late final ScrollController _controller =
      widget.controller ?? ScrollController();
  bool _hovered = false;
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateEnds);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateEnds());
  }

  @override
  void dispose() {
    _controller.removeListener(_updateEnds);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _updateEnds() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final left = position.pixels > 4;
    final right = position.pixels < position.maxScrollExtent - 4;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  static bool get _shiftHeld =>
      HardwareKeyboard.instance.logicalKeysPressed.any(
        (k) =>
            k == LogicalKeyboardKey.shiftLeft ||
            k == LogicalKeyboardKey.shiftRight,
      );

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    // A trackpad's horizontal gesture is handled by the list itself. Only
    // shift turns the wheel sideways; without it the event is left alone and
    // the page scrolls, which is what someone spinning the wheel meant.
    if (event.scrollDelta.dx != 0 || !_shiftHeld) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0) return;
    _controller.jumpTo(
      (_controller.position.pixels + delta).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      ),
    );
  }

  void _step(int direction) {
    if (!_controller.hasClients) return;
    final page = _controller.position.viewportDimension * 0.8;
    _controller.animateTo(
      (_controller.position.pixels + page * direction).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            Listener(
              onPointerSignal: _onSignal,
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                padding: widget.padding,
                itemCount: widget.itemCount,
                separatorBuilder: (_, _) =>
                    SizedBox(width: widget.separatorWidth),
                itemBuilder: widget.itemBuilder,
              ),
            ),
            _Arrow(
              visible: _hovered && _canLeft,
              alignment: Alignment.centerLeft,
              icon: Icons.chevron_left,
              onTap: () => _step(-1),
            ),
            _Arrow(
              visible: _hovered && _canRight,
              alignment: Alignment.centerRight,
              icon: Icons.chevron_right,
              onTap: () => _step(1),
            ),
          ],
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.visible,
    required this.alignment,
    required this.icon,
    required this.onTap,
  });

  final bool visible;
  final Alignment alignment;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                width: 44,
                height: double.infinity,
                color: Palette.ground(0.70),
                child: Icon(icon, size: 26, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
