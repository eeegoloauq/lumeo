import 'package:flutter/material.dart';

import '../theme.dart';

/// One line of the settings page: what it is on the left, with a hint under
/// it when the name alone does not say enough, and the control beside it.
///
/// The control column starts at a fixed place rather than hugging the right
/// edge, so a column of segmented choices reads as one column; on a narrow
/// window the control goes under its name instead of being squeezed.
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.trailing,
  });

  static const minHeight = 60.0;
  static const labelWidth = 232.0;

  final String label;
  final String? hint;
  final Widget value;

  /// Beside the control, for the buttons that act on what it shows.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: SettingsType.label),
        if (hint != null) ...[
          const SizedBox(height: 3),
          Text(hint!, style: SettingsType.hint),
        ],
      ],
    );
    final control = Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [value, ?trailing],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < labelWidth * 2.4) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [name, const SizedBox(height: 10), control],
              );
            }
            return Row(
              children: [
                SizedBox(width: labelWidth, child: name),
                const SizedBox(width: 24),
                Expanded(child: control),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Rows with a line between them, and none above the first or below the last.
///
/// The line is [Palette.divider] rather than [Palette.line]: a row is not an
/// object, it is one line of a list, and the edge that separates two of them
/// should be half the weight of the edge that would surround them. It is also
/// white at low alpha, so it reads the same whichever surface the list is
/// drawn on.
class SettingRows extends StatelessWidget {
  const SettingRows(this.rows, {super.key});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0)
            const Divider(height: 1, thickness: 1, color: Palette.divider),
          row,
        ],
      ],
    );
  }
}

/// The settings page's own sizes, from its mockup: a name a little larger
/// than a data line, a hint a little smaller.
class SettingsType {
  static const label = TextStyle(
    fontFamily: Typo.sans,
    fontSize: 14,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: Palette.text,
  );

  static const hint = TextStyle(
    fontFamily: Typo.sans,
    fontSize: 12,
    height: 1.35,
    color: Palette.muted,
  );

  static const heading = TextStyle(
    fontFamily: Typo.sans,
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: Palette.text,
  );

  static const value = TextStyle(
    fontFamily: Typo.sans,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: Palette.dim,
  );
}
