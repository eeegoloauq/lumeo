import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/player/bindings.dart';

void main() {
  test('the binding list is read as mpv prints it', () {
    const json =
        '[{"section":"default","cmd":"cycle pause","is_weak":true,'
        '"priority":0,"comment":"toggle pause/playback mode","key":"SPACE"},'
        '{"section":"default","cmd":"add volume 2","is_weak":true,'
        '"priority":0,"key":"WHEEL_UP"}]';
    final parsed = MpvBinding.parse(json);
    expect(parsed.map((b) => b.key).toList(), ['SPACE', 'WHEEL_UP']);
    expect(parsed[0].comment, 'toggle pause/playback mode');
    expect(parsed[1].comment, '');
    expect(MpvBinding.parse(''), isEmpty);
    expect(MpvBinding.parse('{'), isEmpty);
  });

  test('keys are printed as keycaps', () {
    expect(keyLabel('f'), 'F');
    expect(keyLabel('F'), 'Shift+F');
    expect(keyLabel('SPACE'), 'Space');
    expect(keyLabel('Shift+RIGHT'), 'Shift+→');
    expect(keyLabel('Shift+Ctrl+BS'), 'Shift+Ctrl+Backspace');
    expect(keyLabel('Ctrl++'), 'Ctrl++');
    expect(keyLabel('Alt+-'), 'Alt+-');
    expect(keyLabel('MBTN_LEFT_DBL'), 'Double click');
    expect(keyLabel('KP5'), 'Numpad 5');
    expect(
      keyLabel('PLAYPAUSE'),
      isNull,
      reason: 'a media key does what is printed on it',
    );
  });

  test(
    'one line per command, ours over the default, the dead ones left out',
    () {
      const bindings = [
        MpvBinding(section: 'default', key: 'MBTN_LEFT', cmd: 'ignore'),
        MpvBinding(
          section: 'default',
          key: 'MBTN_RIGHT',
          cmd: 'cycle pause',
          comment: 'toggle pause/playback mode',
        ),
        MpvBinding(
          section: 'default',
          key: 'SPACE',
          cmd: 'cycle pause',
          comment: 'toggle pause/playback mode',
        ),
        MpvBinding(
          section: 'default',
          key: 'p',
          cmd: 'cycle pause',
          comment: 'toggle pause/playback mode',
        ),
        MpvBinding(
          section: 'default',
          key: 'RIGHT',
          cmd: 'seek  5',
          comment: 'seek 5 seconds forward',
        ),
        MpvBinding(section: 'default', key: '9', cmd: 'add volume -2'),
        MpvBinding(section: 'default', key: '0', cmd: 'add volume 2'),
        MpvBinding(section: 'default', key: 'q', cmd: 'quit'),
        MpvBinding(
          section: 'default',
          key: 'ENTER',
          cmd: 'playlist-next',
          comment: 'skip to the next file',
        ),
        MpvBinding(
          section: 'default',
          key: 'STOP',
          cmd: 'cycle pause',
          comment: 'toggle pause/playback mode',
        ),
        MpvBinding(
          section: 'input',
          key: 'MBTN_LEFT',
          cmd: 'script-binding osc/__keybinding5',
        ),
        MpvBinding(section: ownSection, key: 'MBTN_LEFT', cmd: 'cycle pause'),
        MpvBinding(
          section: ownSection,
          key: 'ESC',
          cmd: 'script-message lumeo escape',
        ),
        MpvBinding(
          section: ownSection,
          key: 'q',
          cmd: 'script-message lumeo back',
        ),
        MpvBinding(
          section: ownSection,
          key: 'c',
          cmd: 'script-message lumeo tracks',
        ),
        MpvBinding(section: ownSection, key: 'F11', cmd: 'cycle fullscreen'),
      ];
      final lines = shortcuts(bindings);
      expect(
        [for (final l in lines) '${l.keys.join(', ')} — ${l.what}'],
        [
          'Click, Right click, Space, P — Toggle pause/playback mode',
          '→ — Seek 5 seconds forward',
          '9 — Volume −2',
          '0 — Volume +2',
          'Q — Back to the title',
          'Esc — Leave fullscreen, else back to the title',
          'C — Audio & subtitles',
          'F11 — Fullscreen',
        ],
      );
    },
  );

  test('our input section contains the host actions', () {
    expect(ownBindings(), [
      'MBTN_LEFT cycle pause',
      'ESC script-message lumeo escape',
      'q script-message lumeo back',
      'c script-message lumeo tracks',
      'F11 cycle fullscreen',
      'LEFT seek -5',
      'RIGHT seek 5',
    ]);
  });

  test('the arrows seek by the stored step, and mpv does the seeking', () {
    // The step is a binding in our section rather than a seek of ours: the
    // key still reaches mpv as a keydown, and mpv seeks.
    expect(
      ownBindings(seekStep: 10),
      containsAll(['LEFT seek -10', 'RIGHT seek 10']),
    );
    final own = ownBindingList(seekStep: 10);
    expect([
      for (final b in own) '${b.section} ${b.key} ${b.cmd}',
    ], contains('lumeo RIGHT seek 10'));
  });

  test('the settings page lists the everyday keys, with the step', () {
    const defaults = [
      MpvBinding(
        section: 'default',
        key: 'SPACE',
        cmd: 'cycle pause',
        comment: 'toggle pause/playback mode',
      ),
      MpvBinding(
        section: 'default',
        key: 'p',
        cmd: 'cycle pause',
        comment: 'toggle pause/playback mode',
      ),
      MpvBinding(
        section: 'default',
        key: 'RIGHT',
        cmd: 'seek  5',
        comment: 'seek 5 seconds forward',
      ),
      MpvBinding(
        section: 'default',
        key: 'UP',
        cmd: 'seek  60',
        comment: 'seek 1 minute forward',
      ),
      MpvBinding(section: 'default', key: 'i', cmd: 'script-binding stats'),
    ];
    final lines = shortcuts(
      [...defaults, ...ownBindingList(seekStep: 10)],
      only: ['SPACE', 'RIGHT', 'LEFT', 'UP'],
    );
    expect(
      [for (final l in lines) '${l.keys.join(', ')} — ${l.what}'],
      [
        'Space, P, Click — Toggle pause/playback mode',
        '→ — Seek 10 seconds forward',
        '← — Seek 10 seconds backward',
        '↑ — Seek 1 minute forward',
      ],
      reason: 'a key not asked for is left out; one doing the same is not',
    );
  });

  test('non-Latin keys use their physical US key unless bound', () {
    expect(layoutKey(0x70009, false, 'а', {}), 'f');
    expect(layoutKey(0x70009, true, 'А', {}), 'F');
    expect(layoutKey(0x7002f, false, 'х', {}), '[');
    expect(layoutKey(0x7002f, true, 'Х', {}), '{');
    expect(layoutKey(0x70009, false, 'а', {'а'}), 'а');
    expect(layoutKey(0x70009, false, 'f', {}), 'f');
    expect(layoutKey(0x70020, true, '№', {}), '#');
  });
}
