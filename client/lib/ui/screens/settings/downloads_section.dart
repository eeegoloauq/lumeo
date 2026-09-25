import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../api/client.dart';
import '../../../api/downloads_store.dart';
import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../../platform/folders.dart';
import '../../../platform/local_settings.dart';
import '../../player/screenshots.dart';
import '../../theme.dart';
import '../../widgets/poster_tile.dart';
import '../../widgets/setting_row.dart';
import '../../widgets/source_list.dart' show formatBytes;
import 'controls.dart';
import 'folder_dialog.dart';

const _gib = 1 << 30;
const _mib = 1 << 20;

/// Where downloads go, how long they stay, what the swarm may take, and what
/// is on disk now.
class DownloadsSection extends StatefulWidget {
  const DownloadsSection({
    super.key,
    required this.api,
    required this.downloads,
    required this.preferences,
    required this.settings,
    required this.about,
    required this.pictures,
    required this.onAboutChanged,
    required this.patch,
    required this.error,
  });

  final LumeoApi api;
  final DownloadsStore downloads;
  final PreferencesStore preferences;
  final LocalSettings settings;

  /// For the download folder the core actually uses.
  final Future<CoreAbout> about;
  final Future<String> Function() pictures;
  final VoidCallback onAboutChanged;
  final Future<void> Function(Map<String, Object?>) patch;
  final Object? error;

  @override
  State<DownloadsSection> createState() => _DownloadsSectionState();
}

class _DownloadsSectionState extends State<DownloadsSection> {
  late Future<Storage> _storage = widget.api.storage();
  late final Future<String> _pictures = widget.pictures();
  String? _freeing;
  Object? _actionError;

  String _keyFor(StorageTitle title) =>
      title.itemId.isNotEmpty ? title.itemId : 'download:${title.title}';

  void _reload() {
    if (!mounted) return;
    setState(() {
      _storage = widget.api.storage();
    });
  }

  Future<void> _act(String what, Future<void> Function() action) async {
    setState(() {
      _freeing = what;
      _actionError = null;
    });
    try {
      await action();
      _reload();
    } on Object catch (error) {
      if (mounted) setState(() => _actionError = error);
    } finally {
      if (mounted) setState(() => _freeing = null);
    }
  }

  Future<void> _free(StorageTitle title) => _act(_keyFor(title), () async {
    if (title.itemId.isNotEmpty) {
      await widget.api.clearStorage(itemId: title.itemId);
    } else {
      for (final download in title.downloads) {
        await widget.api.stopDownload(download.id, discardData: true);
      }
    }
    await widget.downloads.refresh();
  });

  Future<void> _freeAll(Storage storage) async {
    final sure = await confirm(
      context,
      message:
          'Delete ${formatBytes(storage.used)}? Every download goes, '
          'including the ones in progress.',
      action: 'Delete',
    );
    if (!sure || !mounted) return;
    await _act('all', () async {
      await widget.api.clearStorage();
      await widget.downloads.refresh();
    });
  }

  // The core frees what the new policy expires before it answers, so the
  // list read after it is the new one.
  Future<void> _setPolicy(Map<String, Object?> change) async {
    await widget.patch(change);
    if (!mounted) return;
    await widget.downloads.refresh();
    _reload();
  }

  Future<void> _changeDownloadDir(String now) async {
    final chosen = await chooseFolder(
      context,
      title: 'Download new films to',
      start: now,
    );
    if (chosen == null || chosen == now || !mounted) return;
    await widget.patch({'downloadDir': chosen});
    widget.onAboutChanged();
    _reload();
  }

  Future<void> _defaultDownloadDir() async {
    await widget.patch({'downloadDir': null});
    widget.onAboutChanged();
    _reload();
  }

