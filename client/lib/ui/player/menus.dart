import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../api/languages.dart';
import '../../api/models.dart' as api;
import '../theme.dart';
import '../widgets/play_block.dart';
import '../widgets/source_list.dart'
    show formatBytes, formatTimeLeft, languageCodes, localLabel, sourceTitle;
import 'bindings.dart';
import 'chapters.dart';
import 'chrome.dart' show clock;
import 'tracks.dart';

const _dim = Color(0x80FFFFFF);
const _other = Color(0xCCFFFFFF);
const _hover = Color(0x14FFFFFF);

class MenuPanel extends StatelessWidget {
  const MenuPanel({super.key, required this.child, this.width = 280});
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 12,
    child: Container(
      width: width,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height - 92,
      ),
      child: TooltipTheme(
        data: const TooltipThemeData(waitDuration: Duration.zero),
        child: Material(
          color: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// The surface everything floating over the picture sits on: menus, the
/// next-episode card, the scrubber's time.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.radius, required this.child});
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: ColoredBox(color: const Color(0xB81C1C1C), child: child),
    ),
  );
}

class MenuList extends StatelessWidget {
  const MenuList({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

class MenuLabel extends StatelessWidget {
  const MenuLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                letterSpacing: 0.72,
                color: Color(0x8CFFFFFF),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

/// A status line, with a retry beside it when there is one. The retry is a
/// button of its own: a status set as a menu row read as one more choice.
class MenuNote extends StatelessWidget {
  const MenuNote(this.text, {super.key, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, onTap == null ? 16 : 8, 12, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: onTap == null ? _other : _dim,
              fontSize: onTap == null ? 14 : 12,
            ),
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Search again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0x4DFFFFFF)),
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ],
    ),
  );
}

class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.label,
    required this.current,
    required this.onTap,
    this.detail = '',
    this.trailing,
    this.indent = false,
    this.closes = true,
    this.height = 40,
    this.check = true,
    this.note = '',
    this.leading,
  });
  final String label;
  final String detail;

  /// An action's icon, where a choice has its check.
  final Widget? leading;

  /// A second, smaller line under the label.
  final String note;
  final Widget? trailing;
  final bool current;
  final bool indent;
  final bool closes;
  final bool check;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: MenuItemButton(
      onPressed: onTap,
      closeOnActivate: closes,
      // Lets the label fill the row, so the detail sits at the right edge.
      overflowAxis: Axis.vertical,
      style: MenuItemButton.styleFrom(
        minimumSize: Size(0, height),
        padding: EdgeInsets.fromLTRB(indent ? 28 : 12, 0, 12, 0),
        foregroundColor: Colors.white,
        backgroundColor: Colors.transparent,
        overlayColor: _hover,
        shape: const RoundedRectangleBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        children: [
          if (check)
            SizedBox(
              width: 18,
              child: current
                  ? const Icon(Icons.check, size: 18, color: Colors.white)
                  : null,
            ),
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            flex: 3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: current ? Colors.white : _other,
                    fontWeight: current ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                if (note.isNotEmpty)
                  Text(
                    note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _dim),
                  ),
              ],
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 12, color: _dim),
              ),
            ),
          ],
          ?trailing,
        ],
      ),
    ),
  );
}

/// A page's title row, which goes back to the list it came from.
class MenuBack extends StatelessWidget {
  const MenuBack(this.label, this.onTap, {super.key});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MenuItemButton(
        onPressed: onTap,
        closeOnActivate: false,
        overflowAxis: Axis.vertical,
        leadingIcon: const Icon(Icons.chevron_left, size: 20),
        style: MenuItemButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          iconColor: Colors.white,
          overlayColor: _hover,
          shape: const RoundedRectangleBorder(),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      const Divider(height: 9, color: Color(0x1FFFFFFF)),
    ],
  );
}

