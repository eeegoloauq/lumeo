#include "tracks.h"

#include "core.h"
#include "mpvitem.h"
#include "preferences.h"

#include <QFile>
#include <algorithm>
#include <cmath>
#include <memory>

namespace {

// The colours the `subtitleColor` preference names: white, a broadcast
// yellow, a softer cream for long sittings, and a cyan that stays apart from
// warm pictures.
const QHash<QString, QString> subtitleColours = {
    {"white", "#FFFFFF"},
    {"yellow", "#FFE14D"},
    {"cream", "#F5E6C4"},
    {"cyan", "#7FE0FF"},
};

QString format(const QString &codec) {
  static const QHash<QString, QString> names = {
      {"subrip", "SRT"},   {"ass", "ASS"},        {"ssa", "SSA"},
      {"hdmv_pgs_subtitle", "PGS"}, {"dvd_subtitle", "VobSub"},
      {"webvtt", "WebVTT"}, {"mov_text", "Text"},
  };
  return names.value(codec, codec.toUpper());
}

QString channels(int count) {
  switch (count) {
  case 1: return "1.0";
  case 2: return "2.0";
  case 6: return "5.1";
  case 8: return "7.1";
  default: return qtTrId("playerChannels", count);
  }
}

QString idOf(const QVariantMap &track) { return track.value("id").toString(); }

QString foundLabel(const QJsonObject &subtitle) {
  const QString name = subtitle["languageName"].toString();
  return name.isEmpty() ? subtitle["language"].toString().toUpper() : name;
}

QString origin(const QJsonObject &subtitle) {
  return subtitle["kept"].toBool() ? qtTrId("playerSubtitleKept")
                                   : qtTrId("playerSubtitleOpenSubtitles");
}

} // namespace

Tracks::Tracks(MpvItem *mpv, Core *core, Preferences *preferences, QObject *parent)
    : QObject(parent), m_mpv(mpv), m_core(core), m_preferences(preferences),
      m_audioRows(new Rows({"track", "label", "detail", "current"}, this)),
      m_subtitleRows(new Rows(
          {"kind", "track", "found", "label", "detail", "current", "more", "group", "indent"}, this)) {
  connect(mpv, &MpvItem::tracksChanged, this, &Tracks::onTracks);
  connect(mpv, &MpvItem::aidChanged, this, [this] { onTrackChange("aid", m_mpv->aid()); });
  connect(mpv, &MpvItem::sidChanged, this, [this] { onTrackChange("sid", m_mpv->sid()); });
  connect(mpv, &MpvItem::hasPictureChanged, this, &Tracks::subtitleOnceChosen);
  connect(mpv, &MpvItem::subDelayChanged, this, &Tracks::changed);
  connect(mpv, &MpvItem::subVisibleChanged, this, &Tracks::changed);
  // Size and height are kept for the next film. Before the open mpv reports
  // its defaults, which would replace the stored values on their way to it.
  connect(mpv, &MpvItem::subScaleChanged, this, [this] {
    if (!m_opened)
      return;
    m_scale = m_mpv->subScale();
    if (m_preferences->current().value("subtitleScale").toDouble() != m_scale)
      m_preferences->remember("subtitleScale", m_scale);
    emit changed();
  });
  connect(mpv, &MpvItem::subPosChanged, this, [this] {
    if (!m_opened)
      return;
    m_position = std::round(m_mpv->subPos());
    if (m_preferences->current().value("subtitlePosition").toInt() != int(m_position))
      m_preferences->remember("subtitlePosition", int(m_position));
    emit changed();
  });
}

Languages Tracks::languages() const { return Languages(m_preferences->languages()); }

bool Tracks::subtitlesOn() const {
  return m_mpv && m_mpv->subVisible() && !selected("sub").isEmpty();
}

double Tracks::delay() const { return m_mpv ? m_mpv->subDelay() : 0; }

