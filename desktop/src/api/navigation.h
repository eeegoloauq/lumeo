#pragma once

#include <QList>
#include <QObject>
#include <QQmlParserStatus>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

#include "home.h"
#include "library.h"
#include "search.h"

class Core;

// Where the viewer is among the window's pages (decisions/interface.md,
// Back): the stack of places, Home at the bottom, each a page's name and
// what it was opened with, {page: "title", item, at}. It is kept apart
// from the pages so they can go and be made again where they were; the
// whole shell goes while the window is in the background
// (decisions/performance.md, Hidden is not gone). What those pages show is
// kept with it, so a page made again shows at once: Home's shelves, My list,
// and the search's word and titles.
class Navigation : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(int depth READ depth NOTIFY moved)
  Q_PROPERTY(Home *home READ home CONSTANT)
  // Made the first time the library is shown: most windows never open it.
  Q_PROPERTY(MyList *list READ list CONSTANT)
  Q_PROPERTY(Search *search READ search CONSTANT)

public:
  // The app's Core and start page, from the engine that makes it.
  explicit Navigation(QObject *parent = nullptr);
  // [startPage] as LocalSettings has it: "list" opens on My list, with Home
  // under it as after its tab.
  Navigation(Core *core, const QString &startPage, QObject *parent = nullptr);

  // The pages' data is made here, before anything binds to it.
  void classBegin() override;
  void componentComplete() override {}

  int depth() const { return int(m_places.size()); }
  Home *home() const { return m_home; }
  MyList *list();
  Search *search() const { return m_search; }

  // The place at [index], 0 being Home's; empty past the top.
  Q_INVOKABLE QVariantMap at(int index) const;
  // The index of the topmost place of [page], or -1.
  Q_INVOKABLE int find(const QString &page) const;

  // [place] over the one shown. Its `play` is for the page made now: one made
  // again later does not start the title again.
  Q_INVOKABLE void open(const QVariantMap &place);
  // A tab: Home, or the place of [page] already in the stack gone back to,
  // or [place] opened. Back goes where the viewer went, so a tab is never in
  // the stack twice.
  Q_INVOKABLE void go(const QVariantMap &place);
  // A title from a link or a file opened outside the app, which takes the
  // place of one opened that way on top: following link after link kept a
  // page made for each until Back passed them.
  Q_INVOKABLE void openFromOutside(const QVariantMap &item);
  Q_INVOKABLE void back();

signals:
  // The stack changed: its first [kept] places are as they were, and those
  // over them are new.
  void moved(int kept);

private:
  void start(const QString &startPage);
  void popTo(int index);

  Core *m_core = nullptr;
  QList<QVariantMap> m_places;
  Home *m_home = nullptr;
  MyList *m_list = nullptr;
  Search *m_search = nullptr;
};
