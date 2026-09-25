import '../../api/models.dart';
import 'episode_card.dart' show shortDate;
import 'source_list.dart' show formatTimeLeft;

/// A day as somebody says it: "Today", "Yesterday", the weekday within the
/// last week, the date after that, and the year only when it is not this one.
///
/// [day] and [today] are compared as calendar dates, in whatever zone they
/// arrive in: a watch time is the viewer's evening, a release date is
/// Cinemeta's midnight UTC, and each caller hands over the pair that belongs
/// together.
String dayLabel(DateTime day, DateTime today) {
  final days = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) return _weekdays[day.weekday - 1];
  final date = shortDate(day);
  return day.year == today.year ? date : '$date ${day.year}';
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// The line under a poster on My list: how far the viewer is. With the
/// viewer's score beside it, the kind only when there is neither.
///
/// At a poster's width there is room for about twenty characters, so what is
/// said is what the poster cannot say. The kind is usually on the artwork's
/// face and never a reason to open it.
String listedCaption(ListedTitle t) {
  final seen = t.item.isSeries
      ? t.watched > 0 && t.released > 0
            ? t.watched >= t.released
                  ? 'watched'
                  : '${t.watched} of ${t.released} seen'
            : ''
      : t.watched > 0
      ? 'watched'
      : '';
  if (seen.isEmpty && t.rating == 0) return t.item.isSeries ? 'Series' : 'Film';
  return seen;
}

/// Which episode is new and when it came out: "S4 E18 · Today", with how
/// many there are when it is more than one.
String newEpisodeCaption(NewEpisodes n, DateTime now) {
  final e = n.episode;
  final out = e.released == null
      ? ''
      : ' · ${dayLabel(e.released!.toUtc(), now.toUtc())}';
  final more = n.count > 1 ? ' · ${n.count} new' : '';
  return 'S${e.season} E${e.number}$out$more';
}

/// Where a viewing was left: the time still to go, or that it was finished.
String viewingState(WatchEntry entry) {
  if (entry.position > Duration.zero && entry.duration > entry.position) {
    return formatTimeLeft((entry.duration - entry.position).inSeconds);
  }
  return entry.watched ? 'watched' : 'started';
}

/// A history line's title: the series and the episode, or the film.
String viewingTitle(Viewing v) {
  if (!v.item.isSeries) return v.item.title;
  final number = 'S${v.entry.season} E${v.entry.episode}';
  final name = v.episode == null
      ? ''
      : realTitle(v.episode!.number, v.episode!.title);
  return name.isEmpty
      ? '${v.item.title} · $number'
      : '${v.item.title} · $number $name';
}