  Future<void> _changeScreenshotsDir(String now) async {
    final chosen = await chooseFolder(
      context,
      title: 'Save screenshots to',
      start: now,
    );
    if (chosen != null) widget.settings.screenshotsDir = chosen;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.preferences.current;
    return SettingsBlock(
      title: 'Downloads',
      children: [
        FutureBuilder<Storage>(
          future: _storage,
          builder: (context, snapshot) => snapshot.data == null
              ? const SizedBox.shrink()
              : _StorageBar(
                  storage: snapshot.data!,
                  limit: current?.diskLimit ?? 0,
                ),
        ),
        SettingRows([
          if (current != null) ..._policyRows(current),
          // This machine's, like the Clear it works with: in client.json.
          SettingRow(
            label: 'Finished in the panel',
            value: Segments<String>(
              choices: const [
                ('1d', '1 day'),
                ('7d', '7 days'),
                ('cleared', 'Until cleared'),
              ],
              selected: widget.settings.keepFinished,
              onSelected: (keep) => widget.settings.keepFinished = keep,
            ),
          ),
          _videosRow(current),
          _screenshotsRow(),
          if (current == null && widget.error == null) const SettingsLoading(),
          if (widget.error != null) ErrorRow(widget.error!),
        ]),
        if (current != null) ...[
          const _SubHeading('Network'),
          SettingRows(_networkRows(current)),
        ],
        FutureBuilder<Storage>(
          future: _storage,
          builder: (context, snapshot) => _onDisk(snapshot),
        ),
      ],
    );
  }

  List<Widget> _policyRows(Preferences current) {
    const limitTip =
        'Over the limit, watched downloads go first. Unwatched ones stay.';
    final keep = switch (current.keep) {
      'watched' => 'watched',
      'days' when current.keepDays == 30 => 'days30',
      'days' => 'custom',
      _ => 'forever',
    };
    return [
      SettingRow(
        label: 'Disk limit',
        hint: 'When full, watched downloads go first.',
        value: PresetChoice(
          presets: const [
            (50 * _gib, '50 GB'),
            (100 * _gib, '100 GB'),
            (0, 'No limit'),
          ],
          tooltips: const {50 * _gib: limitTip, 100 * _gib: limitTip},
          value: current.diskLimit,
          describe: (bytes) => '${(bytes / _gib).round()} GB',
          onSelected: (limit) => _setPolicy({'diskLimit': limit}),
          askCustom: (context) async {
            final gb = await askNumber(
              context,
              title: 'Disk limit',
              unit: 'GB',
              initial: current.diskLimit == 0
                  ? 250
                  : (current.diskLimit / _gib).round(),
              min: 1,
              max: 100000,
            );
            return gb == null ? null : gb * _gib;
          },
        ),
      ),
      SettingRow(
        label: 'Delete watched',
        hint: 'Unwatched downloads are never deleted by this.',
        value: Segments<String>(
          choices: [
            ('watched', 'Right away'),
            ('days30', 'After 30 days'),
            (
              'custom',
              keep == 'custom' ? 'After ${current.keepDays} days' : 'Custom',
            ),
            ('forever', 'Never'),
          ],
          selected: keep,
          reselect: keep == 'custom',
          onSelected: (choice) async {
            switch (choice) {
              case 'watched' || 'forever':
                await _setPolicy({'keep': choice});
              case 'days30':
                await _setPolicy({'keep': 'days', 'keepDays': 30});
              case 'custom':
                final days = await askNumber(
                  context,
                  title: 'Delete watched downloads after',
                  unit: 'days',
                  initial: current.keepDays,
                  min: 1,
                  max: 365,
                );
                if (days != null) {
                  await _setPolicy({'keep': 'days', 'keepDays': days});
                }
            }
          },
        ),
      ),
      SettingRow(
        label: 'Download next episode',
        hint:
            'Once an episode is on disk, the next one downloads, within the '
            'disk limit.',
        value: SettingSwitch(
          label: 'Download next episode',
          value: current.prefetch,
          onChanged: (on) => _setPolicy({'prefetch': on}),
        ),
      ),
    ];
  }

  /// The folder describes the core's machine, so opening or choosing one
  /// only makes sense when that machine is this one.
  Widget _videosRow(Preferences? current) {
    return FutureBuilder<CoreAbout>(
      future: widget.about,
      builder: (context, snapshot) {
        final dir = snapshot.data?.downloadDir ?? '';
        final local = widget.api.isLocal;
        return SettingRow(
          key: const ValueKey('settings:videos'),
          label: 'Videos',
          hint: 'New downloads go here; the ones already here stay.',
          value: dir.isEmpty
              ? Text(
                  snapshot.hasError ? errorMessage(snapshot.error!) : '…',
                  style: Typo.data,
                )
              : PathText(dir),
          trailing: Wrap(
            spacing: 8,
            children: [
              if (local && dir.isNotEmpty && Directory(dir).existsSync())
                RowButton(label: 'Open', onPressed: () => openFolder(dir)),
              if (local && current != null)
                RowButton(
                  label: 'Change',
                  onPressed: () => _changeDownloadDir(dir),
                ),
              if (current != null && current.downloadDir.isNotEmpty)
                RowButton(label: 'Default', onPressed: _defaultDownloadDir),
            ],
          ),
        );
      },
    );
  }

