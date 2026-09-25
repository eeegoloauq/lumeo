import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../api/preferences_store.dart';
import '../../platform/local_settings.dart';
import '../theme.dart';
import 'download_glyph.dart';
import 'download_rows.dart';
import 'poster_tile.dart' show PosterArtwork;
import 'source_list.dart' show formatBytes, formatTimeLeft;

/// Acquisition is a background operation, not content, so it lives where
/// background operations live: a small pinned indicator that is absent when
/// there is nothing to say, and opens into detail when there is. Giving it a
/// block in the page would push the catalogue down and make the layout jump
/// every time a download starts or finishes.
///
/// It is a ring rather than a labelled pill: the pill slid the search field
/// across the bar every time a download started or finished. The ring is a
/// fixed square at the end of the bar, where the only thing to its right is
/// the window's own buttons.
class DownloadsIndicator extends StatefulWidget {
  const DownloadsIndicator({
    super.key,
    required this.api,
    required this.store,
    required this.settings,
    required this.preferences,
    required this.onStop,
    required this.onOpen,
    required this.onPlay,
    required this.onStorage,
  });

  final LumeoApi api;
  final DownloadsStore store;

  /// This machine's Clear and how long finished downloads stay listed.
  final LocalSettings settings;
  final PreferencesStore preferences;
  final void Function(Download) onStop;

  /// A download with nothing to play yet opens its title page.
  final void Function(Download) onOpen;
  final void Function(Download) onPlay;

  /// Opens the settings where the disk the downloads take is managed.
  final VoidCallback onStorage;

  /// The width the bar reserves for this, so that a download starting moves
  /// nothing. Wide enough for the ring and its hover ground.
  static const width = 40.0;

  /// The panel hangs to the left of the button: this is the last control
  /// before the window's own buttons, so there is nothing to its right to
  /// open into.
  static const _panelWidth = 400.0;

  @override
  State<DownloadsIndicator> createState() => _DownloadsIndicatorState();
}

class _DownloadsIndicatorState extends State<DownloadsIndicator> {
  final _menu = MenuController();

  /// What the panel lists: everything it has something to say about, and
  /// what finished within the time this machine keeps it for.
  List<Download> _listed() => [
    for (final d in widget.store.all)
      if (DownloadKind.of(d) != null &&
          (!d.isDone ||
              (d.updatedAt != null &&
                  widget.settings.showsFinished(d.updatedAt!))))
        d,
  ];

  void _pick(Download d) {
    _menu.close();
    d.isDone || d.ready ? widget.onPlay(d) : widget.onOpen(d);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.store, widget.settings]),
      builder: (context, _) {
        final listed = _listed();
        if (listed.isEmpty) {
          return const SizedBox(width: DownloadsIndicator.width);
        }
        return SizedBox(
          width: DownloadsIndicator.width,
          child: MenuAnchor(
            controller: _menu,
            consumeOutsideTap: true,
            useRootOverlay: true,
            alignmentOffset: const Offset(
              DownloadsIndicator.width - DownloadsIndicator._panelWidth,
              10,
            ),
            style: MenuStyle(
              backgroundColor: WidgetStatePropertyAll(
                Palette.floating.withValues(alpha: 0.97),
              ),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              side: const WidgetStatePropertyAll(
                BorderSide(color: Palette.rim),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Shape.floating),
                ),
              ),
            ),
            menuChildren: [
              _Panel(
                api: widget.api,
                store: widget.store,
                preferences: widget.preferences,
                listed: listed,
                onPick: _pick,
                onPlay: (d) {
                  _menu.close();
                  widget.onPlay(d);
                },
                onStop: widget.onStop,
                onClear: widget.settings.clearFinishedDownloads,
                onStorage: () {
                  _menu.close();
                  widget.onStorage();
                },
              ),
            ],
            builder: (context, controller, _) => _Ring(
              listed: listed,
              open: controller.isOpen,
              onTap: () {
                if (controller.isOpen) return controller.close();
                // The keep time runs out between polls that change nothing,
                // so the list is read again on the way in.
                setState(() {});
                controller.open();
              },
            ),
          ),
        );
      },
    );
  }
}

