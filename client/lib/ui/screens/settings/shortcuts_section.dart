import 'dart:async';

import 'package:flutter/material.dart';

import '../../../api/preferences_store.dart';
import '../../player/bindings.dart';
import '../../player/mpv_facts.dart';
import '../../theme.dart';
import 'controls.dart';

/// The keys that do something in a film most people reach for, by mpv's
/// names. What each does, and every other key that does the same, is read
/// from mpv's bindings and ours: nothing about a key is written here.
const _everyday = [
  'SPACE',
  'LEFT',
  'RIGHT',
  'Shift+LEFT',
  'Shift+RIGHT',
  'DOWN',
  'UP',
  '9',
  '0',
  'm',
  'f',
  'F11',
  'c',
  'v',
  '[',
  ']',
  's',
  'q',
  'ESC',
];

/// The player's keys, read from mpv and not editable: mpv owns them.
class ShortcutsSection extends StatefulWidget {
  const ShortcutsSection({super.key, required this.preferences});

  final PreferencesStore preferences;

  @override
  State<ShortcutsSection> createState() => _ShortcutsSectionState();
}

class _ShortcutsSectionState extends State<ShortcutsSection> {
  final _facts = MpvFacts.instance;
  bool _all = false;

  @override
  void initState() {
    super.initState();
    unawaited(_facts.load());
  }

  @override
  Widget build(BuildContext context) {
    return SettingsBlock(
      title: 'Shortcuts',
      children: [
        ListenableBuilder(
          listenable: _facts,
          builder: (context, _) {
            if (!_facts.done) return const SettingsLoading();
            if (!_facts.answered) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'mpv has not said which keys it has.',
                  style: Typo.data,
                ),
              );
            }
            final step = widget.preferences.current?.seekStep ?? 5;
            final bindings = [
              ..._facts.bindings,
              ...ownBindingList(seekStep: step),
            ];
            final lines = shortcuts(bindings, only: _all ? null : _everyday);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Columns(lines: lines),
                const SizedBox(height: 14),
                RowButton(
                  label: _all ? 'Fewer keys' : 'All player keys',
                  onPressed: () => setState(() => _all = !_all),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Columns extends StatelessWidget {
  const _Columns({required this.lines});

  final List<Shortcut> lines;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(children: [for (final line in lines) _Line(line)]);
        }
        final half = (lines.length / 2).ceil();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                children: [for (final line in lines.take(half)) _Line(line)],
              ),
            ),
            const SizedBox(width: 40),
            Expanded(
              child: Column(
                children: [for (final line in lines.skip(half)) _Line(line)],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.line);

  final Shortcut line;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Palette.divider)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                line.what,
                style: Typo.data.copyWith(fontSize: 14, color: Palette.dim),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 4,
                children: [for (final key in line.keys) _Key(key)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: const BoxDecoration(
        color: Palette.raised,
        borderRadius: BorderRadius.all(Shape.controlRadius),
        border: Border(
          top: BorderSide(color: Color(0xFF2F3037)),
          left: BorderSide(color: Color(0xFF2F3037)),
          right: BorderSide(color: Color(0xFF2F3037)),
          bottom: BorderSide(color: Color(0xFF2F3037), width: 2),
        ),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: Typo.sans,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Palette.text,
          ),
        ),
      ),
    );
  }
}
