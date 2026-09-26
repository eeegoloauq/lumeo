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
  // And asked what it can decode, now rather than when a film fails to play:
  // the answer belongs to the table where a copy is chosen. Nothing waits for
  // it — it is one property read on a handle with no file, and it is done
  // long before a catalogue has arrived over the network.
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

  /// The core to talk to. Left null in the application, where there is exactly
  /// one; given by the UI tests, which stand a fake core in its place so a
  /// screen can be driven without a network or a running binary behind it.
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
        // Down and Up walk the screen rather than the caret, and this is the one
        // place in the application that can say so.
        //
        // Two things make it that place. The search panel is a route of its own,
        // pushed over this Navigator, so nothing inside the application is an
        // ancestor of the field in it and a binding down there never sees the
        // key; `builder` wraps the Navigator, which puts this above every route
        // and below the text editing shortcuts MaterialApp installs, and the
        // nearer binding wins. And `ignoreTextFields: false` is the whole point:
        // a text field registers `DirectionalFocusAction.forTextField`, which
        // exists to swallow exactly this intent so that arrows in a paragraph
        // move the caret instead of leaving the field. This field is one line
        // with a list under it, where down means the first answer.
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