/// Everything arriving read as one: how much of it is here, and whether
/// anybody is sending.
({double fraction, int rate, bool stalled}) _sum(Iterable<Download> list) {
  var completed = 0, total = 0, rate = 0, peers = 0;
  for (final d in list) {
    completed += d.progress.completed;
    total += d.progress.total;
    rate += d.progress.rate;
    peers += d.progress.peers;
  }
  return (
    fraction: total == 0 ? 0 : completed / total,
    rate: rate,
    stalled: peers == 0,
  );
}

class _Ring extends StatelessWidget {
  const _Ring({required this.listed, required this.open, required this.onTap});

  final List<Download> listed;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = listed.where((d) => d.isActive).toList();
    final sum = _sum(running);
    // Paused or failed and nothing else: neither arriving nor on disk.
    final allDone = listed.every((d) => d.isDone);
    return IconButton(
      key: const ValueKey('downloads'),
      onPressed: onTap,
      tooltip: running.isEmpty
          ? 'Downloads'
          : '${running.length} downloading · ${(sum.fraction * 100).round()}%',
      style: IconButton.styleFrom(
        backgroundColor: open ? Palette.raised : Colors.transparent,
        hoverColor: Palette.raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        fixedSize: const Size.square(34),
        padding: EdgeInsets.zero,
      ),
      icon: running.isNotEmpty
          ? DownloadGlyph(
              fraction: sum.fraction,
              stalled: sum.stalled,
              size: 22,
              color: Palette.text,
            )
          : DownloadGlyph(done: allDone, size: 22, color: Palette.text),
    );
  }
}

class _Panel extends StatefulWidget {
  const _Panel({
    required this.api,
    required this.store,
    required this.preferences,
    required this.listed,
    required this.onPick,
    required this.onPlay,
    required this.onStop,
    required this.onClear,
    required this.onStorage,
  });

  final LumeoApi api;
  final DownloadsStore store;
  final PreferencesStore preferences;
  final List<Download> listed;

  /// A row's own download: played when there is something to play, its
  /// title page opened otherwise.
  final void Function(Download) onPick;
  final void Function(Download) onPlay;
  final void Function(Download) onStop;
  final VoidCallback onClear;
  final VoidCallback onStorage;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  late final Future<Storage> _storage = widget.api.storage();

  /// What was watched of each series with a season ready, asked once per
  /// opening: it decides which episode the row's Play opens.
  final _watched = <String, Future<WatchProgress?>>{};
  final _expanded = <String>{};

  /// "Finding peers · 4 min" counts while no poll changes anything.
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (widget.listed.any(
        (d) => DownloadKind.of(d) == DownloadKind.stalled,
      )) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  Future<WatchProgress?> _watchedOf(String itemId) =>
      _watched[itemId] ??= widget.api
          .progress(itemId)
          .then<WatchProgress?>((p) => p)
          // Without it Play opens the first episode of the row.
          .catchError((Object _) => null);

  void _toggle(DownloadRow row) => setState(
    () => _expanded.contains(row.key)
        ? _expanded.remove(row.key)
        : _expanded.add(row.key),
  );

