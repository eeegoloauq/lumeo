import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'bindings.dart';
import 'mpv_host.dart';

/// What the settings page says about the player, asked of an mpv of its
/// own: the page has none, and a film's mpv is gone by the time it opens.
///
/// mpv's default bindings and its version do not change while the
/// application runs, so they are asked once. The hardware decoder does not
/// exist without a film; the player reports the one it used last.
class MpvFacts extends ChangeNotifier {
  MpvFacts({Future<({String bindings, String version})> Function()? ask})
    : _ask = ask ?? _askMpv;

  /// Replaceable for the tests, as [DeviceDecoders.instance] is.
  static MpvFacts instance = MpvFacts();

  final Future<({String bindings, String version})> Function() _ask;
  Future<void>? _asking;
  List<MpvBinding>? _bindings;
  String _version = '';
  String _hardware = '';

  /// Whether mpv answered at all. Nothing is claimed about keys until it has.
  bool get answered => _bindings != null;

  /// Whether the question has been put and answered or failed.
  bool get done => _done;
  bool _done = false;

  /// mpv's own bindings, without ours: those depend on preferences and are
  /// listed by [ownBindingList].
  List<MpvBinding> get bindings => _bindings ?? const [];

  /// "0.41.0", without the "mpv " mpv puts in front; empty when unknown.
  String get version => _version;

  /// The hardware decoder the last film used this session, as mpv names it
  /// (`nvdec`, `vaapi`); empty before one played or when it decoded in
  /// software.
  String get hardware => _hardware;

  set hardware(String value) {
    final used = value == 'no' ? '' : value;
    if (used == _hardware) return;
    _hardware = used;
    notifyListeners();
  }

  Future<void> load() => _asking ??= _load();

  Future<void> _load() async {
    try {
      final answer = await _ask();
      final bindings = [
        for (final b in MpvBinding.parse(answer.bindings))
          if (b.section != ownSection) b,
      ];
      // An mpv with no bindings at all did not answer the question.
      if (bindings.isNotEmpty) _bindings = bindings;
      _version = answer.version.replaceFirst(RegExp(r'^mpv\s+'), '');
    } on Object catch (error) {
      debugPrint('mpv facts: $error');
    }
    _done = true;
    notifyListeners();
  }
}

/// A player with no file, its bindings switched on the way the film's are,
/// and read through a second client so nothing blocks the Dart thread.
Future<({String bindings, String version})> _askMpv() async {
  final player = Player();
  MpvHost? host;
  try {
    final platform = player.platform;
    if (platform is! NativePlayer) return (bindings: '', version: '');
    await platform.setProperty('input-default-bindings', 'yes');
    host = await MpvHost.attach(platform);
    final bindings = await host.get('input-bindings') ?? '';
    final version = await host.get('mpv-version') ?? '';
    return (bindings: bindings, version: version);
  } finally {
    host?.dispose();
    await player.dispose();
  }
}
