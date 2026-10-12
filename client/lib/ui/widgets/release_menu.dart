import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../screens/settings/folder_dialog.dart';
import '../theme.dart';
import 'play_block.dart';
import 'source_list.dart';

/// Which release a title plays from: the best copy, which is the default and
/// comes first; its releases on disk; the packs its providers offer for the
/// current episode; every copy of it; or a folder (a film's file) on this
/// machine. Films and series share it, a film being a title of one episode.
///
/// A pick is the title's, kept by the core, so the next episode continues
/// from the same release on every machine.
class ReleaseMenu extends StatefulWidget {
  const ReleaseMenu({
    super.key,
    required this.choice,
    required this.episodes,
    required this.builder,
  });

  final SourceChoice choice;

  /// The title's episodes: what "13 of 26" counts against. None for a film.
  final List<Episode> episodes;

  /// The button, given what opens and closes the menu.
  final Widget Function(BuildContext context, VoidCallback toggle) builder;

  @override
  State<ReleaseMenu> createState() => _ReleaseMenuState();
}

class _ReleaseMenuState extends State<ReleaseMenu> {
  final _menu = MenuController();

  /// Asked for each time the menu opens: a download may have finished since.
  TitleFolders? _folders;

  SourceChoice get _choice => widget.choice;

  bool get _film => widget.episodes.isEmpty;

  void _toggle() {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    _menu.open();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    try {
      final folders = await _choice.api.folders(_choice.itemId);
      if (mounted) setState(() => _folders = folders);
    } on Object {
      // The menu still offers the packs and the table without them.
      if (mounted) setState(() => _folders = null);
    }
  }

  Future<void> _pick(MediaSource? source) async {
    try {
      await _choice.api.chooseSource(_choice.itemId, source);
    } on Object catch (e) {
      if (mounted) _say(context.l10n.itemReleaseNotChosen(_reason(e)));
      return;
    }
    await _choice.load(follow: source != null);
  }

  Future<void> _linkHere() async {
    final l10n = context.l10n;
    final start =
        _folders?.folders
            .map((f) => f.dir)
            .firstWhere((d) => d.isNotEmpty, orElse: () => '') ??
        '';
    final path = _film
        ? await chooseFile(
            context,
            title: l10n.itemReleaseFileTitle,
            start: start,
          )
        : await chooseFolder(
            context,
            title: l10n.itemReleaseFolderTitle,
            start: start,
          );
    if (path == null) return;
    try {
      await _choice.api.linkFolder(_choice.itemId, path);
    } on Object catch (e) {
      _say(
        e is LumeoApiException && e.status == 422
            ? l10n.itemReleaseFolderEmpty
            : l10n.itemReleaseNotChosen(_reason(e)),
      );
      return;
    }
    await _choice.load(follow: true);
  }