  @override
  Widget build(BuildContext context) {
    final groups = arrangeDownloads(widget.listed);
    final rate = _sum(widget.listed.where((d) => d.isActive)).rate;
    final now = DateTime.now();
    return ConstrainedBox(
      // A season being acquired is many rows, and the bar it hangs from is at
      // the top of the window: without a ceiling the last of them are off the
      // bottom of the screen.
      constraints: BoxConstraints(
        maxWidth: DownloadsIndicator._panelWidth,
        minWidth: DownloadsIndicator._panelWidth,
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Expanded(
                  child: Text(
                    'Downloads',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Palette.text,
                    ),
                  ),
                ),
                if (rate > 0) Text('↓ ${formatBytes(rate)}/s', style: _small),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, g) in groups.indexed) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Divider(height: 1, color: Palette.divider),
                      ),
                    _SectionHeader(
                      group: g,
                      onClear: g.section == DownloadSection.ready
                          ? widget.onClear
                          : null,
                    ),
                    for (final row in g.rows) ..._rows(row, now),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: Palette.divider),
          _footer(),
        ],
      ),
    );
  }

  Iterable<Widget> _rows(DownloadRow row, DateTime now) sync* {
    final open = _expanded.contains(row.key);
    final d = row.first;
    final ready = row.kind == DownloadKind.ready;
    final watched = ready && row.isSeason ? _watchedOf(d.itemId) : null;
    yield FutureBuilder<WatchProgress?>(
      // Keyed so that a row keeps what it learned when rows above it go.
      key: ValueKey(
        row.isSeason ? 'download-row:${row.key}' : 'download:${d.id}',
      ),
      future: watched,
      builder: (context, snapshot) {
        final next = ready ? nextToPlay(row, snapshot.data) : d;
        return _Row(
          row: row,
          item: widget.store.itemOf(d),
          title: widget.store.titleOf(d) ?? d.name,
          line: _line(row, next, now),
          expanded: row.isSeason ? open : null,
          onTap: row.isSeason ? () => _toggle(row) : () => widget.onPick(d),
          actions: _actions(row, next),
        );
      },
    );
    if (!row.isSeason || !open) return;
    for (final e in row.downloads) {
      final one = DownloadRow(e.id, row.kind, [e]);
      yield _EpisodeRow(
        key: ValueKey('download:${e.id}'),
        download: e,
        waiting: row.kind.section == DownloadSection.waiting,
        line: switch (row.kind) {
          DownloadKind.ready => formatBytes(e.progress.total),
          DownloadKind.arriving => '${(e.progress.fraction * 100).round()} %',
          _ => waitingLine(one, now),
        },
        onTap: () => widget.onPick(e),
        // Play is the row itself here; the rest act on this episode alone.
        actions: ready ? const [] : _actions(one, e, compact: true),
      );
    }
  }

  String _line(DownloadRow row, Download next, DateTime now) {
    switch (row.kind) {
      case DownloadKind.ready:
        return [
          if (row.isSeason) 'E${next.episode} next',
          formatBytes(row.size),
        ].join(' · ');
      case DownloadKind.arriving:
        final parts = [
          if (row.rate > 0) '${formatBytes(row.rate)}/s',
          if (row.eta case final eta?) formatTimeLeft(eta),
        ];
        return parts.isEmpty
            ? '${(row.fraction * 100).round()} %'
            : parts.join(' · ');
      case DownloadKind.stalled || DownloadKind.paused || DownloadKind.failed:
        return waitingLine(row, now);
    }
  }

  /// The one thing a row's state lets you do, and Stop for what is waiting.
  List<Widget> _actions(
    DownloadRow row,
    Download next, {
    bool compact = false,
  }) {
    final all = row.downloads;
    // A season's rows say which episodes a button reaches.
    final which = row.isSeason
        ? ' ${episodeRuns([for (final d in all) d.episode])}'
        : '';
    final stop = _Action(
      icon: Icons.close,
      tooltip: 'Stop and discard$which',
      compact: compact,
      onPressed: () => all.forEach(widget.onStop),
    );
    return switch (row.kind) {
      DownloadKind.ready => [
        _PlayButton(
          tooltip: next.episode > 0
              ? 'Play S${next.season} E${next.episode}'
              : 'Play',
          onPressed: () => widget.onPlay(next),
        ),
      ],
      DownloadKind.arriving => [
        _Action(
          icon: Icons.pause,
          tooltip: 'Pause$which',
          compact: compact,
          onPressed: () {
            for (final d in all) {
              unawaited(widget.store.pause(d));
            }
          },
        ),
      ],
      DownloadKind.stalled => [stop],
      DownloadKind.paused || DownloadKind.failed => [
        _Action(
          icon: row.kind == DownloadKind.paused
              ? Icons.play_arrow
              : Icons.refresh,
          tooltip:
              '${row.kind == DownloadKind.paused ? 'Resume' : 'Retry'}'
              '$which',
          compact: compact,
          onPressed: () {
            for (final d in all) {
              unawaited(widget.store.resume(d));
            }
          },
        ),
        stop,
      ],
    };
  }

  Widget _footer() => FutureBuilder<Storage>(
    future: _storage,
    builder: (context, snapshot) {
      final storage = snapshot.data;
      final limit = widget.preferences.current?.diskLimit ?? 0;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(switch (storage) {
                null => '',
                _ when limit > 0 =>
                  '${formatBytes(storage.used)} of ${formatBytes(limit)}',
                _ when storage.diskFree > 0 =>
                  '${formatBytes(storage.used)} · '
                      '${formatBytes(storage.diskFree)} free',
                _ => '${formatBytes(storage.used)} on disk',
              }, style: _small),
            ),
            TextButton(
              onPressed: widget.onStorage,
              style: TextButton.styleFrom(
                foregroundColor: Palette.dim,
                textStyle: const TextStyle(fontSize: 12),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Storage ›'),
            ),
          ],
        ),
      );
    },
  );
}

