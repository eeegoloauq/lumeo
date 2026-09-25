import 'dart:async';

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'languages.dart';
import 'models.dart';

/// The last preferences document the core confirmed, and the failure to get
/// a newer one when there is one.
class PreferencesStore extends ChangeNotifier {
  PreferencesStore(this._api);

  static const _rememberDelay = Duration(milliseconds: 500);

  final LumeoApi _api;
  Timer? _rememberTimer;
  final _remembered = <String, Object?>{};
  Preferences? _current;
  Languages _languages = Languages.none;
  Object? _error;
  bool _disposed = false;
  Future<void> _writes = Future.value();

  /// The document most recently returned by the core.
  Preferences? get current => _current;

  /// The languages a preference may name, with what files call them. Empty
  /// until the core has answered, and every reader prints the code itself
  /// until then.
  Languages get languages => _languages;

  /// The last load or patch failure, cleared by the next successful answer.
  Object? get error => _error;

  /// Asks for the complete effective preferences document, and for the
  /// language table alongside it. The table failing is not the document
  /// failing: it costs names in the menus, not the preferences.
  Future<void> load() async {
    try {
      final fresh = await _api.preferences();
      if (_disposed) return;
      _current = fresh;
      _error = null;
      notifyListeners();
    } on Object catch (error) {
      if (_disposed) return;
      _error = error;
      notifyListeners();
    }
    try {
      final fresh = Languages(await _api.languages());
      if (_disposed) return;
      _languages = fresh;
      notifyListeners();
    } on Object catch (_) {
      // Left empty, and asked for again on the next load.
    }
  }

  /// Sends a partial document and keeps the returned complete document.
  Future<void> patch(Map<String, Object?> patch) =>
      _write(() => _api.patchPreferences(patch));

  /// Every preference back to the core's default. A burst still waiting to
  /// be remembered is dropped: it was chosen before the reset.
  Future<void> reset() {
    _rememberTimer?.cancel();
    _rememberTimer = null;
    _remembered.clear();
    return _write(_api.resetPreferences);
  }

  /// Sends one write after every earlier one has been answered, so the core
  /// applies them in the order they were made: a patch still on its way when
  /// Reset is pressed cannot land after the reset and bring its value back.
  Future<void> _write(Future<Preferences> Function() send) =>
      _writes = _writes.then((_) async {
        try {
          final fresh = await send();
          if (_disposed) return;
          _current = fresh;
          _error = null;
          notifyListeners();
        } on Object catch (error) {
          if (_disposed) return;
          _error = error;
          notifyListeners();
        }
      });

  /// Remembers only the last value of each key chosen during a burst — a
  /// speed key held down, a stepper clicked five times — as one patch.
  void remember(String key, Object? value) {
    _remembered[key] = value;
    _rememberTimer?.cancel();
    _rememberTimer = Timer(_rememberDelay, () {
      final latest = Map.of(_remembered);
      _remembered.clear();
      _rememberTimer = null;
      if (latest.isNotEmpty) unawaited(patch(latest));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _rememberTimer?.cancel();
    super.dispose();
  }
}