  Widget _screenshotsRow() {
    return FutureBuilder<String>(
      future: _pictures,
      builder: (context, snapshot) {
        final chosen = widget.settings.screenshotsDir;
        final dir = screenshotsFolder(
          pictures: snapshot.data ?? '',
          chosen: chosen,
        );
        return SettingRow(
          key: const ValueKey('settings:screenshots'),
          label: 'Screenshots',
          value: dir.isEmpty
              ? const Text('…', style: Typo.data)
              : PathText(dir),
          trailing: Wrap(
            spacing: 8,
            children: [
              if (dir.isNotEmpty && Directory(dir).existsSync())
                RowButton(label: 'Open', onPressed: () => openFolder(dir)),
              RowButton(
                label: 'Change',
                onPressed: () => _changeScreenshotsDir(dir),
              ),
              if (chosen.isNotEmpty)
                RowButton(
                  label: 'Default',
                  onPressed: () => widget.settings.screenshotsDir = '',
                ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _networkRows(Preferences current) {
    String rate(int bytes) => '${_mbs(bytes)} MB/s';
    Future<int?> ask(BuildContext context, String title, int now) async {
      final mb = await askNumber(
        context,
        title: title,
        unit: 'MB/s',
        initial: now == 0 ? 10 : (now / _mib).round().clamp(1, 1000),
        min: 1,
        max: 1000,
      );
      return mb == null ? null : mb * _mib;
    }

    return [
      SettingRow(
        label: 'Seeding',
        hint:
            'Giving back what you have. Off stops it once a download has '
            'what it needs; the upload limit caps it either way.',
        value: SettingSwitch(
          label: 'Seeding',
          value: current.seed,
          onChanged: (on) => widget.patch({'seed': on}),
        ),
      ),
      SettingRow(
        label: 'Upload limit',
        value: PresetChoice(
          presets: const [
            (0, 'No limit'),
            (_mib, '1 MB/s'),
            (5 * _mib, '5 MB/s'),
          ],
          value: current.uploadLimit,
          describe: rate,
          onSelected: (limit) => widget.patch({'uploadLimit': limit}),
          askCustom: (context) =>
              ask(context, 'Upload limit', current.uploadLimit),
        ),
      ),
      SettingRow(
        label: 'Download limit',
        value: PresetChoice(
          presets: const [
            (0, 'No limit'),
            (5 * _mib, '5 MB/s'),
            (20 * _mib, '20 MB/s'),
          ],
          value: current.downloadLimit,
          describe: rate,
          onSelected: (limit) => widget.patch({'downloadLimit': limit}),
          askCustom: (context) =>
              ask(context, 'Download limit', current.downloadLimit),
        ),
      ),
    ];
  }

  static String _mbs(int bytes) {
    final mb = bytes / _mib;
    return mb == mb.roundToDouble()
        ? mb.round().toString()
        : mb.toStringAsFixed(1);
  }

  Widget _onDisk(AsyncSnapshot<Storage> snapshot) {
    final storage = snapshot.data;
    final error = _actionError ?? snapshot.error;
    if (storage == null && error == null) return const SettingsLoading();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 28, bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const _SubHeading('On disk', padded: false),
              if (storage != null && storage.used > 0) ...[
                const SizedBox(width: 10),
                Text(formatBytes(storage.used), style: SettingsType.hint),
              ],
              const Spacer(),
              if (storage != null && storage.titles.isNotEmpty)
                RowButton(
                  label: 'Delete all',
                  onPressed: _freeing == null ? () => _freeAll(storage) : null,
                ),
            ],
          ),
        ),
        SettingRows([
          if (error != null) ErrorRow(error),
          if (storage != null && storage.titles.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('Nothing downloaded yet.', style: Typo.data),
            ),
          if (storage != null)
            for (final title in storage.titles)
              _TitleRow(
                title: title,
                freeing: _freeing == _keyFor(title),
                onFree: _freeing == null ? () => _free(title) : null,
              ),
          // No confirmation: the artwork downloads again as it is shown.
          if (storage != null && storage.cache > 0)
            SettingRow(
              label: 'Cached artwork',
              value: Text(
                formatBytes(storage.cache),
                style: SettingsType.value,
              ),
              trailing: RowButton(
                label: 'Clear',
                onPressed: _freeing == null
                    ? () => _act('cache', widget.api.clearCache)
                    : null,
              ),
            ),
        ]),
      ],
    );
  }
}

class _SubHeading extends StatelessWidget {
  const _SubHeading(this.text, {this.padded = true});

  final String text;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final label = Semantics(
      header: true,
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: Typo.sans,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Palette.text,
        ),
      ),
    );
    return padded
        ? Padding(
            padding: const EdgeInsets.only(top: 28, bottom: 4),
            child: label,
          )
        : label;
  }
}

