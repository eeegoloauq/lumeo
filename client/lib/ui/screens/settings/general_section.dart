import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../platform/local_settings.dart';
import '../../widgets/setting_row.dart';
import 'controls.dart';

class GeneralSection extends StatelessWidget {
  const GeneralSection({super.key, required this.settings});

  final LocalSettings settings;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsBlock(
      title: l10n.settingsGeneral,
      children: [
        SettingRows([
          SettingRow(
            label: l10n.settingsLanguage,
            value: InterfaceLanguage(
              onSelected: (code) => settings.language = code,
            ),
          ),
          SettingRow(
            label: l10n.settingsBackground,
            hint: l10n.settingsBackgroundHint,
            value: SettingSwitch(
              label: l10n.settingsBackground,
              value: settings.background,
              onChanged: (on) => settings.background = on,
            ),
          ),
          SettingRow(
            label: l10n.settingsAutostart,
            hint: l10n.settingsAutostartHint,
            value: SettingSwitch(
              label: l10n.settingsAutostart,
              value: settings.autostart,
              onChanged: (on) => settings.autostart = on,
            ),
          ),
        ]),
      ],
    );
  }
}
