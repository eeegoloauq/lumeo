import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import '../api/models.dart';

/// What this machine can actually play, asked of the thing that will have to
/// play it.
///
/// Fedora ships an ffmpeg without the patent-encumbered decoders, so a copy
/// that is hevc, or whose sound is dts, opens into a black screen or silence
/// on a machine where every other copy of the same film works. That is not a
/// property of the film, of the swarm or of the distribution we can guess at:
/// it is one list, and mpv publishes it as `decoder-list`. So the question is
/// asked once, before anything is chosen, and the answer is what the source
/// table marks its rows with.
///
/// Deliberately not a rule about distributions. The only distribution-shaped
/// thing here is the sentence that says how to install what is missing, and
/// that is a hint under an answer we already have.
class DeviceDecoders {
  DeviceDecoders({
    Future<String> Function()? ask,
    Future<String?> Function()? osRelease,
  }) : _ask = ask ?? _askMpv,
       _osRelease = osRelease ?? readOsRelease;

  /// The one every screen reads. A capability of the machine, not of a widget.
  ///
  /// Replaceable for the same reason the core is: a test about a table that
  /// marks what this machine cannot play must be able to say what this machine
  /// cannot play, and the answer on the machine running the test is "all of
  /// it".
  static DeviceDecoders instance = DeviceDecoders();

  final Future<String> Function() _ask;
  final Future<String?> Function() _osRelease;

  /// mpv's codec names against the drivers offered for each, or null while
  /// nobody has answered. Null is not "none": a query that failed must never
  /// turn into "this machine decodes nothing".
  Map<String, Set<String>>? _drivers;
  String? _installHint;
  List<String> _installCommands = const [];
  Future<void>? _asking;

  bool get answered => _drivers != null;

  /// Asked once and remembered. Safe to call from anywhere, at any time.
  Future<void> load() => _asking ??= _load();

  Future<void> _load() async {
    try {
      final drivers = decoderDrivers(await _ask());
      if (drivers == null) return;
      _drivers = drivers;
      final os = await _osRelease();
      if (os == null) return;
      _installHint = codecInstallHint(os);
      _installCommands = codecInstallCommands(os);
    } on Object catch (_) {
      // Nothing is claimed when the question could not be put. Every caller
      // treats "we do not know" as "say nothing", which is what a diagnostic
      // that failed is worth.
    }
  }

  /// Whether this machine has a decoder for one of mpv's codec names. Null
  /// while the list is unknown.
  bool? has(String codec) => _drivers?.containsKey(codec.toLowerCase());

  /// A codec this machine plays with a decoder that is known not to survive a
  /// seek, when there is one.
  ///
  /// Fedora's libavcodec-free is built without h264 and the hole is filled by
  /// Cisco's libopenh264. It plays, which is exactly why nothing here ever
  /// noticed: h264 is in mpv's list and [has] answers yes. What it does not do
  /// is come back from a backward seek — mpv's own tracker closes those
  /// reports with "openh264 is a known broken decoder, enable Fedora's
  /// multimedia stuff" — and what a viewer sees is the sound landing seconds
  /// away from the picture, which looks like a bug in whatever asked for the
  /// seek. It is not, and the player must say so rather than wear it.
  ///
  /// lavc picks the driver named after the codec. The hardware wrappers
  /// (h264_qsv, h264_cuvid, h264_v4l2m2m) are in the list on every machine and
  /// are only used when named, so their presence says nothing; the question is
  /// whether the driver named after the codec is there at all.
  BrokenDecoder? unreliable(String codec) {
    final name = codec.toLowerCase();
    final drivers = _drivers?[name];
    if (drivers == null || drivers.contains(name)) return null;
    final substitute = _knownBroken[name];
    if (substitute == null || !drivers.contains(substitute)) return null;
    return BrokenDecoder(
      codec: name,
      driver: substitute,
      installHint: _installHint,
    );
  }

  /// The one entry there is evidence for. Not a list of everything that could
  /// go wrong: a decoder belongs here once it has cost somebody an evening.
  static const _knownBroken = <String, String>{'h264': 'libopenh264'};

  /// How to install what is missing, on the distributions that ship their
  /// missing decoders separately.
  String? get installHint => _installHint;

  /// The same thing a shell can be given, where there is one worth printing.
  List<String> get installCommands => _installCommands;

