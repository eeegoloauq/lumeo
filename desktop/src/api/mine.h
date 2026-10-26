#pragma once

#include <QObject>
#include <QQmlParserStatus>
#include <QtQml/qqmlregistration.h>

class Core;

// What the viewer keeps and thinks of one title: whether it is on My list,
// and their score of it. Both change at once and are sent behind the
// change, since a button that waited on the core would read as a click that
// missed; one the core refuses is put back and says so.
class Mine : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(QString itemId MEMBER m_itemId NOTIFY changed)
  // The core has said; until then the buttons stay off, since a core that
  // cannot say whether the title is on the list cannot be told to change it.
  Q_PROPERTY(bool known READ known NOTIFY changed)
  Q_PROPERTY(bool inList READ inList NOTIFY changed)
  // 1 to 10, 0 when not scored.
  Q_PROPERTY(int score READ score NOTIFY changed)

public:
  explicit Mine(QObject *parent = nullptr) : QObject(parent) {}
  Mine(Core *core, const QString &itemId, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  bool known() const { return m_known; }
  bool inList() const { return m_inList; }
  int score() const { return m_score; }

  // Clicks flip the list at once and are sent one at a time, each after the
  // core answered the last: two in flight could land in either order and
  // leave the core on the opposite of what the button shows.
  Q_INVOKABLE void toggle();
  Q_INVOKABLE void rate(int score);
  Q_INVOKABLE void clear();

signals:
  void changed();
  // What did not take: "add", "remove", "rate" or "clear".
  void refused(const QString &what);

private:
  void load();
  void sendList();
  void readList();

  Core *m_core = nullptr;
  QString m_itemId;
  bool m_known = false;
  bool m_inList = false;
  // What the core last said about My list, which m_inList runs ahead of.
  bool m_saved = false;
  bool m_sending = false;
  int m_score = 0;
};
