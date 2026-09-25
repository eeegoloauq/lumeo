import 'package:flutter/foundation.dart';

import 'client.dart';
import 'models.dart';

/// The installed addons as the core last confirmed them, and the failure to
/// change them when there is one.
///
/// Every change goes to the core and the list is what comes back — the row
/// on screen is never ahead of the row in the database, so a refused change
/// is simply a list that did not move, with the reason beside it.
class AddonsStore extends ChangeNotifier {
  AddonsStore(this._api);

  final LumeoApi _api;
  List<Addon>? _current;
  Object? _error;
  Object? _addError;
  bool _adding = false;
  bool _disposed = false;

  /// The list most recently returned by the core, null until it answers.
  List<Addon>? get current => _current;

  /// The last load or change failure, cleared by the next successful answer.
  Object? get error => _error;

  /// Why the last address typed was refused, cleared by the next attempt.
  Object? get addError => _addError;

  /// Whether an address is being checked right now.
  bool get adding => _adding;

  Future<void> load() => _apply(() async => _current = await _api.addons());

  /// Installs the addon at a URL, or re-points the one already installed
  /// from it. Reports whether the core took it.
  Future<bool> add(String url) async {
    _adding = true;
    _addError = null;
    notifyListeners();
    try {
      final addon = await _api.addAddon(url);
      if (_disposed) return false;
      final list = [..._current ?? const <Addon>[]];
      final index = list.indexWhere((a) => a.id == addon.id);
      if (index < 0) {
        list.add(addon);
      } else {
        list[index] = addon;
      }
      _current = list;
      _error = null;
      return true;
    } on Object catch (error) {
      if (_disposed) return false;
      _addError = error;
      return false;
    } finally {
      if (!_disposed) {
        _adding = false;
        notifyListeners();
      }
    }
  }

  Future<void> setEnabled(String id, bool enabled) => _apply(() async {
    final addon = await _api.patchAddon(id, {'enabled': enabled});
    _current = [
      for (final a in _current ?? const <Addon>[])
        if (a.id == id) addon else a,
    ];
  });

  /// Moves an addon to a place in the list. The order is what the core
  /// breaks ties with, and the first catalog is the home screen.
  Future<void> move(String id, int to) => _apply(() async {
    await _api.patchAddon(id, {'position': to});
    _current = await _api.addons();
  });

  Future<void> remove(String id) => _apply(() async {
    await _api.removeAddon(id);
    _current = [
      for (final a in _current ?? const <Addon>[])
        if (a.id != id) a,
    ];
  });

  Future<void> _apply(Future<void> Function() change) async {
    try {
      await change();
      if (_disposed) return;
      _error = null;
    } on Object catch (error) {
      if (_disposed) return;
      _error = error;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