class TracksMenu extends StatefulWidget {
  const TracksMenu({
    super.key,
    required this.audio,
    required this.subtitles,
    required this.found,
    required this.languages,
    required this.preferredSubtitles,
    required this.looking,
    required this.error,
    required this.delay,
    required this.scale,
    required this.position,
    required this.url,
    required this.onAudio,
    required this.onSubtitle,
    required this.onFound,
    required this.onRetry,
    required this.onDelay,
    required this.onScale,
    required this.onPosition,
    required this.background,
    required this.onBackground,
  });
  static const width = 520.0;
  static const scales = [0.8, 1.0, 1.25, 1.5];
  static const scaleLabels = ['Small', 'Normal', 'Large', 'Larger'];
  final List<MpvTrack> audio;
  final List<MpvTrack> subtitles;
  final List<api.Subtitle> found;
  final Languages languages;
  final List<String> preferredSubtitles;
  final bool looking;
  final Object? error;
  final double delay;
  final double scale;
  final double position;
  final String Function(String) url;
  final void Function(MpvTrack) onAudio;
  final void Function(MpvTrack?) onSubtitle;
  final void Function(api.Subtitle) onFound;
  final VoidCallback onRetry;
  final void Function(double) onDelay;
  final void Function(double) onScale;
  final void Function(double) onPosition;
  final String background;
  final void Function(String) onBackground;

  @override
  State<TracksMenu> createState() => _TracksMenuState();
}

class _TracksMenuState extends State<TracksMenu> {
  late String _expanded = _expandedAtStart;
  bool _style = false;

  MpvTrack? get _selectedSubtitle =>
      widget.subtitles.where((t) => t.selected).firstOrNull;

  List<MpvTrack> get _embedded {
    final tracks = widget.subtitles.where((t) => !t.external).indexed.toList();
    int rank(MpvTrack t) {
      final r = widget.languages.rank(t.language, widget.preferredSubtitles);
      return r < 0 ? widget.preferredSubtitles.length : r;
    }

    tracks.sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
    return [for (final (_, t) in tracks) t];
  }

  Map<String, List<api.Subtitle>> get _foundByLanguage {
    final groups = <String, List<api.Subtitle>>{};
    for (final sub in widget.found) {
      groups.putIfAbsent(_base(sub.language), () => []).add(sub);
    }
    return groups;
  }

  String _base(String tag) {
    final code = widget.languages.canonical(tag);
    final dash = code.indexOf('-');
    return dash > 0 ? code.substring(0, dash) : code;
  }

  bool _isLoaded(api.Subtitle sub) {
    final selected = _selectedSubtitle;
    return selected != null &&
        selected.external &&
        sub.url.isNotEmpty &&
        selected.externalFilename == widget.url(sub.url);
  }

