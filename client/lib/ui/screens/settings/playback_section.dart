import 'package:flutter/material.dart';

import '../../../api/preferences_store.dart';
import '../../../platform/local_settings.dart';
import '../../widgets/setting_row.dart';
import 'controls.dart';

class PlaybackSection extends StatelessWidget {
  const PlaybackSection({
    super.key,
    required this.preferences,
    required this.settings,
    required this.patch,
    required this.error,
  });

  final PreferencesStore preferences;
  final LocalSettings settings;
  final Future<void> Function(Map<String, Object?>) patch;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final current = preferences.current;
    return SettingsBlock(
      title: 'Playback',
      children: [
        SettingRows([
          if (current != null) ...[
            SettingRow(
              label: 'Audio languages',
              value: LanguageList(
                preference: 'audioLanguages',
                chosen: current.audioLanguages,
                preferences: preferences,
                onPatch: patch,
                empty: 'The file’s own',
              ),
            ),
            SettingRow(
              label: 'Show next episode',
              hint: 'When the file does not mark its credits.',
              value: PreferenceStepper(
                stored: current.nextNotice,
                min: 5,
                max: 120,
                step: 5,
                describe: (seconds) => '$seconds s',
                lessLabel: 'Earlier',
                moreLabel: 'Later',
                onChosen: (seconds) => patch({'nextNotice': seconds}),
              ),
              trailing: const Text('before the end', style: SettingsType.hint),
            ),
            SettingRow(
              label: 'Play next episode',
              hint:
                  'Counted from the last frame. Credits marked in the file '
                  'are the countdown themselves.',
              value: PresetChoice(
                presets: const [(0, 'On a press'), (5, 'After 5 s')],
                value: current.nextCountdown,
                describe: (seconds) => 'After $seconds s',
                onSelected: (seconds) => patch({'nextCountdown': seconds}),
                askCustom: (context) => askNumber(
                  context,
                  title: 'Play the next episode after',
                  unit: 's',
                  initial: current.nextCountdown == 0
                      ? 10
                      : current.nextCountdown,
                  min: 1,
                  max: 60,
                ),
              ),
            ),
            SettingRow(
              label: 'Arrow keys skip',
              value: PresetChoice(
                presets: const [(5, '5 s'), (10, '10 s')],
                value: current.seekStep,
                describe: (seconds) => '$seconds s',
                onSelected: (seconds) => patch({'seekStep': seconds}),
                askCustom: (context) => askNumber(
                  context,
                  title: 'The arrow keys skip',
                  unit: 's',
                  initial: current.seekStep,
                  min: 1,
                  max: 60,
                ),
              ),
              trailing: const Text('with Shift, 1 s', style: SettingsType.hint),
            ),
          ],
          // This machine's: whether it can afford a second decoder.
          SettingRow(
            label: 'Timeline previews',
            hint:
                'Frames over the seek bar, from a second player on the '
                'same file.',
            value: SettingSwitch(
              label: 'Timeline previews',
              value: settings.timelinePreviews,
              onChanged: (on) => settings.timelinePreviews = on,
            ),
          ),
          if (current == null && error == null) const SettingsLoading(),
          if (error != null) ErrorRow(error!),
        ]),
      ],
    );
  }
}
