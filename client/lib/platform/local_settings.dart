import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';

import 'dirs.dart';

/// Facts that belong only to this machine, such as volume and, later, the
/// cores it knows. A choice that should follow somebody to another client
/// belongs in the core instead.
class LocalSettings extends ChangeNotifier {
  LocalSettings({String? path}) : _path = path ?? _defaultPath();

  static const _saveDelay = Duration(milliseconds: 500);
  static const _defaultVolume = 100.0;

  final String _path;
  double _volume = _defaultVolume;
  String _keepFinished = keepFinishedChoices.first;
  String _listSort = listSortChoices.first;
  String _textScale = textScaleChoices[1];
  String _language = '';
  bool _timelinePreviews = true;
  String _screenshotsDir = '';
  DateTime? _clearedAt;
  Timer? _saveTimer;
  Completer<void>? _scheduled;
  Future<void> _writes = Future.value();

  /// Loads the local file when it is usable and otherwise returns defaults.
  static Future<LocalSettings> load({String? path}) async {
    final settings = LocalSettings(path: path);
    try {
      final decoded = jsonDecode(await File(settings._path).readAsString());
      if (decoded is Map<String, dynamic>) {
        if (decoded['volume'] is num) {
          settings._volume = (decoded['volume'] as num).toDouble().clamp(
            0,
            100,
          );
        }
        if (keepFinishedChoices.contains(decoded['keepFinished'])) {
          settings._keepFinished = decoded['keepFinished'] as String;
        }
        if (listSortChoices.contains(decoded['listSort'])) {
          settings._listSort = decoded['listSort'] as String;
        }
        if (textScaleChoices.contains(decoded['textScale'])) {
          settings._textScale = decoded['textScale'] as String;
        }
        if (_isTranslated(decoded['language'])) {
          settings._language = decoded['language'] as String;
        }
        if (decoded['timelinePreviews'] is bool) {
          settings._timelinePreviews = decoded['timelinePreviews'] as bool;
        }
        if (decoded['screenshotsDir'] is String) {
          settings._screenshotsDir = decoded['screenshotsDir'] as String;
        }
        if (decoded['downloadsClearedAt'] is String) {
          settings._clearedAt = DateTime.tryParse(
            decoded['downloadsClearedAt'] as String,
          );
        }
      }
    } on Object catch (_) {
      // Missing, unreadable and corrupt files all mean the same thing here:
      // this machine has not supplied a usable local value.
    }
    return settings;
  }

  double get volume => _volume;

  set volume(double value) {
    final clamped = value.clamp(0, 100).toDouble();
    if (clamped == _volume) return;
    _volume = clamped;
    notifyListeners();
    _scheduleSave();
  }

  /// How long a finished download stays in the downloads panel: '1d', '7d',
  /// or 'cleared' for until Clear.
  static const keepFinishedChoices = ['1d', '7d', 'cleared'];

  String get keepFinished => _keepFinished;

  set keepFinished(String value) {
    if (value == _keepFinished || !keepFinishedChoices.contains(value)) return;
    _keepFinished = value;
    notifyListeners();
    _scheduleSave();
  }

  /// How My list is ordered: 'added' (the latest first), 'title', 'year'
  /// (the newest first) or 'rating' (the viewer's highest first). A way of
  /// looking at the list on this screen, not a fact about the list, so it
  /// stays with the machine.
  static const listSortChoices = ['added', 'title', 'year', 'rating'];

  String get listSort => _listSort;

  set listSort(String value) {
    if (value == _listSort || !listSortChoices.contains(value)) return;
    _listSort = value;
    notifyListeners();
    _scheduleSave();
  }

  /// How large the interface's text is on this screen: 'small', 'default'
  /// or 'large'. A fact about a screen and the distance to it, so it stays
  /// with the machine.
  static const textScaleChoices = ['small', 'default', 'large'];

  String get textScale => _textScale;

