import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../api/client.dart';
import '../../../api/downloads_store.dart';
import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../../l10n/l10n.dart';
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
      message: context.l10n.settingsDeleteAllConfirm(
        formatBytes(storage.used, context.l10n),
      ),
      action: context.l10n.commonDelete,
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
      title: context.l10n.settingsDownloadFolderQuestion,
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
      title: context.l10n.settingsScreenshotsFolderQuestion,
      start: now,
    );
    if (chosen != null) widget.settings.screenshotsDir = chosen;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.preferences.current;
    return SettingsBlock(
      title: context.l10n.settingsDownloads,
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
            label: context.l10n.settingsFinishedPanel,
            value: Segments<String>(
              choices: [
                ('1d', context.l10n.settingsOneDay),
                ('7d', context.l10n.settingsSevenDays),
                ('cleared', context.l10n.settingsUntilCleared),
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
          _SubHeading(context.l10n.settingsNetwork),
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
    final limitTip = context.l10n.settingsDiskLimitTooltip;
    final keep = switch (current.keep) {
      'watched' => 'watched',
      'days' when current.keepDays == 30 => 'days30',
      'days' => 'custom',
      _ => 'forever',
    };
    return [
      SettingRow(
        label: context.l10n.settingsDiskLimit,
        hint: context.l10n.settingsDiskLimitHint,
        value: PresetChoice(
          presets: [
            (50 * _gib, context.l10n.settingsGigabytes(50)),
            (100 * _gib, context.l10n.settingsGigabytes(100)),
            (0, context.l10n.settingsNoLimit),
          ],
          tooltips: {50 * _gib: limitTip, 100 * _gib: limitTip},
          value: current.diskLimit,
          describe: (bytes) =>
              context.l10n.settingsGigabytes((bytes / _gib).round()),
          onSelected: (limit) => _setPolicy({'diskLimit': limit}),
          askCustom: (context) async {
            final gb = await askNumber(
              context,
              title: context.l10n.settingsDiskLimit,
              unit: context.l10n.settingsGigabyteUnit,
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
        label: context.l10n.settingsDeleteWatched,
        hint: context.l10n.settingsDeleteWatchedHint,
        value: Segments<String>(
          choices: [
            ('watched', context.l10n.settingsRightAway),
            ('days30', context.l10n.settingsAfterThirtyDays),
            (
              'custom',
              keep == 'custom'
                  ? context.l10n.settingsAfterDays(current.keepDays)
                  : context.l10n.commonCustom,
            ),
            ('forever', context.l10n.settingsNever),
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
                  title: context.l10n.settingsDeleteWatchedAfter,
                  unit: context.l10n.settingsDayUnit,
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
        label: context.l10n.settingsDownloadNextEpisode,
        hint: context.l10n.settingsDownloadNextEpisodeHint,
        value: SettingSwitch(
          label: context.l10n.settingsDownloadNextEpisode,
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
          label: context.l10n.settingsVideos,
          hint: context.l10n.settingsVideosHint,
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
                RowButton(
                  label: context.l10n.commonOpen,
                  onPressed: () => openFolder(dir),
                ),
              if (local && current != null)
                RowButton(
                  label: context.l10n.commonChange,
                  onPressed: () => _changeDownloadDir(dir),
                ),
              if (current != null && current.downloadDir.isNotEmpty)
                RowButton(
                  label: context.l10n.settingsDefault,
                  onPressed: _defaultDownloadDir,
                ),
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
          label: context.l10n.settingsScreenshots,
          value: dir.isEmpty
              ? const Text('…', style: Typo.data)
              : PathText(dir),
          trailing: Wrap(
            spacing: 8,
            children: [
              if (dir.isNotEmpty && Directory(dir).existsSync())
                RowButton(
                  label: context.l10n.commonOpen,
                  onPressed: () => openFolder(dir),
                ),
              RowButton(
                label: context.l10n.commonChange,
                onPressed: () => _changeScreenshotsDir(dir),
              ),
              if (chosen.isNotEmpty)
                RowButton(
                  label: context.l10n.settingsDefault,
                  onPressed: () => widget.settings.screenshotsDir = '',
                ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _networkRows(Preferences current) {
    String rate(int bytes) => context.l10n.settingsMegabytesPerSecond(
      _mbs(bytes, context.l10n.localeName),
    );
    Future<int?> ask(BuildContext context, String title, int now) async {
      final mb = await askNumber(
        context,
        title: title,
        unit: context.l10n.settingsMegabytesPerSecondUnit,
        initial: now == 0 ? 10 : (now / _mib).round().clamp(1, 1000),
        min: 1,
        max: 1000,
      );
      return mb == null ? null : mb * _mib;
    }

    return [
      SettingRow(
        label: context.l10n.settingsSeeding,
        hint: context.l10n.settingsSeedingHint,
        value: SettingSwitch(
          label: context.l10n.settingsSeeding,
          value: current.seed,
          onChanged: (on) => widget.patch({'seed': on}),
        ),
      ),
      SettingRow(
        label: context.l10n.settingsUploadLimit,
        value: PresetChoice(
          presets: [
            (0, context.l10n.settingsNoLimit),
            (_mib, context.l10n.settingsMegabytesPerSecond('1')),
            (5 * _mib, context.l10n.settingsMegabytesPerSecond('5')),
          ],
          value: current.uploadLimit,
          describe: rate,
          onSelected: (limit) => widget.patch({'uploadLimit': limit}),
          askCustom: (context) => ask(
            context,
            context.l10n.settingsUploadLimit,
            current.uploadLimit,
          ),
        ),
      ),
      SettingRow(
        label: context.l10n.settingsDownloadLimit,
        value: PresetChoice(
          presets: [
            (0, context.l10n.settingsNoLimit),
            (5 * _mib, context.l10n.settingsMegabytesPerSecond('5')),
            (20 * _mib, context.l10n.settingsMegabytesPerSecond('20')),
          ],
          value: current.downloadLimit,
          describe: rate,
          onSelected: (limit) => widget.patch({'downloadLimit': limit}),
          askCustom: (context) => ask(
            context,
            context.l10n.settingsDownloadLimit,
            current.downloadLimit,
          ),
        ),
      ),
    ];
  }

  static String _mbs(int bytes, String locale) {
    final mb = bytes / _mib;
    return mb == mb.roundToDouble()
        ? NumberFormat.decimalPattern(locale).format(mb.round())
        : NumberFormat('0.0', locale).format(mb);
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
              _SubHeading(context.l10n.downloadsOnDisk, padded: false),
              if (storage != null && storage.used > 0) ...[
                const SizedBox(width: 10),
                Text(
                  formatBytes(storage.used, context.l10n),
                  style: SettingsType.hint,
                ),
              ],
              const Spacer(),
              if (storage != null && storage.titles.isNotEmpty)
                RowButton(
                  label: context.l10n.settingsDeleteAll,
                  onPressed: _freeing == null ? () => _freeAll(storage) : null,
                ),
            ],
          ),
        ),
        SettingRows([
          if (error != null) ErrorRow(error),
          if (storage != null && storage.titles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                context.l10n.settingsNothingDownloaded,
                style: Typo.data,
              ),
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
              label: context.l10n.settingsCachedArtwork,
              value: Text(
                formatBytes(storage.cache, context.l10n),
                style: SettingsType.value,
              ),
              trailing: RowButton(
                label: context.l10n.commonClear,
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
        child: Text(
          context.l10n.settingsStorageLumeo(
            formatBytes(storage.used, context.l10n),
          ),
          style: Typo.data,
        ),
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
      label: context.l10n.settingsStorageSemantics(
        formatBytes(used, context.l10n),
        formatBytes(other, context.l10n),
        formatBytes(storage.diskFree, context.l10n),
      ),
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
                          text: context.l10n.settingsStorageLumeo(
                            formatBytes(used, context.l10n),
                          ),
                          style: const TextStyle(
                            color: Palette.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (limit > 0)
                          TextSpan(
                            text: context.l10n.settingsStorageOf(
                              formatBytes(limit, context.l10n),
                            ),
                          ),
                      ],
                    ),
                    style: SettingsType.hint,
                  ),
                  Text(
                    context.l10n.settingsStorageOther(
                      formatBytes(other, context.l10n),
                    ),
                    style: SettingsType.hint,
                  ),
                  Text(
                    context.l10n.settingsStorageFree(
                      formatBytes(storage.diskFree, context.l10n),
                    ),
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
        ? context.l10n.commonFilm
        : context.l10n.settingsEpisodeCount(episodes);
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
                    active
                        ? context.l10n.settingsDetailDownloading(detail)
                        : detail,
                    style: SettingsType.hint,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 80,
              child: Text(
                formatBytes(title.onDisk, context.l10n),
                textAlign: TextAlign.right,
                style: SettingsType.value,
              ),
            ),
            const SizedBox(width: 14),
            RowButton(
              label: freeing
                  ? context.l10n.settingsDeleting
                  : context.l10n.commonDelete,
              onPressed: onFree,
            ),
          ],
        ),
      ),
    );
  }
}