void Tracks::prepare(const QString &itemId, const QString &downloadId,
                     std::function<void()> ready) {
  m_itemId = itemId;
  m_downloadId = downloadId;
  if (m_prepared) {
    apply();
    ready();
    return;
  }
  auto waiting = std::make_shared<int>(4);
  auto done = [this, waiting, ready] {
    if (--*waiting > 0)
      return;
    m_prepared = true;
    const QVariantMap prefs = m_preferences->current();
    m_scale = prefs.value("subtitleScale", 1).toDouble();
    m_position = prefs.value("subtitlePosition", 100).toDouble();
    m_background = prefs.value("subtitleBackground", "none").toString();
    apply();
    ready();
  };
  if (itemId.isEmpty()) {
    done();
  } else {
    m_core->get("/api/v1/choices/" + Core::segment(itemId), {}, this,
                [this, done](const Core::Reply &reply) {
                  if (reply.ok())
                    m_choice = reply.json().toObject();
                  done();
                });
  }
  // Listed from disk, no provider asked: offline they are what there is.
  m_core->get("/api/v1/downloads/" + Core::segment(downloadId) + "/subtitles", {}, this,
              [this, done](const Core::Reply &reply) {
                if (reply.ok())
                  m_kept = reply.json()["subtitles"].toArray();
                done();
              });
  if (!m_preferences->current().isEmpty()) {
    done();
  } else {
    // The languages answer apart and say changed too.
    auto connection = std::make_shared<QMetaObject::Connection>();
    *connection = connect(m_preferences, &Preferences::changed, this, [this, connection, done] {
      if (m_preferences->current().isEmpty() && m_preferences->error().isEmpty())
        return;
      QObject::disconnect(*connection);
      done();
    });
    m_preferences->load();
  }
  m_mpv->get("sub-border-style", this, [this, done](const QVariant &value) {
    m_borderStyle = value.isValid();
    done();
  });
}

// mpv chooses: the languages, whether a soundtrack in one of the subtitle
// languages needs subtitles, and whether a default track counts when none is
// in a wanted language. The title's own picks go first.
void Tracks::apply() {
  const QVariantMap prefs = m_preferences->current();
  const QString mode = prefs.value("subtitleMode").toString();
  const QJsonObject audio = m_choice["audio"].toObject();
  const QJsonObject subtitle = m_choice["subtitle"].toObject();
  const bool pickedSubtitle = !subtitle["off"].toBool() && !subtitle["language"].toString().isEmpty();
  QStringList alang;
  if (!audio["language"].toString().isEmpty())
    alang << audio["language"].toString();
  alang << prefs.value("audioLanguages").toStringList();
  QStringList slang;
  if (pickedSubtitle)
    slang << subtitle["language"].toString();
  if (mode != "manual")
    slang << prefs.value("subtitleLanguages").toStringList();
  m_mpv->set("alang", alang.join(','));
  m_mpv->set("slang", slang.join(','));
  m_mpv->set("subs-with-matching-audio", mode == "foreign" && !pickedSubtitle ? "no" : "yes");
  m_mpv->set("subs-fallback", mode == "manual" ? "no" : "default");
  if (subtitle["off"].toBool())
    selectOwn("sid", "no");
  m_mpv->set("sub-scale", m_scale);
  m_mpv->set("sub-pos", int(m_position));
  const QVariantMap background = backgroundProperties(m_background, m_borderStyle);
  for (auto it = background.begin(); it != background.end(); ++it)
    m_mpv->set(it.key(), it.value());
  // mpv's colour reaches plain text only while `sub-ass-override` is its
  // default; `force` makes ours win over a styled track's too.
  m_mpv->set("sub-color", subtitleColours.value(prefs.value("subtitleColor").toString(), "#FFFFFF"));
  m_mpv->set("sub-ass-override", prefs.value("subtitleKeepStyling", true).toBool() ? "scale" : "force");
}

QVariantMap Tracks::backgroundProperties(const QString &background, bool borderStyle) {
  // Opaque and unblurred: a wide translucent shadow reads as a grey smear.
  const QString shadow = "#FF000000", box = "#C0000000", clear = "#00000000";
  // A thick outline alone; a thin one under a drop shadow, which a thick one
  // would hide; for the box, its padding.
  QVariantMap properties{
      {"sub-border-size", background == "shadow" ? 1.5 : 4.0},
      {"sub-shadow-offset", background == "shadow" ? 3 : 0},
  };
  if (borderStyle) {
    properties["sub-border-style"] = background == "box" ? "background-box" : "outline-and-shadow";
    properties["sub-back-color"] = background == "box" ? box : background == "shadow" ? shadow : clear;
  } else {
    properties["sub-back-color"] = background == "box" ? box : clear;
    properties["sub-shadow-color"] = shadow;
  }
  return properties;
}

