import 'package:flutter/material.dart';

import '../../../api/preferences_store.dart';
import '../../../l10n/l10n.dart';
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
      title: context.l10n.settingsPlayback,
      children: [
        SettingRows([
          if (current != null) ...[
            SettingRow(
              label: context.l10n.settingsAudioLanguages,
              value: LanguageList(
                preference: 'audioLanguages',
                chosen: current.audioLanguages,
                preferences: preferences,
                onPatch: patch,
                empty: context.l10n.settingsFileLanguage,
              ),
            ),
            SettingRow(
              label: context.l10n.settingsShowNextEpisode,
              hint: context.l10n.settingsShowNextEpisodeHint,
              value: PreferenceStepper(
                stored: current.nextNotice,
                min: 5,
                max: 120,
                step: 5,
                describe: (seconds) => context.l10n.commonSeconds(seconds),
                lessLabel: context.l10n.settingsEarlier,
                moreLabel: context.l10n.settingsLater,
                onChosen: (seconds) => patch({'nextNotice': seconds}),
              ),
              trailing: Text(
                context.l10n.settingsBeforeEnd,
                style: SettingsType.hint,
              ),
            ),
            SettingRow(
              label: context.l10n.settingsPlayNextEpisode,
              hint: context.l10n.settingsNextCountdownHint,
              value: PresetChoice(
                presets: [
                  (0, context.l10n.settingsOnPress),
                  (5, context.l10n.settingsAfterFiveSeconds),
                ],
                value: current.nextCountdown,
                describe: (seconds) =>
                    context.l10n.settingsAfterSeconds(seconds),
                onSelected: (seconds) => patch({'nextCountdown': seconds}),
                askCustom: (context) => askNumber(
                  context,
                  title: context.l10n.settingsPlayNextEpisodeAfter,
                  unit: context.l10n.commonSecondUnit,
                  initial: current.nextCountdown == 0
                      ? 10
                      : current.nextCountdown,
                  min: 1,
                  max: 60,
                ),
              ),
            ),
            SettingRow(
              label: context.l10n.settingsArrowSkip,
              value: PresetChoice(
                presets: [
                  (5, context.l10n.settingsFiveSeconds),
                  (10, context.l10n.settingsTenSeconds),
                ],
                value: current.seekStep,
                describe: (seconds) => context.l10n.commonSeconds(seconds),
                onSelected: (seconds) => patch({'seekStep': seconds}),
                askCustom: (context) => askNumber(
                  context,
                  title: context.l10n.settingsArrowSkipQuestion,
                  unit: context.l10n.commonSecondUnit,
                  initial: current.seekStep,
                  min: 1,
                  max: 60,
                ),
              ),
              trailing: Text(
                context.l10n.settingsShiftSkip,
                style: SettingsType.hint,
              ),
            ),
          ],
          // This machine's: whether it can afford a second decoder.
          SettingRow(
            label: context.l10n.settingsTimelinePreviews,
            hint: context.l10n.settingsTimelinePreviewsHint,
            value: SettingSwitch(
              label: context.l10n.settingsTimelinePreviews,
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