/// The disk as one bar: Lumeo's share, everything else, what is free.
class _StorageBar extends StatelessWidget {
  const _StorageBar({required this.storage, required this.limit});

  final Storage storage;
  final int limit;

  @override
  Widget build(BuildContext context) {
    if (storage.diskTotal <= 0) {
      if (storage.used <= 0) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text('Lumeo ${formatBytes(storage.used)}', style: Typo.data),
      );
    }
    final used = storage.used.clamp(0, storage.diskTotal).toInt();
    final occupied = (storage.diskTotal - storage.diskFree)
        .clamp(used, storage.diskTotal)
        .toInt();
    final other = occupied - used;
    int share(int bytes) => (bytes / storage.diskTotal * 1000).round();
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      label:
          'Lumeo ${formatBytes(used)}, other ${formatBytes(other)}, '
          'free ${formatBytes(storage.diskFree)}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(5)),
                child: SizedBox(
                  height: 10,
                  child: Row(
                    children: [
                      if (used > 0)
                        Expanded(
                          flex: share(used).clamp(1, 1000),
                          child: ColoredBox(color: accent),
                        ),
                      if (used > 0 && other > 0) const SizedBox(width: 2),
                      if (other > 0)
                        Expanded(
                          flex: share(other).clamp(1, 1000),
                          child: const ColoredBox(color: Color(0xFF3A3B42)),
                        ),
                      const SizedBox(width: 2),
                      Expanded(
                        flex: share(storage.diskFree).clamp(1, 1000),
                        child: const ColoredBox(color: Palette.raised),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 20,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Lumeo ${formatBytes(used)}',
                          style: const TextStyle(
                            color: Palette.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (limit > 0)
                          TextSpan(text: ' of ${formatBytes(limit)}'),
                      ],
                    ),
                    style: SettingsType.hint,
                  ),
                  Text('Other ${formatBytes(other)}', style: SettingsType.hint),
                  Text(
                    'Free ${formatBytes(storage.diskFree)}',
                    style: SettingsType.hint,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({
    required this.title,
    required this.freeing,
    required this.onFree,
  });

  final StorageTitle title;
  final bool freeing;
  final VoidCallback? onFree;

  @override
  Widget build(BuildContext context) {
    final episodes = title.downloads.length;
    final detail = title.kind == 'movie'
        ? 'Film'
        : '$episodes ${episodes == 1 ? 'episode' : 'episodes'}';
    final active = title.downloads.any(
      (download) => download.state == 'active',
    );
    final item = MediaItem(
      id: title.itemId,
      kind: title.kind,
      title: title.title,
      poster: title.poster,
    );
    return Padding(
      key: ValueKey(
        'storage:${title.itemId.isNotEmpty ? title.itemId : title.title}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              height: 48,
              child: ClipRRect(
                borderRadius: const BorderRadius.all(
                  Radius.circular(Shape.art),
                ),
                child: PosterArtwork(item: item, width: 32, named: false),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title.title, style: Typo.cardTitle),
                  const SizedBox(height: 2),
                  Text(
                    active ? '$detail · downloading' : detail,
                    style: SettingsType.hint,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 80,
              child: Text(
                formatBytes(title.onDisk),
                textAlign: TextAlign.right,
                style: SettingsType.value,
              ),
            ),
            const SizedBox(width: 14),
            RowButton(
              label: freeing ? 'Deleting…' : 'Delete',
              onPressed: onFree,
            ),
          ],
        ),
      ),
    );
  }
}
