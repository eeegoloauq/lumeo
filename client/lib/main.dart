import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'api/client.dart';
import 'api/downloads_store.dart';
import 'api/preferences_store.dart';
import 'l10n/app_localizations.dart';
import 'platform/decoders.dart';
import 'platform/local_file.dart';
import 'platform/local_settings.dart';
import 'ui/player/episode_frames.dart';
import 'ui/screens/app_shell.dart';
import 'ui/theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // libmpv has to be set up before anything asks for a player.
  MediaKit.ensureInitialized();
  // Asked what it can decode now, for the table where a copy is chosen.
  // Nothing waits for it.
  unawaited(DeviceDecoders.instance.load());
  final settings = await LocalSettings.load();
  runApp(LumeoApp(settings: settings, open: fileToOpen(args)));
}

class LumeoApp extends StatefulWidget {
  const LumeoApp({
    super.key,
    this.api,
    this.settings,
    this.preferences,
    this.open,
  });

  /// The core to talk to. Null in the app; the UI tests pass a fake core.
  final LumeoApi? api;

  /// Facts kept by this installation. Tests provide a temporary file so they
  /// never read or write the desktop user's configuration.
  final LocalSettings? settings;

  /// Shared choices from the core. Tests may provide the store when they need
  /// to observe its confirmed state directly.
  final PreferencesStore? preferences;

  /// A file to play on start: "Open with Lumeo" on it.
  final String? open;

  @override
  State<LumeoApp> createState() => _LumeoAppState();
}

class _LumeoAppState extends State<LumeoApp> {
  late final _api = widget.api ?? LumeoApi();
  late final _downloads = DownloadsStore(_api);
  late final _frames = EpisodeFrames(_api, _downloads);
  late final _settings = widget.settings ?? LocalSettings();
  late final _preferences = widget.preferences ?? PreferencesStore(_api);

  @override
  void initState() {
    super.initState();
    unawaited(_preferences.load());
  }

  @override
  void dispose() {
    _frames.dispose();
    _downloads.dispose();
    _preferences.dispose();
    unawaited(_settings.flush());
    _settings.dispose();
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_preferences, _settings]),
      // The shell is built once and handed in, so a preference change
      // rebuilds the theme and not the screens under it.
      child: AppShell(
        api: _api,
        downloads: _downloads,
        frames: _frames,
        settings: _settings,
        preferences: _preferences,
        open: widget.open,
      ),
      builder: (context, shell) => MaterialApp(
        title: 'Lumeo',
        debugShowCheckedModeBanner: false,
        theme: lumeoTheme(_preferences.current?.accent ?? 'white'),
        // None chosen follows the desktop, and a desktop language with no
        // translation gets the first supported one, English.
        locale: _settings.language.isEmpty ? null : Locale(_settings.language),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        // Down and Up walk the screen rather than the caret, for the search field's
        // one line with a list under it. Here because the search panel is a route of
        // its own: `builder` wraps the Navigator, above every route and below
        // MaterialApp's text editing shortcuts, and the nearer binding wins.
        // `ignoreTextFields: false` overrides the text field's
        // `DirectionalFocusAction.forTextField`, which swallows this intent.
        builder: (context, child) => Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(
              LogicalKeyboardKey.arrowDown,
            ): DirectionalFocusIntent(
              TraversalDirection.down,
              ignoreTextFields: false,
            ),
            SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
              TraversalDirection.up,
              ignoreTextFields: false,
            ),
          },
          // Text size is this screen's, from client.json, and scales every
          // Text under the Navigator the way the desktop's own setting would.
          child: ListenableBuilder(
            listenable: _settings,
            child: child,
            // On top of the desktop's own factor, not instead of it.
            builder: (context, child) {
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(
                  textScaler: TextScaler.linear(
                    media.textScaler.scale(1) * _settings.textScaleFactor,
                  ),
                ),
                child: child!,
              );
            },
          ),
        ),
        home: shell,
      ),
    );
  }
}
