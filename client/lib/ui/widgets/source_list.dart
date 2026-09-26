import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
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
      barrierLabel: context.l10n.downloadsCloseSources,
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
String sourceTitle(MediaSource s, AppLocalizations l10n) => [
  s.release.group.isNotEmpty ? s.release.group : s.tracker,
  s.release.kind(l10n),
].where((e) => e.isNotEmpty).join(' · ');

/// The copy's languages as codes: flags name countries, not languages. Three
/// is a fact; twenty-six is a wall, so the rest becomes a count.
List<String> languageCodes(MediaSource s, AppLocalizations l10n) {
  final codes = s.languages.map((e) => e.toUpperCase()).toList();
  return codes.length <= 3
      ? codes
      : [...codes.take(3), l10n.downloadsMoreLanguages(codes.length - 3)];
}

String localLabel(MediaSource s, AppLocalizations l10n) => switch (s.local) {
  'done' => l10n.downloadsOnDiskLower,
  'partial' => l10n.downloadsPartOnDisk,
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
                        context.l10n.downloadsSeasonEpisode(
                          c.season,
                          c.episode,
                        ),
                        style: Typo.cardTitle.copyWith(fontSize: 18),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        context.l10n.downloadsCopyCount(sources.length),
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
                    for (final (heading, rows) in _groups(
                      sources,
                      context.l10n,
                    )) ...[
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
  static List<(String, List<MediaSource>)> _groups(
    List<MediaSource> all,
    AppLocalizations l10n,
  ) {
    final local = all.where((s) => s.local.isNotEmpty).toList();
    final byResolution = <String, List<MediaSource>>{};
    for (final s in all.where((s) => s.local.isEmpty)) {
      final r = s.release.resolution.isEmpty
          ? l10n.downloadsOther
          : s.release.resolution;
      byResolution.putIfAbsent(r, () => []).add(s);
    }
    int sharpness(String r) => int.tryParse(r.replaceAll('p', '')) ?? 0;
    final order = byResolution.keys.toList()
      ..sort((a, b) => sharpness(b).compareTo(sharpness(a)));
    return [
      if (local.isNotEmpty) (l10n.downloadsOnDisk, local),
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
    final codes = languageCodes(s, context.l10n);
    final title = sourceTitle(s, context.l10n);
    return Tooltip(
      message: [s.rawName, ?gap?.sentence(context.l10n)].join('\n'),
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
                formatBytes(s.size, context.l10n),
                if (s.local.isNotEmpty)
                  localLabel(s, context.l10n)
                else if (s.seeders > 0)
                  context.l10n.downloadsSeedCount(s.seeders),
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
              if (codes.isEmpty)
                Text(context.l10n.downloadsNoLanguages, style: Typo.data),
              if (gap != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    gap.mark(context.l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Typo.data.copyWith(color: Palette.warn),
                  ),
                ),
              ],
              const Spacer(),
              if (s.lastUsed)
                Text(context.l10n.downloadsLastUsed, style: Typo.data),
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
String formatTimeLeft(int seconds, AppLocalizations l10n) {
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return l10n.downloadsTimeLeftMinutes(minutes);
  final rest = NumberFormat('00', l10n.localeName).format(minutes % 60);
  return l10n.downloadsTimeLeftHours(minutes ~/ 60, rest);
}

String formatBytes(int value, AppLocalizations l10n) {
  if (value <= 0) return '—';
  final units = [
    l10n.downloadsByteUnit,
    l10n.downloadsKilobyteUnit,
    l10n.downloadsMegabyteUnit,
    l10n.downloadsGigabyteUnit,
    l10n.downloadsTerabyteUnit,
  ];
  var v = value.toDouble();
  var unit = 0;
  while (v >= 1024 && unit < units.length - 1) {
    v /= 1024;
    unit++;
  }
  final size = NumberFormat(
    v >= 100 || unit == 0 ? '0' : '0.0',
    l10n.localeName,
  ).format(v);
  return l10n.downloadsSize(size, units[unit]);
}