void Tracks::opened() {
  m_opened = true;
  matchTitles();
}

void Tracks::reopened() {
  m_opened = false;
  m_titlesMatched.clear();
  m_audioAnswered = false;
}

void Tracks::restoreDelay(double seconds) {
  m_delayKnown = true;
  if (seconds != 0)
    setDelay(seconds);
}

QVariantList Tracks::tracksOf(const QString &type) const {
  QVariantList of;
  if (m_mpv)
    for (const QVariant &track : m_mpv->tracks())
      if (track.toMap().value("type") == type)
        of.append(track);
  return of;
}

QVariantMap Tracks::selected(const QString &type) const {
  for (const QVariant &track : tracksOf(type))
    if (track.toMap().value("selected").toBool())
      return track.toMap();
  return {};
}

void Tracks::onTracks() {
  matchTitles();
  answerForAudio();
  subtitleOnceChosen();
  if (!m_ownFound.isEmpty())
    for (const QVariant &t : tracksOf("sub")) {
      const QVariantMap track = t.toMap();
      if (track.value("external").toBool() && track.value("external-filename") == m_ownFound) {
        m_ownFound.clear();
        selectOwn("sid", idOf(track));
        break;
      }
    }
  saveTracks();
  rebuild();
}

bool Tracks::byViewer(const QString &property, const QString &value) {
  if (value == "auto") {
    m_mpvChoosing.insert(property);
    return false;
  }
  const QString previous = m_last.value(property);
  m_last[property] = value;
  if (m_mpvChoosing.remove(property))
    return false;
  return m_own.take(property) != value && value != previous;
}

void Tracks::selectOwn(const QString &property, const QString &id) {
  m_own[property] = id;
  m_mpv->set(property, id);
}

void Tracks::onTrackChange(const QString &property, const QString &value) {
  rebuild();
  if (!byViewer(property, value))
    return;
  if (property == "sid")
    ++m_picks;
  m_unsaved[property] = value;
  saveTracks();
  if (property == "sid")
    rememberForAudio(value != "no");
}

// A title's pick is matched by language and title, since a file can have
// several tracks in one language.
void Tracks::matchTitles() {
  if (!m_opened)
    return;
  const std::pair<QString, QString> kinds[] = {{"aid", "audio"}, {"sid", "sub"}};
  for (const auto &[property, type] : kinds) {
    const QVariantList tracks = tracksOf(type);
    if (m_titlesMatched.contains(type) || tracks.isEmpty())
      continue;
    m_titlesMatched.insert(type);
    const QJsonObject picked = m_choice[type == "sub" ? "subtitle" : "audio"].toObject();
    if (picked.isEmpty() || picked["off"].toBool() || picked["title"].toString().isEmpty())
      continue;
    for (const QVariant &t : tracks) {
      const QVariantMap track = t.toMap();
      if (!track.value("external").toBool() &&
          track.value("lang").toString() == picked["language"].toString() &&
          track.value("title").toString() == picked["title"].toString()) {
        if (!track.value("selected").toBool())
          selectOwn(property, idOf(track));
        break;
      }
    }
  }
}

QString Tracks::audioLanguage() const {
  return languages().canonical(selected("audio").value("lang").toString());
}

QVariant Tracks::answerForAudioLanguage() const {
  return m_preferences->current().value("subtitlesWithAudio").toMap().value(audioLanguage());
}

// Subtitles turned on or off by hand are the answer for every title in this
// soundtrack's language, as well as this title's track.
void Tracks::rememberForAudio(bool on) {
  const QString language = audioLanguage();
  QVariantMap answers = m_preferences->current().value("subtitlesWithAudio").toMap();
  if (language.isEmpty() || (answers.contains(language) && answers.value(language).toBool() == on))
    return;
  answers.insert(language, on);
  m_preferences->remember("subtitlesWithAudio", answers);
}

