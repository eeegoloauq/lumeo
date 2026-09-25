import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../platform/decoders.dart';
import '../theme.dart';
import 'play_block.dart';

/// Every copy of one film or episode, in a drawer from the right.
///
/// Grouped the way the choice is made: what is already here, then by
/// resolution, each group in the core's order. A row is the copy's name and
/// its languages; the release name waits in a tooltip, because a wall of
/// truncated file names is what every addon client shows.
Future<void> showSources(BuildContext context, SourceChoice choice) =>
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close sources',
      barrierColor: const Color(0x80000000),
      transitionDuration: Motion.panel,
      pageBuilder: (context, _, _) => Align(
        alignment: Alignment.centerRight,
        child: _SourceDrawer(choice: choice),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Motion.ease)),
        child: child,
      ),
    );

/// The copy as one line: who made it and what kind of copy it is.
String sourceTitle(MediaSource s) => [
  s.release.group.isNotEmpty ? s.release.group : s.tracker,
  s.release.kind,
].where((e) => e.isNotEmpty).join(' · ');

/// The copy's languages as codes: flags name countries, not languages. Three
/// is a fact; twenty-six is a wall, so the rest becomes a count.
List<String> languageCodes(MediaSource s) {
  final codes = s.languages.map((e) => e.toUpperCase()).toList();
  return codes.length <= 3 ? codes : [...codes.take(3), '+${codes.length - 3}'];
}

String localLabel(MediaSource s) => switch (s.local) {
  'done' => 'on disk',
  'partial' => 'part on disk',
  _ => '',
};

class _SourceDrawer extends StatelessWidget {
  const _SourceDrawer({required this.choice});

  final SourceChoice choice;

  @override
  Widget build(BuildContext context) {
    final c = choice;
    return Drawer(
      width: 520,
      backgroundColor: Palette.floating,
      shape: const RoundedRectangleBorder(),
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final sources = c.sources ?? const <MediaSource>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 64,
                padding: const EdgeInsets.only(left: 24, right: 12),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Palette.line)),
                ),
                child: Row(
                  children: [
                    if (c.season > 0) ...[
                      Text(
                        'S${c.season} E${c.episode}',
                        style: Typo.cardTitle.copyWith(fontSize: 18),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        sources.length == 1
                            ? '1 copy'
                            : '${sources.length} copies',
                        style: c.season > 0
                            ? Typo.data
                            : Typo.cardTitle.copyWith(fontSize: 18),
                      ),
                    ),
                    const CloseButton(),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final (heading, rows) in _groups(sources)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                        child: Text(heading, style: Typo.data),
                      ),
                      for (final s in rows)
                        _SourceRow(
                          source: s,
                          current: identical(s, c.picked),
                          onPick: () {
                            c.pick(s);
                            Navigator.pop(context);
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// On disk first, then one group per resolution from the sharpest down,
  /// each in the order the core ranked it.
  static List<(String, List<MediaSource>)> _groups(List<MediaSource> all) {
    final local = all.where((s) => s.local.isNotEmpty).toList();
    final byResolution = <String, List<MediaSource>>{};
    for (final s in all.where((s) => s.local.isEmpty)) {
      final r = s.release.resolution.isEmpty ? 'Other' : s.release.resolution;
      byResolution.putIfAbsent(r, () => []).add(s);
    }
    int sharpness(String r) => int.tryParse(r.replaceAll('p', '')) ?? 0;
    final order = byResolution.keys.toList()
      ..sort((a, b) => sharpness(b).compareTo(sharpness(a)));
    return [
      if (local.isNotEmpty) ('On disk', local),
      for (final r in order) (r, byResolution[r]!),
    ];
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.current,
    required this.onPick,
  });

  final MediaSource source;
  final bool current;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final s = source;
    // What this machine cannot decode is a fact about the row, not about the
    // film: the same copy plays on the next machine. It is marked rather than
    // hidden, and Play does not choose it.
    final gap = DeviceDecoders.instance.gapIn(s.release);
    final codes = languageCodes(s);
    final title = sourceTitle(s);
    return Tooltip(
      message: [s.rawName, ?gap?.sentence].join('\n'),
      waitDuration: const Duration(milliseconds: 600),
      child: ListTile(
        // The drawer opens on the copy Play would start, so the keyboard is
        // inside it: arrows move, Enter picks, Escape closes.
        autofocus: current,
        selected: current,
        selectedTileColor: Palette.tint,
        selectedColor: Palette.text,
        textColor: Palette.text,
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        onTap: onPick,
        title: Row(
          children: [
            Expanded(
              child: Text(
                [
                  if (s.local.isNotEmpty && s.release.resolution.isNotEmpty)
                    s.release.resolution,
                  title.isEmpty ? '—' : title,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: current ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            Text(
              [
                formatBytes(s.size),
                if (s.local.isNotEmpty)
                  localLabel(s)
                else if (s.seeders > 0)
                  '${s.seeders} seeds',
              ].join(' · '),
              style: Typo.data.copyWith(color: Palette.dim),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              for (final code in codes) _Code(code),
              if (codes.isEmpty) Text('no languages listed', style: Typo.data),
              if (gap != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    gap.mark,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Typo.data.copyWith(color: Palette.warn),
                  ),
                ),
              ],
              const Spacer(),
              if (s.lastUsed) Text('last used', style: Typo.data),
            ],
          ),
        ),
      ),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code(this.code);

  final String code;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 4),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Palette.tint,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(code, style: Typo.dataStrong.copyWith(fontSize: 11)),
  );
}

/// "3 min left", "1 h 05 min left".
String formatTimeLeft(int seconds) {
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes min left';
  final rest = (minutes % 60).toString().padLeft(2, '0');
  return '${minutes ~/ 60} h $rest min left';
}

String formatBytes(int value) {
  if (value <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = value.toDouble();
  var unit = 0;
  while (v >= 1024 && unit < units.length - 1) {
    v /= 1024;
    unit++;
  }
  return '${v.toStringAsFixed(v >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}
