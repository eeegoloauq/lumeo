import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/platform/decoders.dart';

void main() {
  const decoderList = '''
[
  {"codec":"h264","driver":"h264","description":"H.264 / AVC"},
  {"codec":"hevc","driver":"hevc","description":"HEVC (High Efficiency Video Coding)"},
  {"codec":"vp9","driver":"vp9","description":"Google VP9"}
]
''';

  test('finds a codec in mpv decoder-list JSON', () {
    // A generic decoder failure must not be blamed on a missing HEVC decoder
    // when mpv says that its libavcodec build provides one.
    expect(decoderListHas(decoderList, 'hevc'), isTrue);
  });

  test('reports a codec absent from a valid decoder list', () {
    // An absent codec is the only result that permits package instructions;
    // confusing it with a failed query sends people on an unrelated repair.
    expect(decoderListHas(decoderList, 'eac3'), isFalse);
  });

  test('does not draw a conclusion from malformed JSON', () {
    // A truncated IPC response used to risk turning uncertainty into a false
    // claim about how the local libavcodec was built.
    expect(decoderListHas('[{"codec":"hevc"}', 'hevc'), isNull);
  });

  test('does not draw a conclusion from an empty response', () {
    // mpv can fail the diagnostic query as well as playback; silence must
    // retain the source-selection advice instead of becoming "codec absent".
    expect(decoderListHas('', 'hevc'), isNull);
  });

  group('a decoder that plays but does not seek', () {
    // Fedora 44 as it actually is: libavcodec-free has no h264 driver, the
    // hole is filled by Cisco's libopenh264, and the hardware wrappers are in
    // the list on every machine whether or not the hardware is.
    const fedora = '''
[
  {"codec":"h264","driver":"libopenh264","description":"OpenH264 H.264 / AVC"},
  {"codec":"h264","driver":"h264_qsv","description":"H264 (Intel Quick Sync)"},
  {"codec":"h264","driver":"h264_cuvid","description":"Nvidia CUVID H264"},
  {"codec":"hevc","driver":"hevc","description":"HEVC"}
]
''';

    DeviceDecoders decoders(String answer) => DeviceDecoders(
      ask: () async => answer,
      osRelease: () async => 'ID=fedora\n',
    );

    test('is not a missing decoder: the film still plays', () async {
      // The reason this went unseen for so long. Every check asked "can this
      // machine decode h264", mpv answered yes, and it was telling the truth.
      final device = decoders(fedora);
      await device.load();
      expect(device.has('h264'), isTrue);
      expect(device.gapIn(const Release(videoCodec: 'AVC')), isNull);
    });

    test('is named, with the way out of it', () async {
      final device = decoders(fedora);
      await device.load();
      final broken = device.unreliable('h264');
      expect(broken?.driver, 'libopenh264');
      // The fact is one string and the advice another: the page that has room
      // for the commands prints them under the warning rather than inside it.
      expect(broken?.fact, contains('backward seek'));
      expect(broken?.fact, isNot(contains('RPM Fusion')));
      expect(broken?.sentence, contains('RPM Fusion'));
      expect(device.installCommands.last, endsWith('libavcodec-freeworld'));
    });

    test('the hardware wrappers are not what lavc would pick', () async {
      // h264_qsv and h264_cuvid sit in the list next to libopenh264 and are
      // only used when asked for by name. Counting them as a working decoder
      // would silence the warning on exactly the machines that need it.
      final device = decoders(fedora);
      await device.load();
      expect(device.unreliable('h264'), isNotNull);
    });

    test('says nothing where the codec has its own driver', () async {
      final device = decoders(decoderList);
      await device.load();
      expect(device.unreliable('h264'), isNull);
      expect(device.unreliable('hevc'), isNull);
    });

    test('says nothing about a codec mpv never mentioned', () async {
      final device = decoders(fedora);
      await device.load();
      expect(device.unreliable('av1'), isNull);
    });

    test('says nothing when mpv never answered', () async {
      final device = decoders('');
      await device.load();
      expect(device.unreliable('h264'), isNull);
    });
  });

  const fedora = '''
NAME="Fedora Linux"
ID=fedora
ID_LIKE="rhel centos"
''';

  test('sends Fedora to RPM Fusion without printing half a command', () {
    // The hint used to be the install line on its own, and on a machine
    // without RPM Fusion that line answers "no match": the one person who
    // followed it had to be told the missing half by somebody else. A
    // sentence that says where the packages live and where the commands are
    // cannot go wrong in that direction.
    final hint = codecInstallHint(fedora);
    expect(hint, contains('RPM Fusion'));
    expect(hint, isNot(contains('dnf install')));
  });

  test('the commands add the repository before the package', () {
    // Two, in this order, because the second one is what fails without the
    // first. The release number is asked of rpm rather than written down: one
    // baked in here is wrong the day after the next Fedora.
    final commands = codecInstallCommands(fedora);
    expect(commands, hasLength(2));
    expect(commands.first, contains('rpmfusion-free-release'));
    expect(commands.first, contains(r'$(rpm -E %fedora)'));
    expect(commands.last, endsWith('libavcodec-freeworld'));
  });

  test('a distribution with nothing verified to say gets no command', () {
    // openSUSE gets the sentence and no commands: adding Packman differs
    // between Leap and Tumbleweed, and a command printed on a guess is worse
    // than none at all.
    const suse = '''
NAME="openSUSE Tumbleweed"
ID="opensuse-tumbleweed"
ID_LIKE="opensuse suse"
''';
    expect(codecInstallHint(suse), isNotNull);
    expect(codecInstallCommands(suse), isEmpty);
    expect(codecInstallCommands('ID=debian'), isEmpty);
  });

  test('recognises openSUSE Tumbleweed through ID and ID_LIKE', () {
    // The rolling release has a qualified ID, so matching only the literal
    // "opensuse" value would silently drop its Packman instruction.
    const release = '''
NAME="openSUSE Tumbleweed"
ID="opensuse-tumbleweed"
ID_LIKE="opensuse suse"
''';
    expect(codecInstallHint(release), 'Install libavcodec from Packman.');
  });

  test('does not invent installation advice for Debian', () {
    // There is no verified universal package instruction, so an unrelated
    // distribution must not receive advice copied from RPM systems.
    const release = '''
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
ID=debian
ID_LIKE=debian
''';
    expect(codecInstallHint(release), isNull);
  });

  group('what this machine can play', () {
    // The whole point of asking mpv before anything is chosen: a copy whose
    // codec is missing here is a black screen, and the table has to say so
    // while there is still another row to click.
    DeviceDecoders decoders(String answer) => DeviceDecoders(
      ask: () async => answer,
      osRelease: () async => 'ID=fedora\n',
    );

    test('marks a copy whose video codec nothing here decodes', () async {
      final device = decoders(decoderList);
      await device.load();
      final gap = device.gapIn(const Release(videoCodec: 'HEVC'));
      expect(gap, isNull, reason: 'this list has hevc');

      final without = decoders(
        '[{"codec":"h264","driver":"h264","description":"H.264"}]',
      );
      await without.load();
      final missing = without.gapIn(const Release(videoCodec: 'HEVC'));
      expect(missing?.codec, 'hevc');
      expect(missing?.sound, isFalse);
      expect(missing?.sentence, contains('RPM Fusion'));
    });

    test('names the sound when it is the sound that is missing', () async {
      // x264 and DTS is the ordinary shape of the copy this happens to: the
      // picture plays and the film is silent, which is a line over a film
      // rather than a message covering it.
      final device = decoders(
        '[{"codec":"h264","driver":"h264","description":"H.264"}]',
      );
      await device.load();
      final gap = device.gapIn(
        const Release(videoCodec: 'AVC', audioCodec: 'DTS-HD'),
      );
      expect(gap?.sound, isTrue);
      expect(gap?.codec, 'dts', reason: 'DTS-HD is decoded by the dts decoder');
    });

    test('says nothing about a copy whose name says nothing', () async {
      final device = decoders(decoderList);
      await device.load();
      expect(device.gapIn(const Release()), isNull);
      expect(
        device.gapIn(const Release(videoCodec: 'Cinepak')),
        isNull,
        reason: 'an unknown name is not a missing decoder',
      );
    });

    test('claims nothing when mpv did not answer', () async {
      // The failure mode that matters: a query that fails must not turn into
      // "this machine decodes nothing" and mark every row in the table.
      final device = decoders('');
      await device.load();
      expect(device.answered, isFalse);
      expect(device.has('hevc'), isNull);
      expect(device.gapIn(const Release(videoCodec: 'HEVC')), isNull);
    });

    test('asks the file which half of it failed', () {
      // mpv words both failures the same way, so the file's own track list is
      // what tells a black screen from a silent film. The track whose decoder
      // failed is still in the list, still naming its codec.
      const tracks = '''
[
  {"id":1,"type":"video","codec":"hevc","selected":true},
  {"id":2,"type":"audio","codec":"dts","selected":true},
  {"id":3,"type":"sub","codec":"ass","selected":false}
]
''';
      expect(trackTypeFor(tracks, 'dts'), 'audio');
      expect(trackTypeFor(tracks, 'HEVC'), 'video');
      expect(trackTypeFor(tracks, 'eac3'), isNull);
      expect(trackTypeFor('', 'dts'), isNull);
      expect(trackTypeFor('[{"type":"audio"', 'dts'), isNull);
    });
  });
}