// Once the soundtrack is known, the viewer's answer for its language goes
// over the mode; a subtitle picked for this title goes over both.
void Tracks::answerForAudio() {
  if (m_audioAnswered || !m_opened || selected("audio").isEmpty())
    return;
  m_audioAnswered = true;
  const QVariant on = answerForAudioLanguage();
  if (!on.isValid() || m_choice["subtitle"].isObject())
    return;
  const Languages names = languages();
  const QStringList wanted = m_preferences->current().value("subtitleLanguages").toStringList();
  const QString id = subtitleForAudio(m_mpv->tracks(), on.toBool(), [&](const QString &language) {
    return names.rank(language, wanted);
  });
  if (!id.isEmpty())
    selectOwn("sid", id);
}

QString Tracks::subtitleForAudio(const QVariantList &tracks, bool on,
                                 const std::function<int(const QString &)> &rank) {
  QVariantMap chosen, best;
  QVariantList subtitles;
  for (const QVariant &t : tracks)
    if (t.toMap().value("type") == "sub") {
      subtitles.append(t);
      if (t.toMap().value("selected").toBool())
        chosen = t.toMap();
    }
  if (!on)
    return chosen.isEmpty() || chosen.value("forced").toBool() ? QString() : "no";
  if (!chosen.isEmpty())
    return {};
  for (const QVariant &t : subtitles) {
    const int r = rank(t.toMap().value("lang").toString());
    if (r >= 0 && (best.isEmpty() || r < rank(best.value("lang").toString())))
      best = t.toMap();
  }
  return best.isEmpty() ? QString() : idOf(best);
}

// A pick is saved once the track list has caught up with it.
void Tracks::saveTracks() {
  QJsonObject patch;
  const std::pair<QString, QString> kinds[] = {{"aid", "audio"}, {"sid", "subtitle"}};
  for (const auto &[property, key] : kinds) {
    if (!m_unsaved.contains(property))
      continue;
    const QString id = m_unsaved.value(property);
    if (property == "sid" && id == "no") {
      patch[key] = QJsonObject{{"off", true}};
      m_unsaved.remove(property);
      continue;
    }
    for (const QVariant &t : tracksOf(property == "aid" ? "audio" : "sub")) {
      const QVariantMap track = t.toMap();
      if (idOf(track) != id)
        continue;
      patch[key] = QJsonObject{{"language", track.value("lang").toString()},
                               {"title", track.value("title").toString()}};
      m_unsaved.remove(property);
    }
  }
  if (m_itemId.isEmpty() || patch.isEmpty())
    return;
  m_core->send("PATCH", "/api/v1/choices/" + Core::segment(m_itemId), {}, patch, this,
               [](const Core::Reply &reply) {
                 if (!reply.ok())
                   qWarning("tracks not remembered: %s", qPrintable(reply.message()));
               });
}

// Once the picture is up and mpv has said which tracks the file has, and so
// which subtitle it chose.
void Tracks::subtitleOnceChosen() {
  if (m_mpv && m_mpv->hasPicture() && !tracksOf("video").isEmpty())
    subtitleFromDatabase();
}