  set textScale(String value) {
    if (value == _textScale || !textScaleChoices.contains(value)) return;
    _textScale = value;
    notifyListeners();
    _scheduleSave();
  }

  /// The factor [textScale] stands for.
  double get textScaleFactor => switch (_textScale) {
    'small' => 0.9,
    'large' => 1.15,
    _ => 1.0,
  };

  /// The interface's language as a language code, or empty to follow the
  /// desktop's. Kept here rather than in the core because the first frame
  /// needs it, before any answer from the core could arrive.
  String get language => _language;

  set language(String value) {
    if (value == _language || !_isTranslated(value)) return;
    _language = value;
    notifyListeners();
    _scheduleSave();
  }

  /// A translation that is no longer shipped reads as none chosen.
  static bool _isTranslated(Object? code) => AppLocalizations.supportedLocales
      .any((locale) => locale.languageCode == code);

  /// Whether the seek bar shows frames. Off, the second mpv that makes them
  /// never starts: on a slow machine or a metered swarm that is the point.
  bool get timelinePreviews => _timelinePreviews;

  set timelinePreviews(bool value) {
    if (value == _timelinePreviews) return;
    _timelinePreviews = value;
    notifyListeners();
    _scheduleSave();
  }

  /// Where the player saves frames; empty for Pictures/Lumeo.
  String get screenshotsDir => _screenshotsDir;

  set screenshotsDir(String value) {
    if (value == _screenshotsDir) return;
    _screenshotsDir = value;
    notifyListeners();
    _scheduleSave();
  }

  /// The choices the settings page shows, back to their defaults. Volume, the
  /// list's order and the panel's Clear are not choices made there.
  void resetChoices() {
    _keepFinished = keepFinishedChoices.first;
    _textScale = textScaleChoices[1];
    _language = '';
    _timelinePreviews = true;
    _screenshotsDir = '';
    notifyListeners();
    _scheduleSave();
  }

  /// When the panel's Clear was last pressed on this machine.
  DateTime? get downloadsClearedAt => _clearedAt;

  void clearFinishedDownloads() {
    _clearedAt = DateTime.now().toUtc();
    notifyListeners();
    _scheduleSave();
  }

  /// Whether a download that finished at [finishedAt] is still listed.
  bool showsFinished(DateTime finishedAt) {
    if (_clearedAt != null && !finishedAt.isAfter(_clearedAt!)) return false;
    final days = switch (_keepFinished) {
      '1d' => 1,
      '7d' => 7,
      _ => null,
    };
    return days == null ||
        DateTime.now().toUtc().difference(finishedAt) < Duration(days: days);
  }

  void _scheduleSave() {
    _scheduled ??= Completer<void>();
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _startSave);
  }

  void _startSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final scheduled = _scheduled;
    if (scheduled == null) return;
    _scheduled = null;
    final values = {
      'volume': _volume,
      'keepFinished': _keepFinished,
      'listSort': _listSort,
      'textScale': _textScale,
      if (_language.isNotEmpty) 'language': _language,
      'timelinePreviews': _timelinePreviews,
      'screenshotsDir': _screenshotsDir,
      if (_clearedAt != null)
        'downloadsClearedAt': _clearedAt!.toIso8601String(),
    };
    _writes = _writes.then((_) => _write(values)).whenComplete(() {
      if (!scheduled.isCompleted) scheduled.complete();
    });
  }

  Future<void> _write(Map<String, Object> values) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      final temporary = File('$_path.tmp');
      await temporary.writeAsString(jsonEncode(values), flush: true);
      await temporary.rename(_path);
    } on Object catch (error) {
      // A read-only home must not turn a film into a crash.
      debugPrint('saving $_path failed: $error');
    }
  }

  /// Writes a coalesced pending change and waits for all saves already begun.
  Future<void> flush() async {
    final pending = _scheduled?.future;
    if (pending != null) _startSave();
    if (pending != null) await pending;
    await _writes;
  }

  static String _defaultPath() => '${configDir()}/client.json';
}
