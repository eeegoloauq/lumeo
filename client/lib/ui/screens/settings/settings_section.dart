import '../../../l10n/app_localizations.dart';

/// The parts of the settings page, in the order it shows them. Its own file
/// so the shell and the downloads panel can name one without the page.
enum SettingsSection {
  general,
  appearance,
  playback,
  audioSubtitles,
  downloads,
  sources,
  shortcuts,
  about;

  String title(AppLocalizations l10n) => switch (this) {
    general => l10n.settingsGeneral,
    appearance => l10n.settingsAppearance,
    playback => l10n.settingsPlayback,
    audioSubtitles => l10n.settingsAudioSubtitles,
    downloads => l10n.settingsDownloads,
    sources => l10n.settingsSources,
    shortcuts => l10n.settingsShortcuts,
    about => l10n.settingsAbout,
  };
}