// After mpv's choice: a subtitle kept with the download in a language the
// viewer ranks above mpv's, or, when mpv chose none and the mode wants one,
// the database's best. Kept files are not handed to mpv with the film: mpv
// ranks any external track above the file's own, whatever its language.
// Once per film, so that turning them off sticks.
void Tracks::subtitleFromDatabase() {
  if (m_databaseAsked)
    return;
  m_databaseAsked = true;
  const QVariantMap prefs = m_preferences->current();
  const Languages names = languages();
  const QJsonObject picked = m_choice["subtitle"].toObject();
  if (picked["off"].toBool())
    return;
  const QVariant answer = m_choice["subtitle"].isObject() ? QVariant() : answerForAudioLanguage();
  if (answer.isValid() && !answer.toBool())
    return;
  const QString mode = prefs.value("subtitleMode").toString();
  QStringList wanted;
  if (!picked["language"].toString().isEmpty())
    wanted << names.canonical(picked["language"].toString());
  if ((answer.isValid() && answer.toBool()) || mode != "manual")
    wanted << prefs.value("subtitleLanguages").toStringList();
  if (wanted.isEmpty())
    return;
  if (!m_choice["subtitle"].isObject() && !answer.isValid() && mode == "foreign" &&
      names.rank(selected("audio").value("lang").toString(),
                 prefs.value("subtitleLanguages").toStringList()) >= 0)
    return;
  auto rank = [names, wanted](const QString &language) {
    const int r = names.rank(language, wanted);
    return r < 0 ? int(wanted.size()) : r;
  };
  const int picks = m_picks;
  const QVariantMap chosen = selected("sub");
  const int beats = chosen.isEmpty() ? int(wanted.size()) : rank(chosen.value("lang").toString());
  QJsonObject best;
  for (const QJsonValue &kept : m_kept)
    if (rank(kept["language"].toString()) <
        (best.isEmpty() ? beats : rank(best["language"].toString())))
      best = kept.toObject();
  auto load = [this, picks, rank](const QJsonObject &best) {
    fetch(best, [this, picks, rank, best](const QString &path) {
      if (m_picks != picks)
        return;
      if (path.isEmpty()) {
        emit subtitleFailed();
        return;
      }
      const QVariantMap now = selected("sub");
      if (!now.isEmpty() && rank(now.value("lang").toString()) <= rank(best["language"].toString()))
        return;
      m_ownFound = path;
      addSubtitle(path, best, "auto");
    });
  };
  if (!best.isEmpty()) {
    load(best);
    return;
  }
  if (!chosen.isEmpty())
    return;
  // Only now is the database asked: the lookup costs the swarm the last
  // 64 KiB of the file, which a viewer whose file has the language never pays.
  auto fromFound = [this, rank, wanted, load] {
    if (!selected("sub").isEmpty())
      return;
    for (const QJsonValue &found : m_found)
      if (rank(found["language"].toString()) < wanted.size()) {
        load(found.toObject());
        return;
      }
  };
  if (m_lookedUp) {
    fromFound();
    return;
  }
  m_afterLookup = fromFound;
  lookUp();
}

void Tracks::show() {
  if (!m_lookedUp)
    lookUp();
  // Unfolded at the language whose database copy is on screen while the
  // file has a track of its own in it.
  m_expanded.clear();
  QSet<QString> inFile;
  for (const QVariant &track : embedded())
    inFile.insert(base(track.toMap().value("lang").toString()));
  for (const QJsonValue &found : m_found)
    if (isLoaded(found.toObject()) && inFile.contains(base(found["language"].toString()))) {
      m_expanded = base(found["language"].toString());
      break;
    }
  rebuild();
}

void Tracks::lookUp() {
  if (m_looking || m_itemId.isEmpty())
    return;
  m_looking = true;
  m_lookupFailed = false;
  rebuild();
  m_core->get("/api/v1/subtitles", QUrlQuery{{"item", m_itemId}, {"download", m_downloadId}}, this,
              [this](const Core::Reply &reply) {
                m_looking = false;
                m_lookedUp = true;
                m_lookupFailed = !reply.ok();
                if (reply.ok())
                  m_found = reply.json()["subtitles"].toArray();
                rebuild();
                if (auto after = std::exchange(m_afterLookup, {}))
                  after();
              });
}

void Tracks::expand(const QString &group) {
  m_expanded = m_expanded == group ? QString() : group;
  rebuild();
}

void Tracks::pickAudio(const QString &id) { m_mpv->set("aid", id); }

void Tracks::pickSubtitle(const QString &id) {
  ++m_picks;
  m_mpv->set("sid", id.isEmpty() ? "no" : id);
}

// A copy mpv already has is selected again: mpv keeps every external track
// it was handed.
void Tracks::pickFound(int index) {
  if (index < 0 || index >= m_found.size())
    return;
  const QJsonObject subtitle = m_found[index].toObject();
  const int pick = ++m_picks;
  fetch(subtitle, [this, pick, subtitle](const QString &path) {
    if (pick != m_picks)
      return;
    if (path.isEmpty()) {
      emit subtitleFailed();
      return;
    }
    for (const QVariant &t : tracksOf("sub"))
      if (t.toMap().value("external").toBool() && t.toMap().value("external-filename") == path) {
        m_mpv->set("sid", idOf(t.toMap()));
        return;
      }
    addSubtitle(path, subtitle, "select");
  });
}