  /// What this copy would lose here, going by the codecs its name states.
  ///
  /// Null when it plays, when nothing in the name says what it is, or when mpv
  /// never answered. The picture is reported before the sound: a copy with
  /// neither is one problem, and the first line of it is the one on screen.
  DecodeGap? gapIn(Release release) {
    final video = mpvVideoCodec(release.videoCodec);
    if (video != null && has(video) == false) {
      return DecodeGap(codec: video, sound: false, installHint: _installHint);
    }
    final audio = mpvAudioCodec(release.audioCodec);
    if (audio != null && has(audio) == false) {
      return DecodeGap(codec: audio, sound: true, installHint: _installHint);
    }
    return null;
  }
}

/// A codec this machine plays with the wrong decoder.
///
/// Not a [DecodeGap]: the picture is there and the film is watchable, so this
/// never marks a copy as unplayable. It is a sentence said once, when the
/// thing it warns about is about to be blamed on the player.
class BrokenDecoder {
  const BrokenDecoder({
    required this.codec,
    required this.driver,
    this.installHint,
  });

  final String codec;

  /// mpv's name for the decoder actually doing the work.
  final String driver;
  final String? installHint;

  /// What is wrong, without what to do about it — which is what a page that
  /// prints the commands underneath needs.
  String get fact =>
      '$codec is decoded here by $driver, which loses sync on a backward seek.';

  String get sentence => [fact, ?installHint].join(' ');
}

/// Something in a copy that this machine cannot decode.
class DecodeGap {
  const DecodeGap({required this.codec, required this.sound, this.installHint});

  /// mpv's name for it, which is also the name mpv prints when it fails.
  final String codec;

  /// Which half of the film goes missing.
  final bool sound;
  final String? installHint;

  /// Short enough for a table row, and about this machine rather than about
  /// the copy: the copy is fine, it is this machine that cannot open it.
  String get mark => sound ? 'no $codec sound' : 'no $codec here';

  /// What is missing, without what to do about it.
  String get fact => sound
      ? 'Nothing installed here decodes $codec, so this copy has no sound.'
      : 'Nothing installed here decodes $codec.';

  /// The whole of it, for the row that is being looked at and for the player.
  String get sentence => [fact, ?installHint].join(' ');
}

/// The codec names our release parser prints, in mpv's spelling.
///
/// The two vocabularies are not the same and neither is wrong: a release calls
/// it x265, mpv calls it hevc, and the table between them is the only place
/// that has to know both. Anything not listed is left alone — an unknown name
/// is not a missing decoder.
const _videoCodecs = <String, String>{
  'AVC': 'h264',
  'HEVC': 'hevc',
  'AV1': 'av1',
  'VP9': 'vp9',
  'XviD': 'mpeg4',
  'DivX': 'mpeg4',
  'MPEG-2': 'mpeg2video',
};

/// DTS-HD and DTS-X are dts with more in the stream: one decoder, and the
/// core of the track plays wherever it exists. PCM is deliberately absent —
/// it is a family of a dozen codec names and nothing ships without it.
const _audioCodecs = <String, String>{
  'AAC': 'aac',
  'AC3': 'ac3',
  'EAC3': 'eac3',
  'DTS': 'dts',
  'DTS-HD': 'dts',
  'DTS-X': 'dts',
  'TrueHD': 'truehd',
  'FLAC': 'flac',
  'Opus': 'opus',
  'MP3': 'mp3',
};

String? mpvVideoCodec(String releaseCodec) => _videoCodecs[releaseCodec];

String? mpvAudioCodec(String releaseCodec) => _audioCodecs[releaseCodec];

