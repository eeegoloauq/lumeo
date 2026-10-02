import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../platform/folders.dart';
import '../theme.dart';

/// Release notes in a corner: what an update brought, or what a newer
/// release would bring. A long list stops at [shown] until its count is
/// clicked, and scrolls when it is taller than the room the card has. A
/// [collapsed] card shows only the count: its notes were told before.
class ReleaseNotesCard extends StatefulWidget {
  const ReleaseNotesCard({
    super.key,
    required this.title,
    required this.items,
    required this.action,
    required this.onAction,
    required this.onClose,
    this.collapsed = false,
  });

  static const shown = 6;

  final String title;
  final List<String> items;
  final String action;
  final VoidCallback onAction;
  final VoidCallback onClose;
  final bool collapsed;

  @override
  State<ReleaseNotesCard> createState() => _ReleaseNotesCardState();
}

class _ReleaseNotesCardState extends State<ReleaseNotesCard> {
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final shown = _all
        ? items
        : items.take(widget.collapsed ? 0 : ReleaseNotesCard.shown);
    final hidden = items.length - shown.length;
    return Container(
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
                  widget.title,
                  style: Typo.cardTitle.copyWith(fontSize: 15),
                ),
              ),
              IconButton(
                tooltip: context.l10n.commonClose,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in shown)
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
                  if (hidden > 0)
                    TextButton(
                      onPressed: () => setState(() => _all = true),
                      child: Text(
                        widget.collapsed
                            ? context.l10n.releaseChanges(hidden)
                            : context.l10n.releaseMore(hidden),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: widget.onAction,
                child: Text(widget.action),
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
}