void Tracks::addSubtitle(const QString &path, const QJsonObject &subtitle, const QString &flag) {
  const QString name = subtitle["name"].toString();
  m_mpv->command({"sub-add", path, flag, name.isEmpty() ? foundLabel(subtitle) : name,
                  subtitle["language"].toString()});
}

// The core converts the file to UTF-8 on the way through; it is kept here
// for the film, and a failed one is asked for again on the next pick.
void Tracks::fetch(const QJsonObject &subtitle, std::function<void(const QString &)> done) {
  const QString url = subtitle["url"].toString();
  if (m_paths.contains(url)) {
    done(m_paths.value(url));
    return;
  }
  auto &waiting = m_fetching[url];
  waiting.append(std::move(done));
  if (waiting.size() > 1)
    return;
  m_core->get(url, {}, this, [this, url](const Core::Reply &reply) {
    QString path;
    if (reply.ok() && m_dir.isValid()) {
      QFile file(m_dir.filePath(QString::number(m_paths.size())));
      if (file.open(QIODevice::WriteOnly) && file.write(reply.body) == reply.body.size())
        path = file.fileName();
    }
    if (!path.isEmpty())
      m_paths.insert(url, path);
    for (const auto &answer : m_fetching.take(url))
      answer(path);
  });
}

void Tracks::setDelay(double seconds) {
  m_mpv->set("sub-delay", std::round(seconds * 10) / 10);
}

void Tracks::setScale(double scale) {
  m_mpv->set("sub-scale", std::round(std::clamp(scale, 0.5, 2.0) * 100) / 100);
}

// Above 100 mpv pushes the line below the picture.
void Tracks::setPosition(double position) {
  m_mpv->set("sub-pos", int(std::round(std::clamp(position, 70.0, 100.0))));
}

// Kept on the pick itself: no key of mpv's changes it.
void Tracks::setBackground(const QString &background) {
  m_background = background;
  m_preferences->remember("subtitleBackground", background);
  const QVariantMap properties = backgroundProperties(background, m_borderStyle);
  for (auto it = properties.begin(); it != properties.end(); ++it)
    m_mpv->set(it.key(), it.value());
  emit changed();
}

QString Tracks::base(const QString &tag) const {
  const QString code = languages().canonical(tag);
  const qsizetype dash = code.indexOf('-');
  return dash > 0 ? code.left(dash) : code;
}

QString Tracks::trackLabel(const QVariantMap &track) const {
  const QString language = track.value("lang").toString();
  const QString name = languages().name(language);
  if (!name.isEmpty())
    return name;
  if (!language.isEmpty() && language != "und")
    return language.toUpper();
  const QString title = track.value("title").toString();
  return title.isEmpty() ? qtTrId("playerTrack").arg(idOf(track)) : title;
}

bool Tracks::isLoaded(const QJsonObject &subtitle) const {
  const QVariantMap chosen = selected("sub");
  const QString url = subtitle["url"].toString();
  return !chosen.isEmpty() && chosen.value("external").toBool() && !url.isEmpty() &&
         m_paths.contains(url) && chosen.value("external-filename") == m_paths.value(url);
}

// The file's own subtitles, in the order of the viewer's languages.
QVariantList Tracks::embedded() const {
  QVariantList tracks;
  for (const QVariant &t : tracksOf("sub"))
    if (!t.toMap().value("external").toBool())
      tracks.append(t);
  const Languages names = languages();
  const QStringList preferred = m_preferences->current().value("subtitleLanguages").toStringList();
  auto rank = [&](const QVariant &t) {
    const int r = names.rank(t.toMap().value("lang").toString(), preferred);
    return r < 0 ? int(preferred.size()) : r;
  };
  std::stable_sort(tracks.begin(), tracks.end(),
                   [&](const QVariant &a, const QVariant &b) { return rank(a) < rank(b); });
  return tracks;
}

