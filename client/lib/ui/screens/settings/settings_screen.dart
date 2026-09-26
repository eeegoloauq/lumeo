import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../api/addons_store.dart';
import '../../../api/client.dart';
import '../../../api/downloads_store.dart';
import '../../../api/models.dart';
import '../../../api/preferences_store.dart';
import '../../../l10n/l10n.dart';
import '../../../platform/folders.dart';
import '../../../platform/local_settings.dart';
import '../../theme.dart';
import '../../widgets/top_bar.dart';
import 'about_section.dart';
import 'appearance_section.dart';
import 'controls.dart';
import 'downloads_section.dart';
import 'general_section.dart';
import 'playback_section.dart';
import 'settings_section.dart';
import 'shortcuts_section.dart';
import 'sources_section.dart';
import 'subtitles_section.dart';

export 'settings_section.dart';

/// Every setting on one page that scrolls, with a list of its sections
/// beside it: pressing one scrolls there, and the one being read is lit.
///
/// One page rather than a rail of pages because most visits are "where was
/// that", and a page to scroll answers it by looking; a rail answered it by
/// guessing which page to open.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.downloads,
    required this.preferences,
    required this.settings,
    this.section,
    this.request = 0,
    this.pictures = picturesFolder,
  });

  final LumeoApi api;
  final DownloadsStore downloads;
  final PreferencesStore preferences;
  final LocalSettings settings;

  /// Where the page opens, scrolled to; the top when null.
  final SettingsSection? section;

  /// Changed by the shell to scroll to [section] again on a page already
  /// open — the downloads panel's Storage link pressed over Settings.
  final int request;

  /// The desktop's Pictures folder, which screenshots go under by default.
  /// A seam for the tests: the real answer runs a program.
  final Future<String> Function() pictures;

  /// The sections that have rows. General has only the language yet: its
  /// other mockup rows (closing to a tray, pausing when minimised) need
  /// things the application does not have, and a row that does nothing is
  /// not shown.
  static const shown = [
    SettingsSection.general,
    SettingsSection.appearance,
    SettingsSection.playback,
    SettingsSection.subtitles,
    SettingsSection.downloads,
    SettingsSection.sources,
    SettingsSection.shortcuts,
    SettingsSection.about,
  ];

  /// A section counts as the one being read once its heading is this near
  /// the top of the view.
  static const readingLine = 120.0;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<CoreAbout> _about = widget.api.about();
  late final _addons = AddonsStore(widget.api)..load();
  final _keys = {
    for (final section in SettingsScreen.shown) section: GlobalKey(),
  };
  final _viewport = GlobalKey();

  late SettingsSection _current = SettingsScreen.shown.first;

  /// Where the page was asked to open, kept until the viewer scrolls: the
  /// sections above it grow as their answers arrive, and the page follows.
  SettingsSection? _target;

  /// Set while a press in the list scrolls the page, so the section passing
  /// under the line on the way does not light up.
  bool _going = false;

  /// Which section's control the last preference change came from: the
  /// core's refusal is said there, not at the top of a page scrolled away.
  SettingsSection? _changedIn;

  @override
  void initState() {
    super.initState();
    _aim(widget.section);
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    if (widget.request != old.request) _aim(widget.section);
  }

  @override
  void dispose() {
    _addons.dispose();
    super.dispose();
  }

  void _aim(SettingsSection? section) {
    if (section == null) return;
    _target = section;
    _current = section;
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  void _follow() {
    final target = _target;
    if (!mounted || target == null) return;
    unawaited(_scrollTo(target, animate: false));
  }

  Future<void> _scrollTo(SettingsSection section, {bool animate = true}) async {
    final context = _keys[section]?.currentContext;
    if (context == null) return;
    setState(() => _current = section);
    _going = true;
    try {
      await Scrollable.ensureVisible(
        context,
        duration: animate ? Motion.panel : Duration.zero,
        curve: Motion.ease,
      );
    } finally {
      _going = false;
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    // A jump of ours can end in an idle one; only the viewer moves it.
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      _target = null;
    }
    if (notification is ScrollMetricsNotification && _target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
    if (!_going &&
        (notification is ScrollUpdateNotification ||
            notification is ScrollEndNotification)) {
      _spy(notification.metrics);
    }
    return false;
  }

  /// The section whose heading has passed the top of the view is the one
  /// being read; at the very bottom, the last one, which may be too short
  /// ever to reach the top.
  void _spy(ScrollMetrics metrics) {
    if (_target != null) return;
    final view = _viewport.currentContext?.findRenderObject();
    if (view is! RenderBox) return;
    var reading = SettingsScreen.shown.first;
    if (metrics.extentAfter < 1 && metrics.extentBefore > 0) {
      reading = SettingsScreen.shown.last;
    } else {
      for (final section in SettingsScreen.shown) {
        final box = _keys[section]?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached) continue;
        final top = box.localToGlobal(Offset.zero, ancestor: view).dy;
        if (top + SettingsBlock.headingTop <= _readingLine) reading = section;
      }
    }
    if (reading != _current) setState(() => _current = reading);
  }

  static const _readingLine = SettingsScreen.readingLine;

  Future<void> _patch(SettingsSection section, Map<String, Object?> patch) {
    setState(() => _changedIn = section);
    return widget.preferences.patch(patch);
  }

  /// The preferences failure, in the section it belongs to: the one changed
  /// last, or the first one when the document never arrived.
  Object? _errorIn(SettingsSection section) {
    final error = widget.preferences.error;
    if (error == null) return null;
    return section == (_changedIn ?? SettingsSection.appearance) ? error : null;
  }

  void _refreshAbout() => setState(() {
    _about = widget.api.about();
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: TopBar.height),
      child: Stack(
        fit: StackFit.expand,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: SingleChildScrollView(
              key: _viewport,
              primary: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 0, 48, 96),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1056),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 256),
                      child: ListenableBuilder(
                        listenable: Listenable.merge([
                          widget.preferences,
                          widget.settings,
                        ]),
                        builder: (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final section in SettingsScreen.shown)
                              KeyedSubtree(
                                key: _keys[section],
                                child: KeyedSubtree(
                                  key: ValueKey('settings:${section.name}'),
                                  child: _section(section),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1056),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _Nav(
                    current: _current,
                    onGo: (section) {
                      _target = null;
                      unawaited(_scrollTo(section));
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(SettingsSection section) {
    final preferences = widget.preferences;
    Future<void> patch(Map<String, Object?> p) => _patch(section, p);
    return switch (section) {
      SettingsSection.general => GeneralSection(settings: widget.settings),
      SettingsSection.appearance => AppearanceSection(
        preferences: preferences,
        settings: widget.settings,
        patch: patch,
        error: _errorIn(section),
      ),
      SettingsSection.playback => PlaybackSection(
        preferences: preferences,
        settings: widget.settings,
        patch: patch,
        error: _errorIn(section),
      ),
      SettingsSection.subtitles => SubtitlesSection(
        preferences: preferences,
        patch: patch,
        error: _errorIn(section),
      ),
      SettingsSection.downloads => DownloadsSection(
        api: widget.api,
        downloads: widget.downloads,
        preferences: preferences,
        settings: widget.settings,
        about: _about,
        pictures: widget.pictures,
        onAboutChanged: _refreshAbout,
        patch: patch,
        error: _errorIn(section),
      ),
      SettingsSection.sources => SourcesSection(addons: _addons),
      SettingsSection.shortcuts => ShortcutsSection(preferences: preferences),
      SettingsSection.about => AboutSection(
        api: widget.api,
        preferences: preferences,
        settings: widget.settings,
        about: _about,
        onReset: () => setState(() => _changedIn = SettingsSection.about),
        error: _errorIn(section),
      ),
    };
  }
}

class _Nav extends StatelessWidget {
  const _Nav({required this.current, required this.onGo});

  final SettingsSection current;
  final ValueChanged<SettingsSection> onGo;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Padding(
        // The title stands on the line of the first section's heading.
        padding: const EdgeInsets.only(top: 50),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 20),
              child: Semantics(
                header: true,
                child: Text(
                  context.l10n.settingsTitle,
                  style: Typo.heroTitle.copyWith(
                    fontSize: 30,
                    letterSpacing: -0.4,
                    shadows: const [],
                  ),
                ),
              ),
            ),
            for (final section in SettingsScreen.shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Semantics(
                  selected: section == current,
                  child: TextButton(
                    onPressed: () => onGo(section),
                    style: TextButton.styleFrom(
                      foregroundColor: section == current
                          ? Palette.text
                          : Palette.muted,
                      backgroundColor: section == current
                          ? Palette.raised
                          : Colors.transparent,
                      overlayColor: Palette.hover,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Shape.controlRadius),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 34),
                      maximumSize: const Size(double.infinity, 34),
                      alignment: Alignment.centerLeft,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: Typo.cardTitle.copyWith(
                        fontWeight: section == current
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    child: Text(section.title(context.l10n)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