const _small = TextStyle(
  fontFamily: Typo.sans,
  fontSize: 12,
  height: 1.3,
  color: Palette.muted,
);

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.group, required this.onClear});

  final DownloadGroup group;

  /// Takes what finished off the list; only the finished have it.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(
      fontFamily: Typo.sans,
      fontSize: 11,
      height: 1.3,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.9,
      color: Palette.muted,
    );
    final eta = group.section == DownloadSection.arriving ? group.eta : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, onClear == null ? 16 : 8, 6),
      child: SizedBox(
        // The Clear button is taller than the words; every header is its
        // height so that the sections sit the same distance apart.
        height: 24,
        child: Row(
          children: [
            Text(group.section.title.toUpperCase(), style: label),
            const SizedBox(width: 8),
            Text(
              '${group.count}',
              style: label.copyWith(
                color: Palette.muted.withValues(alpha: 0.7),
              ),
            ),
            const Spacer(),
            if (eta != null)
              Text(
                'about ${spokenMinutes(Duration(seconds: eta))}',
                style: _small,
              ),
            if (onClear != null)
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  foregroundColor: Palette.dim,
                  textStyle: const TextStyle(fontSize: 12),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Clear'),
              ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.item,
    required this.title,
    required this.line,
    required this.expanded,
    required this.onTap,
    required this.actions,
  });

  final DownloadRow row;
  final MediaItem? item;
  final String title;

  /// The line under the title: size, speed, or what it waits on.
  final String line;

  /// Null for a single download, which has nothing to open into.
  final bool? expanded;
  final VoidCallback onTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final waiting = row.kind.section == DownloadSection.waiting;
    return InkWell(
      onTap: onTap,
      hoverColor: Palette.hover,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            Opacity(
              opacity: waiting ? 0.6 : 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Shape.art),
                child: SizedBox(
                  width: 32,
                  height: 48,
                  child: item == null
                      ? const ColoredBox(color: Palette.raised)
                      : PosterArtwork(item: item!, width: 32, named: false),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Typo.cardTitle.copyWith(
                            color: waiting ? Palette.dim : Palette.text,
                          ),
                        ),
                      ),
                      if (row.tag.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(row.tag, style: _small),
                      ],
                      if (expanded case final open?)
                        Icon(
                          open ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: Palette.muted,
                        ),
                    ],
                  ),
                  if (row.kind == DownloadKind.arriving) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: row.fraction,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                      color: Palette.text,
                      backgroundColor: const Color(0x24FFFFFF),
                      semanticsLabel: 'Downloaded',
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    line,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _small.copyWith(
                      color: row.kind == DownloadKind.failed
                          ? Palette.warn
                          : Palette.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// One episode of a season row, opened out under it.
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    super.key,
    required this.download,
    required this.waiting,
    required this.line,
    required this.onTap,
    required this.actions,
  });

  final Download download;
  final bool waiting;
  final String line;
  final VoidCallback onTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: Palette.hover,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(60, 0, 12, 0),
          child: Row(
            children: [
              Text(
                'E${download.episode}',
                style: TextStyle(
                  fontFamily: Typo.sans,
                  fontSize: 13,
                  color: waiting ? Palette.muted : Palette.dim,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: _small,
                ),
              ),
              const SizedBox(width: 4),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// What will play is marked in the accent, as everywhere else.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton.filled(
    onPressed: onPressed,
    tooltip: tooltip,
    iconSize: 18,
    style: IconButton.styleFrom(
      fixedSize: const Size.square(32),
      minimumSize: const Size.square(32),
      padding: EdgeInsets.zero,
    ),
    icon: const Icon(Icons.play_arrow),
  );
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.compact = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// The smaller size of an episode opened out under its season.
  final bool compact;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    iconSize: compact ? 16 : 18,
    color: Palette.muted,
    style: IconButton.styleFrom(
      fixedSize: Size.square(compact ? 28 : 32),
      minimumSize: Size.square(compact ? 28 : 32),
      padding: EdgeInsets.zero,
    ),
    icon: Icon(icon),
  );
}