void Tracks::rebuild() {
  QList<QVariantMap> audioRows;
  for (const QVariant &t : tracksOf("audio")) {
    const QVariantMap track = t.toMap();
    const QString title = track.value("title").toString();
    const int count = track.value("demux-channel-count").toInt();
    audioRows.append(QVariantMap{
        {"track", idOf(track)},
        {"label", title.isEmpty() ? trackLabel(track) : trackLabel(track) + " · " + title},
        {"detail", count > 0 ? channels(count) : QString()},
        {"current", track.value("selected").toBool()},
    });
  }

  const QVariantList inFileTracks = embedded();
  QHash<QString, QList<int>> groups;
  QStringList order;
  for (int i = 0; i < m_found.size(); ++i) {
    const QString group = base(m_found[i].toObject()["language"].toString());
    if (!groups.contains(group))
      order.append(group);
    groups[group].append(i);
  }
  QSet<QString> inFile;
  for (const QVariant &t : inFileTracks)
    inFile.insert(base(t.toMap().value("lang").toString()));

  // Every row has every role.
  auto row = [](const QString &kind, const QString &label) {
    return QVariantMap{{"kind", kind},  {"track", QString()},  {"found", -1},
                       {"label", label}, {"detail", QString()}, {"current", false},
                       {"more", 0},      {"group", QString()},  {"indent", false}};
  };
  auto foundRow = [this, row](int index, bool indent) {
    const QJsonObject subtitle = m_found[index].toObject();
    const QString name = subtitle["name"].toString();
    QVariantMap found = row("found", indent && !name.isEmpty() ? name : foundLabel(subtitle));
    found["found"] = index;
    found["detail"] = origin(subtitle);
    found["current"] = isLoaded(subtitle);
    found["indent"] = indent;
    return found;
  };

  QList<QVariantMap> subtitleRows;
  QVariantMap off = row("off", qtTrId("playerOff"));
  off["current"] = selected("sub").isEmpty();
  subtitleRows.append(off);
  QSet<QString> counted;
  for (const QVariant &t : inFileTracks) {
    const QVariantMap track = t.toMap();
    const QString group = base(track.value("lang").toString());
    const QList<int> others = counted.contains(group) ? QList<int>() : groups.value(group);
    counted.insert(group);
    // What tells a track apart: its title, forced or SDH, or the format when
    // two of a language differ in nothing else.
    QSet<QString> formats;
    for (const QVariant &same : inFileTracks)
      if (base(same.toMap().value("lang").toString()) == group)
        formats.insert(same.toMap().value("codec").toString());
    const QString title = track.value("title").toString();
    const QString label = trackLabel(track);
    const QString detail =
        !title.isEmpty() && title.toLower() != label.toLower() ? title
        : track.value("forced").toBool()                      ? qtTrId("playerForced")
        : track.value("hearing-impaired").toBool()            ? QString("SDH")
        : formats.size() > 1 ? format(track.value("codec").toString())
                             : QString();
    QVariantMap own = row("track", label);
    own["track"] = idOf(track);
    own["detail"] = detail;
    own["current"] = track.value("selected").toBool();
    own["more"] = others.size();
    own["group"] = group;
    subtitleRows.append(own);
    if (m_expanded == group)
      for (int index : others)
        subtitleRows.append(foundRow(index, true));
  }
  for (const QString &group : order) {
    if (inFile.contains(group))
      continue;
    const QList<int> all = groups.value(group);
    QVariantMap best = foundRow(all.first(), false);
    best["more"] = all.size() - 1;
    best["group"] = group;
    subtitleRows.append(best);
    if (m_expanded == group)
      for (int index : all.mid(1))
        subtitleRows.append(foundRow(index, true));
  }
  if (m_looking)
    subtitleRows.append(row("note", qtTrId("playerLooking")));
  m_audioRows->set(audioRows);
  m_subtitleRows->set(subtitleRows);

  m_note = m_looking         ? QString()
           : m_lookupFailed  ? qtTrId("playerNoCoreAnswer")
           : !m_found.isEmpty() ? QString()
           : inFileTracks.isEmpty() ? qtTrId("playerOpenSubtitlesNone")
                                    : qtTrId("playerOpenSubtitlesNoMore");
  emit changed();
}