  String get _expandedAtStart {
    final inFile = {for (final t in _embedded) _base(t.language)};
    for (final sub in widget.found) {
      final base = _base(sub.language);
      if (_isLoaded(sub) && inFile.contains(base)) return base;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) => _style
      ? _stylePage()
      : MenuPanel(
          width: TracksMenu.width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(child: _columns()),
              ?_searchNote(),
            ],
          ),
        );

  Widget _columns() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MenuLabel('Audio'),
            Flexible(child: MenuList(children: _audioRows())),
          ],
        ),
      ),
      const SizedBox(width: 1, child: ColoredBox(color: Color(0x30FFFFFF))),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MenuLabel(
              'Subtitles',
              trailing: IconButton(
                tooltip: 'Subtitle style',
                onPressed: () => setState(() => _style = true),
                icon: const Icon(Icons.tune, size: 18, color: Colors.white),
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
            Flexible(child: MenuList(children: _subtitleRows())),
          ],
        ),
      ),
    ],
  );

  /// Under both columns rather than at the end of one: it is about the
  /// search, not one more subtitle to pick.
  Widget? _searchNote() {
    if (widget.looking) return null;
    final String text;
    if (widget.error != null) {
      text = 'No answer from the core';
    } else if (widget.found.isEmpty) {
      text = _embedded.isEmpty
          ? 'OpenSubtitles has nothing for this file'
          : 'OpenSubtitles has nothing else for this file';
    } else {
      return null;
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: MenuNote(text, onTap: widget.onRetry),
    );
  }

  List<Widget> _audioRows() => widget.audio.isEmpty
      ? const [MenuNote('No sound in this file')]
      : [
          for (final track in widget.audio)
            MenuRow(
              label: track.title.isEmpty
                  ? _trackLabel(track)
                  : '${_trackLabel(track)} · ${track.title}',
              detail: track.channels > 0 ? _channels(track.channels) : '',
              height: 36,
              current: track.selected,
              onTap: () => widget.onAudio(track),
            ),
        ];

  List<Widget> _subtitleRows() {
    final embedded = _embedded;
    final groups = _foundByLanguage;
    final inFile = {for (final t in embedded) _base(t.language)};
    final rows = <Widget>[
      MenuRow(
        label: 'Off',
        current: _selectedSubtitle == null,
        height: 36,
        onTap: () => widget.onSubtitle(null),
      ),
    ];
    final counted = <String>{};
    for (final track in embedded) {
      final base = _base(track.language);
      final others = counted.add(base)
          ? groups[base] ?? const <api.Subtitle>[]
          : const <api.Subtitle>[];
      rows.add(
        MenuRow(
          label: _trackLabel(track),
          detail: _subtitleDetail(track),
          current: track.selected,
          height: 36,
          trailing: others.isEmpty ? null : _more(base, others.length),
          onTap: () => widget.onSubtitle(track),
        ),
      );
      if (_expanded == base) rows.addAll(_alternatives(others));
    }
    for (final entry in groups.entries) {
      if (inFile.contains(entry.key)) continue;
      final best = entry.value.first;
      final others = entry.value.skip(1).toList();
      rows.add(
        MenuRow(
          label: best.label,
          detail: 'OpenSubtitles',
          current: _isLoaded(best),
          height: 36,
          trailing: others.isEmpty ? null : _more(entry.key, others.length),
          onTap: () => widget.onFound(best),
        ),
      );
      if (_expanded == entry.key) rows.addAll(_alternatives(others));
    }
    if (widget.looking) rows.add(const MenuNote('Looking…'));
    return rows;
  }

  Iterable<Widget> _alternatives(List<api.Subtitle> subs) => [
    for (final sub in subs)
      MenuRow(
        label: sub.name.isEmpty ? sub.label : sub.name,
        detail: 'OpenSubtitles',
        current: _isLoaded(sub),
        height: 36,
        indent: true,
        onTap: () => widget.onFound(sub),
      ),
  ];

  Widget _more(String language, int count) {
    final open = _expanded == language;
    return TextButton(
      onPressed: () => setState(() => _expanded = open ? '' : language),
      style: TextButton.styleFrom(
        foregroundColor: _dim,
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text('$count more', style: const TextStyle(fontSize: 12)),
    );
  }

  String _trackLabel(MpvTrack track) {
    final name = widget.languages.name(track.language);
    if (name.isNotEmpty) return name;
    if (track.language.isNotEmpty && track.language != 'und') {
      return track.language.toUpperCase();
    }
    return track.title.isNotEmpty ? track.title : 'Track ${track.id}';
  }

  String _subtitleDetail(MpvTrack track) {
    final title = track.title;
    if (title.isNotEmpty &&
        title.toLowerCase() != _trackLabel(track).toLowerCase()) {
      return title;
    }
    return track.forced ? 'Forced' : '';
  }

  static String _channels(int count) => switch (count) {
    1 => '1.0',
    2 => '2.0',
    6 => '5.1',
    8 => '7.1',
    _ => '$count ch',
  };

  Widget _stylePage() => MenuPanel(
    width: 340,
    child: MenuList(
      children: [
        MenuBack('Subtitle style', () => setState(() => _style = false)),
        _styleLine(
          'Size',
          _choices([
            for (final (i, label) in ['S', 'M', 'L', 'XL'].indexed)
              (
                label,
                (widget.scale - TracksMenu.scales[i]).abs() < 0.01,
                () => widget.onScale(TracksMenu.scales[i]),
              ),
          ]),
        ),
        _styleLine(
          'Position',
          _stepper(
            widget.position >= 100
                ? 'bottom'
                : '${(100 - widget.position).round()}% up',
            () => widget.onPosition((widget.position + 5).clamp(70, 100)),
            () => widget.onPosition((widget.position - 5).clamp(70, 100)),
          ),
        ),
        _styleLine(
          'Timing',
          _stepper(
            widget.delay == 0
                ? 'in sync'
                : '${widget.delay > 0 ? '+' : ''}${widget.delay.toStringAsFixed(1)} s',
            () => widget.onDelay(widget.delay - 0.1),
            () => widget.onDelay(widget.delay + 0.1),
          ),
        ),
        _styleLine(
          'Background',
          _choices([
            for (final (value, label) in [
              ('none', 'None'),
              ('shadow', 'Shadow'),
              ('box', 'Box'),
            ])
              (
                label,
                widget.background == value,
                () => widget.onBackground(value),
              ),
          ]),
        ),
      ],
    ),
  );

  Widget _choices(List<(String, bool, VoidCallback)> choices) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (label, on, pick) in choices)
        TextButton(
          onPressed: pick,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: on ? const Color(0x2EFFFFFF) : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            minimumSize: const Size(36, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(label),
        ),
    ],
  );

  Widget _styleLine(String label, Widget control) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          control,
        ],
      ),
    ),
  );

  Widget _stepper(String value, VoidCallback less, VoidCallback more) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        onPressed: less,
        icon: const Icon(Icons.remove, size: 18, color: Colors.white),
      ),
      SizedBox(
        width: 80,
        child: Text(
          value,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
      IconButton(
        onPressed: more,
        icon: const Icon(Icons.add, size: 18, color: Colors.white),
      ),
    ],
  );
}

