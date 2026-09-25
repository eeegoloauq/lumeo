import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/player/tracks.dart';

void main() {
  test('the track list is read as mpv prints it', () {
    const json = '''
[
 {"id":1,"type":"video","selected":true,"codec":"hevc"},
 {"id":1,"type":"audio","title":"Japanese","lang":"jpn","codec":"aac",
  "demux-channel-count":2,"default":true,"selected":true},
 {"id":2,"type":"audio","lang":"eng","codec":"eac3","demux-channel-count":6},
 {"id":1,"type":"sub","title":"Signs & Songs","lang":"eng","forced":true,
  "codec":"ass","selected":false},
 {"id":2,"type":"sub","title":"Full","lang":"eng","default":true,"selected":true},
 {"id":3,"type":"sub","external":true,"lang":"pl","codec":"subrip",
  "external-filename":"http://core/api/v1/subtitles/abc"}
]''';
    final tracks = MpvTrack.parse(json);
    expect(tracks.map((t) => '${t.type}:${t.id}').toList(), [
      'video:1',
      'audio:1',
      'audio:2',
      'sub:1',
      'sub:2',
      'sub:3',
    ]);
    final audio = tracks[1];
    expect(audio.title, 'Japanese');
    expect(audio.language, 'jpn');
    expect(audio.codec, 'aac');
    expect(audio.channels, 2);
    expect(audio.selected, isTrue);
    expect(audio.isDefault, isTrue);
    expect(tracks[2].channels, 6);
    expect(tracks[2].selected, isFalse);
    expect(tracks[3].forced, isTrue);
    expect(tracks[4].selected, isTrue);
    final external = tracks[5];
    expect(external.external, isTrue);
    expect(external.externalFilename, 'http://core/api/v1/subtitles/abc');
    expect(external.title, '');
  });

  test('a list that does not parse is an empty one', () {
    expect(MpvTrack.parse(''), isEmpty);
    expect(MpvTrack.parse('{'), isEmpty);
    expect(MpvTrack.parse('{"id":1}'), isEmpty);
    expect(MpvTrack.parse('[1, "x", {"type":"sub"}]'), isEmpty);
  });

  group('whose change of aid and sid', () {
    test('mpv\'s pick after auto is mpv\'s, the next one the viewer\'s', () {
      final changes = TrackChanges();
      expect(changes.byViewer('aid', 'auto'), isFalse);
      expect(changes.byViewer('aid', '1'), isFalse, reason: 'mpv chose');
      expect(changes.byViewer('aid', '2'), isTrue, reason: 'the # key');
      expect(changes.byViewer('aid', '2'), isFalse, reason: 'no change');
    });

    test('a value the screen set is its own, even folded into mpv\'s', () {
      final changes = TrackChanges();
      changes.byViewer('sid', 'auto');
      changes.own('sid', '2');
      // mpv chose 1 and the screen then 2, reported as one change.
      expect(changes.byViewer('sid', '2'), isFalse);
      expect(
        changes.byViewer('sid', 'no'),
        isTrue,
        reason: 'a folded-away own value does not swallow the next pick',
      );
    });

    test('an own value reported on its own is consumed once', () {
      final changes = TrackChanges();
      changes.byViewer('sid', 'auto');
      changes.byViewer('sid', '1');
      changes.own('sid', '3');
      expect(changes.byViewer('sid', '3'), isFalse);
      expect(changes.byViewer('sid', '1'), isTrue);
    });

    test('properties are kept apart', () {
      final changes = TrackChanges();
      changes.byViewer('aid', 'auto');
      expect(changes.byViewer('sid', '1'), isTrue);
      expect(changes.byViewer('aid', '1'), isFalse);
    });
  });

  const tracks = [
    MpvTrack(
      id: '1',
      type: 'sub',
      language: 'eng',
      title: 'English Full',
      selected: true,
    ),
    MpvTrack(
      id: '2',
      type: 'sub',
      language: 'eng',
      title: 'English Honorifics',
    ),
    MpvTrack(id: '1', type: 'audio', language: 'jpn', title: 'Japanese'),
  ];

  test('a pick is found by language and title, and only when not on', () {
    const honorifics = TrackChoice(
      language: 'eng',
      title: 'English Honorifics',
    );
    expect(trackToSelect(tracks, 'sub', honorifics)?.id, '2');
    expect(
      trackToSelect(
        tracks,
        'sub',
        const TrackChoice(language: 'eng', title: 'English Full'),
      ),
      isNull,
    );
    expect(
      trackToSelect(tracks, 'sub', const TrackChoice(language: 'eng')),
      isNull,
      reason: 'slang decides',
    );
    expect(trackToSelect(tracks, 'sub', const TrackChoice(off: true)), isNull);
    expect(trackToSelect(tracks, 'audio', honorifics), isNull);
  });

  test('what is remembered waits for the track to be listed', () {
    final japanese = trackToRemember(tracks, 'audio', '1')!;
    expect([japanese.language, japanese.title], ['jpn', 'Japanese']);
    expect(trackToRemember(tracks, 'sub', 'no')!.off, isTrue);
    expect(trackToRemember(tracks, 'sub', '3'), isNull);
  });
}