  /// The core's own words when it answered, not the exception's dump.
  static String _reason(Object e) =>
      e is LumeoApiException ? e.message : e.toString();

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 6),
      menuChildren: _items(context),
      builder: (context, _, _) => widget.builder(context, _toggle),
    );
  }

  List<Widget> _items(BuildContext context) {
    final l10n = context.l10n;
    final folders = _folders;
    final onDisk = folders?.folders ?? const <DiskFolder>[];
    final sources = _choice.sources ?? const <MediaSource>[];
    final offered = _offered(sources);
    return [
      MenuItemButton(
        leadingIcon: _Check(on: folders != null && !folders.chosen),
        onPressed: () => _pick(null),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.itemReleaseAutomatic),
            Text(
              _film ? l10n.itemReleaseBestFilm : l10n.itemReleaseBest,
              style: Typo.data.copyWith(color: Palette.muted),
            ),
          ],
        ),
      ),
      const Divider(height: 13),
      if (onDisk.isNotEmpty) _Heading(l10n.downloadsOnDisk),
      for (final f in onDisk)
        MenuItemButton(
          leadingIcon: _Check(on: f.current),
          trailingIcon: _Facts([
            if (f.directorsCut) l10n.downloadsDirectorsCut,
            if (!_film) _have(f, l10n),
          ]),
          onPressed: () => _pick(f.source),
          child: Text(_folderName(f, l10n)),
        ),
      _Heading(l10n.itemReleaseAvailable),
      if (offered.isNotEmpty)
        for (final s in offered)
          MenuItemButton(
            leadingIcon: _Check(on: s.lastUsed),
            trailingIcon: _Facts([
              if (_film && s.size > 0) formatBytes(s.size, l10n),
              if (s.seeders > 0) l10n.downloadsSeedCount(s.seeders),
            ]),
            onPressed: () => _pick(s),
            child: Text(_releaseName(s, s.packFolder, l10n)),
          )
      else
        _why(context),
      const Divider(height: 13),
      // Not when every copy is already a row under On disk.
      if (sources.any((s) => s.local.isEmpty && s.providerId != 'local'))
        MenuItemButton(
          leadingIcon: const _Check(on: false),
          trailingIcon: _Facts(['${sources.length}']),
          onPressed: () => showSources(context, _choice),
          child: Text(
            _film
                ? l10n.itemReleaseAllCopiesFilm
                : l10n.itemReleaseAllCopies(_choice.episode),
          ),
        ),
      // The core reads the folder, so it has to be on the machine browsed.
      if (_choice.api.isLocal)
        MenuItemButton(
          leadingIcon: const _Check(on: false),
          onPressed: _linkHere,
          child: Text(_film ? l10n.itemReleaseFile : l10n.itemReleaseFolder),
        ),
    ];
  }

  /// Why no pack is offered, and what can be done about it.
  Widget _why(BuildContext context) {
    final l10n = context.l10n;
    if (_choice.providers == 0) {
      return MenuItemButton(
        leadingIcon: const _Check(on: false),
        trailingIcon: _Facts([l10n.playerAddSource]),
        onPressed: _choice.onAddSource,
        child: Text(l10n.playerNoSourceAddons),
      );
    }
    final empty = emptySources(
      failed: _choice.failed,
      released: _choice.released,
      now: DateTime.now(),
      l10n: l10n,
    );
    return MenuItemButton(
      leadingIcon: const _Check(on: false),
      trailingIcon: empty.retry ? _Facts([l10n.commonTryAgain]) : null,
      onPressed: empty.retry ? _choice.load : null,
      child: Text(empty.text),
    );
  }

  /// The best copy of each pack the providers offer for this episode, three
  /// at most: a pack is a choice, its copies are the table's business.
  static List<MediaSource> _offered(List<MediaSource> sources) {
    final seen = <String>{};
    final out = <MediaSource>[];
    for (final s in sources) {
      if (s.local.isNotEmpty || s.providerId == 'local') continue;
      final pack = s.bingeGroup.isNotEmpty
          ? s.bingeGroup
          : '${s.locator['infoHash'] ?? s.rawName}';
      if (!seen.add('$pack\u0000${s.packFolder}')) continue;
      out.add(s);
      if (out.length == 3) break;
    }
    return out;
  }

  String _folderName(DiskFolder f, AppLocalizations l10n) {
    if (f.dir.isNotEmpty) {
      final parts = f.dir.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
      return parts.skip(parts.length > 2 ? parts.length - 2 : 0).join(' › ');
    }
    return _releaseName(f.source, f.folder, l10n);
  }

  /// A release as the menu tells it from the others: two packs of one group
  /// differ by their resolution, two folders of one pack by the folder.
  static String _releaseName(
    MediaSource s,
    String folder,
    AppLocalizations l10n,
  ) => [
    sourceTitle(s, l10n),
    s.release.resolution,
    folder,
  ].where((e) => e.isNotEmpty).join(' · ');

  /// How many of the released episodes of its seasons the folder holds.
  String _have(DiskFolder f, AppLocalizations l10n) {
    final seasons = f.episodes.map((e) => e.season).toSet();
    final total = widget.episodes
        .where((e) => seasons.contains(e.season) && !e.isUpcoming)
        .length;
    return total < f.episodes.length
        ? '${f.episodes.length}'
        : l10n.itemReleaseHave(f.episodes.length, total);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
    child: Text(text, style: Typo.data.copyWith(color: Palette.muted)),
  );
}

/// Keeps every row's text in one column, ticked or not.
class _Check extends StatelessWidget {
  const _Check({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 18,
    child: on ? const Icon(Icons.check, size: 18) : null,
  );
}

class _Facts extends StatelessWidget {
  const _Facts(this.facts);

  final List<String> facts;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 24),
    child: Text(
      facts.where((f) => f.isNotEmpty).join(' · '),
      style: Typo.data.copyWith(color: Palette.muted),
    ),
  );
}