class SettingsMenu extends StatefulWidget {
  const SettingsMenu({
    super.key,
    required this.rate,
    required this.fit,
    this.chapters = const [],
    this.chapter,
    this.shortcuts,
    required this.onRate,
    required this.onFit,
    this.onChapter,
    required this.onShortcuts,
    required this.onStats,
    this.hardware = 'auto-safe',
    this.decoding = 'Hardware',
    this.onDecoding,
    this.sources,
    this.current = '',
    this.onSource,
    this.page = '',
  });
  static const width = 280.0;
  static const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  static const fits = ['Fit', 'Fill', 'Stretch'];
  final double rate;
  final int fit;
  final List<MpvChapter> chapters;
  final int? chapter;
  final List<Shortcut>? shortcuts;
  final void Function(double) onRate;
  final void Function(int) onFit;
  final void Function(int)? onChapter;
  final VoidCallback onShortcuts;
  final VoidCallback onStats;
  final String hardware;
  final String decoding;
  final void Function(String)? onDecoding;

  /// This episode's copies, in the core's order (on disk first).
  final SourceChoice? sources;

  /// The playing download's name, which is the copy's release name.
  final String current;
  final void Function(api.MediaSource)? onSource;

  /// The page it opens on; the main list when empty.
  final String page;

  static String sourceLabel(api.MediaSource source) => [
    if (source.release.resolution.isNotEmpty) source.release.resolution,
    sourceTitle(source),
  ].where((e) => e.isNotEmpty).join(' · ');

  static String sourceNote(api.MediaSource source) => [
    if (source.local.isNotEmpty) localLabel(source),
    languageCodes(source).join(' '),
    if (source.lastUsed) 'last used',
  ].where((e) => e.isNotEmpty).join(' · ');

  bool _playing(api.MediaSource s) =>
      s.rawName == current || s.filename == current;

  static String label(double rate) => rate == 1
      ? 'Normal'
      : '${rate.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}×';

  @override
  State<SettingsMenu> createState() => _SettingsMenuState();
}

class _SettingsMenuState extends State<SettingsMenu> {
  late String _page = widget.page;