/// Which kind of track in mpv's track list is in [codec] — "audio", "video",
/// or null when the list says nothing about it.
///
/// mpv words a decoder it could not initialise identically whether the track
/// was the picture or the sound, and the difference decides between covering
/// the screen with a message and saying one line over a film that is playing
/// perfectly well apart from being silent. The file's own track list is what
/// answers it: a track whose decoder failed is still in the list, still with
/// the codec it is in — which is why this is not a list of audio codec names
/// kept by hand.
String? trackTypeFor(String json, String codec) {
  if (json.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    final wanted = codec.toLowerCase();
    for (final entry in decoded) {
      if (entry is Map &&
          entry['codec'] is String &&
          (entry['codec'] as String).toLowerCase() == wanted &&
          entry['type'] is String) {
        return entry['type'] as String;
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// mpv's decoder list, as codec names against the drivers offered for each.
///
/// The driver matters and not only the codec: a codec whose own driver is
/// missing is still listed, decoded by whatever substitute the distribution
/// put there. See [DeviceDecoders.unreliable].
///
/// Null means the value was not a decoder list, so callers do not confuse a
/// failed query with a machine that decodes nothing.
Map<String, Set<String>>? decoderDrivers(String json) {
  if (json.trim().isEmpty) return null;

  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    final drivers = <String, Set<String>>{};
    for (final entry in decoded) {
      if (entry is! Map || entry['codec'] is! String) continue;
      final codec = (entry['codec'] as String).toLowerCase();
      final driver = entry['driver'];
      (drivers[codec] ??= <String>{}).add(
        driver is String ? driver.toLowerCase() : codec,
      );
    }
    return drivers;
  } on FormatException {
    return null;
  }
}

/// The codec names in mpv's decoder list.
Set<String>? decoderCodecs(String json) => decoderDrivers(json)?.keys.toSet();

/// Whether mpv's decoder list contains [codec].
bool? decoderListHas(String json, String codec) =>
    decoderCodecs(json)?.contains(codec.toLowerCase());

/// An actionable way to add a missing decoder on distributions where they are
/// packaged separately. Which decoder it is does not change the answer: these
/// repositories ship the whole set as one package.
String? codecInstallHint(String osReleaseContents) {
  final ids = _distributions(osReleaseContents);
  if (ids.contains('fedora')) {
    return 'They ship in RPM Fusion; Settings has the two commands.';
  }
  if (ids.contains('opensuse') || ids.contains('suse')) {
    return 'Install libavcodec from Packman.';
  }
  return null;
}

/// The same advice as a shell can take it, in the order it has to be run.
///
/// Two commands on Fedora and not one. The package is in RPM Fusion, which
/// Fedora does not enable and does not intend to, so a machine without that
/// repository answers the install with "no match" — which is exactly what the
/// one-command version of this hint produced for the first person to follow
/// it. Where the repository is already there the first line is a no-op.
///
/// Empty where there is nothing verified to say. openSUSE gets the sentence
/// above and no commands: adding Packman differs between Leap and Tumbleweed,
/// and a command printed on a guess is worse than none.
List<String> codecInstallCommands(String osReleaseContents) {
  if (!_distributions(osReleaseContents).contains('fedora')) return const [];
  return const [
    // The release number comes from rpm rather than from us: os-release has
    // it, but a number baked into a string here is a number that is wrong the
    // day after the next release.
    r'sudo dnf install https://mirrors.rpmfusion.org/free/fedora/'
        r'rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm',
    'sudo dnf install libavcodec-freeworld',
  ];
}

/// What the machine calls itself, its family included.
Set<String> _distributions(String osReleaseContents) {
  final fields = _osReleaseFields(osReleaseContents);
  return '${fields['ID'] ?? ''} ${fields['ID_LIKE'] ?? ''}'
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .toSet();
}

Map<String, String> _osReleaseFields(String contents) {
  final fields = <String, String>{};
  for (final line in const LineSplitter().convert(contents)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final equals = trimmed.indexOf('=');
    if (equals <= 0) continue;
    final key = trimmed.substring(0, equals);
    var value = trimmed.substring(equals + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    fields[key] = value;
  }
  return fields;
}

/// Reads the operating-system identity separately from its parser so the
/// distribution rules stay deterministic and filesystem-free in tests.
Future<String?> readOsRelease() async {
  try {
    return await File('/etc/os-release').readAsString();
  } on FileSystemException {
    return null;
  }
}

/// mpv, asked before it has been given anything to play.
///
/// A player of its own rather than the one on the player screen: the answer is
/// needed while a title is being chosen, which is before any film has been
/// opened. It costs one libmpv handle with no window, no video output and no
/// file, and it is disposed the moment it has answered.
Future<String> _askMpv() async {
  final player = Player();
  try {
    final platform = player.platform;
    if (platform is! NativePlayer) return '';
    return await platform.getProperty('decoder-list');
  } finally {
    await player.dispose();
  }
}
