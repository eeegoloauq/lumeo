import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../platform/folders.dart';
import '../theme.dart';

class ReleaseNotesCard extends StatelessWidget {
  const ReleaseNotesCard({
    super.key,
    required this.version,
    required this.items,
    required this.onClose,
  });

  final String version;
  final List<String> items;
  final VoidCallback onClose;

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
              child: Text(
                context.l10n.releaseUpdatedTo(version),
                style: Typo.cardTitle.copyWith(fontSize: 15),
              ),
            ),
            IconButton(
              tooltip: context.l10n.commonClose,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 10),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: Palette.dim,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    item,
                    style: Typo.data.copyWith(color: Palette.dim),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: onClose,
              child: Text(context.l10n.releaseGotIt),
            ),
            TextButton(
              onPressed: () =>
                  openUrl('https://github.com/eeegoloauq/lumeo/releases'),
              child: Text(context.l10n.releaseAllChanges),
            ),
          ],
        ),
      ],
    ),
  );
}