  @override
  Widget build(BuildContext context) => MenuPanel(
    width: _page == 'Speed'
        ? 240
        : _page == 'Source'
        ? 340
        : SettingsMenu.width,
    child: _page.isEmpty
        ? MenuList(key: const ValueKey('main'), children: _main())
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MenuBack(_page, () => setState(() => _page = '')),
              Flexible(
                child: MenuList(key: ValueKey(_page), children: _subpage()),
              ),
            ],
          ),
  );

  List<Widget> _main() => [
    if (widget.sources != null)
      _open('Source', switch (widget.sources!.sources
          ?.where(widget._playing)
          .firstOrNull) {
        final s? => SettingsMenu.sourceLabel(s),
        null => '',
      }),
    _open('Speed', SettingsMenu.label(widget.rate)),
    _open('Picture', SettingsMenu.fits[widget.fit]),
    if (widget.chapters.isNotEmpty)
      _open(
        'Chapters',
        widget.chapter == null || widget.chapter! >= widget.chapters.length
            ? ''
            : chapterLabel(widget.chapters, widget.chapter!),
      ),
    _open('Decoding', widget.decoding),
    const Divider(height: 1, color: Color(0x30FFFFFF)),
    MenuRow(
      label: 'Statistics',
      detail: 'I',
      current: false,
      check: false,
      onTap: widget.onStats,
    ),
    _open('Keyboard shortcuts', '?'),
  ];

  Widget _open(String label, String value) => MenuRow(
    label: label,
    detail: value,
    current: false,
    check: false,
    closes: false,
    trailing: const Icon(Icons.chevron_right, size: 20, color: _dim),
    onTap: () {
      if (label == 'Keyboard shortcuts') widget.onShortcuts();
      setState(() => _page = label);
    },
  );

  List<Widget> _subpage() => [
    if (_page == 'Source')
      if (widget.sources?.sources case final sources?)
        if (sources.isEmpty)
          const MenuNote('No copies for this episode')
        else
          for (final source in sources)
            MenuRow(
              label: SettingsMenu.sourceLabel(source),
              note: SettingsMenu.sourceNote(source),
              height: 52,
              detail: [
                if (source.size > 0) formatBytes(source.size),
                if (source.seeders > 0) '${source.seeders} seeds',
              ].join(' · '),
              current: widget._playing(source),
              onTap: () {
                if (!widget._playing(source)) widget.onSource?.call(source);
              },
            )
      else if (widget.sources?.error != null)
        MenuNote('Sources unavailable', onTap: widget.sources!.load)
      else
        const MenuNote('Looking for sources…'),
    if (_page == 'Speed')
      for (final rate in SettingsMenu.rates)
        MenuRow(
          label: SettingsMenu.label(rate),
          current: widget.rate == rate,
          closes: false,
          onTap: () => widget.onRate(rate),
        ),
    if (_page == 'Picture')
      for (final (i, fit) in SettingsMenu.fits.indexed)
        MenuRow(
          label: fit,
          current: widget.fit == i,
          closes: false,
          onTap: () => widget.onFit(i),
        ),
    if (_page == 'Chapters')
      for (final (i, chapter) in widget.chapters.indexed)
        MenuRow(
          label: chapterLabel(widget.chapters, i),
          detail: clock(chapter.time),
          current: widget.chapter == i,
          closes: false,
          onTap: () => widget.onChapter?.call(i),
        ),
    if (_page == 'Decoding') ...[
      MenuRow(
        label: 'Hardware',
        current: widget.decoding == 'Hardware',
        closes: false,
        onTap: () => widget.onDecoding?.call(widget.hardware),
      ),
      MenuRow(
        label: 'Software',
        current: widget.decoding == 'Software',
        closes: false,
        onTap: () => widget.onDecoding?.call('no'),
      ),
    ],
    if (_page == 'Keyboard shortcuts')
      if (widget.shortcuts == null)
        const MenuNote('Asking mpv…')
      else if (widget.shortcuts!.isEmpty)
        const MenuNote('mpv has no bindings to list')
      else
        for (final line in widget.shortcuts!)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 100,
                  child: Text(
                    line.keys.join(', '),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Text(
                    line.what,
                    style: const TextStyle(color: _other, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
  ];
}

class MenuStepper extends StatelessWidget {
  const MenuStepper({
    super.key,
    required this.value,
    required this.onLess,
    required this.onMore,
    this.onReset,
  });
  final String value;
  final VoidCallback onLess;
  final VoidCallback onMore;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      fixedSize: const Size(28, 24),
      minimumSize: const Size(28, 24),
      padding: EdgeInsets.zero,
      backgroundColor: Palette.raised,
      foregroundColor: Colors.white,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Row(
      children: [
        IconButton(
          onPressed: onLess,
          icon: const Icon(Icons.remove, size: 14),
          style: style,
        ),
        const SizedBox(width: 6),
        IconButton(
          onPressed: onMore,
          icon: const Icon(Icons.add, size: 14),
          style: style,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(value, style: Typo.dataStrong)),
        if (onReset != null)
          TextButton(
            onPressed: onReset,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Reset'),
          ),
      ],
    );
  }
}

/// Why the next episode has no download yet.
enum NextFetch { waiting, off, noRoom, noCopy, failed }

/// The panel behind the download button: how this file is arriving and, in a
/// series, what the prefetch is doing with the next one.
class DownloadPanel extends StatelessWidget {
  const DownloadPanel({
    super.key,
    required this.download,
    this.source = '',
    this.onSource,
    this.next,
    this.nextDownload,
    this.nextFetch = NextFetch.waiting,
    this.onDownloadNext,
    this.onStorage,
  });
  static const width = 340.0;

  final api.Download download;

  /// The playing copy as the Source page names it; the release name until
  /// the source list has arrived.
  final String source;
  final VoidCallback? onSource;
  final api.Episode? next;
  final api.Download? nextDownload;
  final NextFetch nextFetch;
  final VoidCallback? onDownloadNext;
  final VoidCallback? onStorage;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final next = this.next;
    final nextName = next == null
        ? ''
        : [
            'E${next.number}',
            api.realTitle(next.number, next.title),
          ].where((part) => part.isNotEmpty).join(' ');
    return MenuPanel(
      width: width,
      child: MenuList(
        children: [
          _Caption(download.episode > 0 ? 'This episode' : 'This film'),
          ..._state(download, accent, detailed: true),
          if (onSource != null)
            MenuRow(
              label: source.isEmpty ? download.name : source,
              detail: 'Source',
              current: false,
              check: false,
              closes: false,
              trailing: const Icon(Icons.chevron_right, size: 20, color: _dim),
              onTap: onSource!,
            ),
          if (next != null) ...[
            const Divider(height: 17, color: Color(0x1FFFFFFF)),
            _Caption('Next · $nextName'),
            if (nextDownload case final d?) ...[
              ..._state(d, accent),
              if (d.state == 'failed') _action('Download now', onDownloadNext),
            ] else
              ...switch (nextFetch) {
                NextFetch.waiting => [
                  const _Line('Waiting'),
                  _action('Download now', onDownloadNext),
                ],
                NextFetch.off => [_action('Download now', onDownloadNext)],
                NextFetch.noRoom => [
                  const _Line('No room'),
                  _action('Download anyway', onDownloadNext),
                  if (onStorage != null)
                    _action('Storage settings', onStorage, Icons.storage),
                ],
                NextFetch.noCopy => [const _Line('No copies')],
                NextFetch.failed => [
                  const _Line('Failed'),
                  _action('Download now', onDownloadNext),
                ],
              },
          ],
        ],
      ),
    );
  }

  static Widget _action(
    String label,
    VoidCallback? onTap, [
    IconData icon = Icons.download,
  ]) => MenuRow(
    label: label,
    leading: Icon(icon, size: 18, color: _other),
    current: false,
    check: false,
    closes: false,
    onTap: onTap ?? () {},
  );

  static List<Widget> _state(
    api.Download d,
    Color accent, {
    bool detailed = false,
  }) {
    final p = d.progress;
    switch (d.state) {
      case 'done':
        return [_Line('On disk', value: formatBytes(p.total), done: true)];
      case 'active':
        final left = p.rate > 0
            ? 'about ${formatTimeLeft((p.total - p.completed) ~/ p.rate)}'
            : '';
        return [
          _Line('Downloading', value: '${(p.fraction * 100).round()} %'),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: LinearProgressIndicator(
              value: p.fraction,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              color: accent,
              backgroundColor: const Color(0x2EFFFFFF),
            ),
          ),
          _Note(
            [
              if (p.total > 0)
                '${formatBytes(p.completed)} of ${formatBytes(p.total)}',
              left,
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
          if (detailed)
            _Note(switch (d.stage) {
              api.DownloadStage.arriving =>
                '${formatBytes(p.rate)}/s · ${p.peers} peers, '
                    '${p.seeders} seeding',
              api.DownloadStage.fetchingMetadata =>
                '${d.stage.label} · ${p.peers} peers',
              api.DownloadStage.findingPeers => d.stage.label,
            }),
        ];
      case 'failed':
        return [const _Line('Failed')];
      default:
        return [const _Line('Paused')];
    }
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA)),
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.text, {this.value = '', this.done = false});
  final String text;
  final String value;
  final bool done;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    child: Row(
      children: [
        if (done) ...[
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 14, color: Colors.white),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: Color(0xFFAAAAAA),
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );
}
