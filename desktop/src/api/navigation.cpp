#include "navigation.h"

#include "core.h"
#include "home.h"
#include "library.h"
#include "search.h"
#include "settings.h"

#include <QQmlEngine>

Navigation::Navigation(QObject *parent) : QObject(parent) {}

Navigation::Navigation(Core *core, const QString &startPage, QObject *parent)
    : QObject(parent), m_core(core) {
  start(startPage);
}

void Navigation::classBegin() {
  QQmlEngine *engine = qmlEngine(this);
  m_core = engine->singletonInstance<Core *>("Lumeo", "Core");
  start(engine->singletonInstance<LocalSettings *>("Lumeo", "LocalSettings")->startPage());
}

void Navigation::start(const QString &startPage) {
  m_home = new Home(m_core, this);
  m_search = new Search(m_core, this);
  m_places = {{{"page", "home"}}};
  if (startPage == "list")
    m_places.append({{"page", "library"}});
}

MyList *Navigation::list() {
  if (!m_list)
    m_list = new MyList(m_core, this);
  return m_list;
}

QVariantMap Navigation::at(int index) const { return m_places.value(index); }

int Navigation::find(const QString &page) const {
  for (qsizetype i = m_places.size() - 1; i >= 0; --i)
    if (m_places[i]["page"] == page)
      return int(i);
  return -1;
}

void Navigation::open(const QVariantMap &place) {
  m_places.append(place);
  emit moved(depth() - 1);
  m_places.last().remove("play");
}

void Navigation::go(const QVariantMap &place) {
  const QString page = place["page"].toString();
  const int at = page == "home" ? 0 : find(page);
  if (at >= 0)
    popTo(at);
  else
    open(place);
}

void Navigation::openFromOutside(const QVariantMap &item) {
  const QVariantMap place{{"page", "title"}, {"item", item}, {"outside", true}};
  if (depth() > 1 && m_places.last()["outside"].toBool()) {
    m_places.last() = place;
    emit moved(depth() - 1);
    return;
  }
  open(place);
}

void Navigation::back() {
  if (depth() > 1)
    popTo(depth() - 2);
}

void Navigation::popTo(int index) {
  if (index >= depth() - 1)
    return;
  m_places.resize(index + 1);
  emit moved(depth());
}
