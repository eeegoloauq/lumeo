import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme.dart';

/// A notice that sits over the page's corner until it is closed: a title,
/// a close button and what it has to say.
class FloatingCard extends StatelessWidget {
  const FloatingCard({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: 360,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Palette.raised,
      borderRadius: const BorderRadius.all(Shape.floatingRadius),
      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x99000000),
          blurRadius: 32,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Typo.cardTitle.copyWith(fontSize: 15)),
            ),
            IconButton(
              tooltip: context.l10n.commonClose,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Flexible(child: child),
      ],
    ),
  );
}
