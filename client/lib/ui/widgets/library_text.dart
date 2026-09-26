import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/app_localizations.dart';
import 'episode_card.dart' show shortDate;
import 'source_list.dart' show formatTimeLeft;

/// A day as somebody says it: "Today", "Yesterday", the weekday within the
/// last week, the date after that, and the year only when it is not this one.
///
/// [day] and [today] are compared as calendar dates, in whatever zone they
/// arrive in: a watch time is the viewer's evening, a release date is
/// Cinemeta's midnight UTC, and each caller hands over the pair that belongs
/// together.
String dayLabel(DateTime day, DateTime today, AppLocalizations l10n) {
  final days = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
  if (days == 0) return l10n.libraryToday;
  if (days == 1) return l10n.libraryYesterday;
  if (days > 1 && days < 7) return DateFormat.E(l10n.localeName).format(day);
  final date = shortDate(day, l10n.localeName);
  return day.year == today.year
      ? date
      : DateFormat.yMMMd(l10n.localeName).format(day);
}

/// The line under a poster on My list: how far the viewer is. With the
/// viewer's score beside it, the kind only when there is neither.
///
/// At a poster's width there is room for about twenty characters, so what is
/// said is what the poster cannot say. The kind is usually on the artwork's
/// face and never a reason to open it.
String listedCaption(ListedTitle t, AppLocalizations l10n) {
  final seen = t.item.isSeries
      ? t.watched > 0 && t.released > 0
            ? t.watched >= t.released
                  ? l10n.libraryWatched
                  : l10n.libraryWatchedOf(
                      NumberFormat.decimalPattern(l10n.localeName)
                          .format(t.watched),
                      NumberFormat.decimalPattern(l10n.localeName)
                          .format(t.released),
                    )
            : ''
      : t.watched > 0
      ? l10n.libraryWatched
      : '';
  if (seen.isEmpty && t.rating == 0) {
    return t.item.isSeries ? l10n.commonSeries : l10n.commonFilm;
  }
  return seen;
}

/// Which episode is new and when it came out: "S4 E18 · Today", with how
/// many there are when it is more than one.
String newEpisodeCaption(NewEpisodes n, DateTime now, AppLocalizations l10n) {
  final e = n.episode;
  final date = e.released == null
      ? null
      : dayLabel(e.released!.toUtc(), now.toUtc(), l10n);
  if (date != null && n.count > 1) {
    return l10n.libraryNewEpisodeDateCount(e.season, e.number, date, n.count);
  }
  if (date != null) return l10n.libraryNewEpisodeDate(e.season, e.number, date);
  if (n.count > 1) {
    return l10n.libraryNewEpisodeCount(e.season, e.number, n.count);
  }
  return l10n.libraryNewEpisode(e.season, e.number);
}

/// Where a viewing was left: the time still to go, or that it was finished.
String viewingState(WatchEntry entry, AppLocalizations l10n) {
  if (entry.position > Duration.zero && entry.duration > entry.position) {
    return formatTimeLeft((entry.duration - entry.position).inSeconds, l10n);
  }
  return entry.watched ? l10n.libraryWatched : l10n.libraryStarted;
}

/// A history line's title: the series and the episode, or the film.
String viewingTitle(Viewing v, AppLocalizations l10n) {
  if (!v.item.isSeries) return v.item.title;
  final name = v.episode == null
      ? ''
      : realTitle(v.episode!.number, v.episode!.title);
  return name.isEmpty
      ? l10n.libraryViewingTitle(v.item.title, v.entry.season, v.entry.episode)
      : l10n.libraryViewingNamedTitle(
          v.item.title,
          v.entry.season,
          v.entry.episode,
          name,
        );
}
