#pragma once

#include <QImage>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QtQml/qqmlregistration.h>
#include <optional>

class FrameGrabber;

// The seek bar's preview frames, from an mpv of their own on the same stream:
// there is no server to make them in advance, and decoding the whole file
// for pictures nobody points at would cost more than the 25 ms each takes on
// demand. Nothing starts until the pointer first reaches the bar, a newer
// position replaces one still waiting, and none is kept (decisions/player.md).
class Previews : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_UNCREATABLE("a Playback's")
  // The latest frame while the pointer is on the bar; null otherwise.
  Q_PROPERTY(QImage frame READ frame NOTIFY frameChanged)
  // Its size, empty while there is none.
  Q_PROPERTY(QSize frameSize READ frameSize NOTIFY frameChanged)

public:
  Previews(const QString &url, const QStringList &headers, QObject *parent = nullptr);
  ~Previews() override;

  QImage frame() const { return m_frame; }
  QSize frameSize() const { return m_frame.size(); }

  Q_INVOKABLE void show(double seconds);
  Q_INVOKABLE void hide();

signals:
  void frameChanged();

private:
  void next();

  QString m_url;
  QStringList m_headers;
  FrameGrabber *m_grabber = nullptr;
  std::optional<double> m_wanted;
  // Until the file is loaded, and for good if it fails to.
  bool m_busy = true;
  bool m_shown = false;
  QImage m_frame;
};

// The previews' frame drawn as it is, the item's size: an image node of the
// scene graph's, no painting in between. It takes the previews rather than
// the frame, since a QImage property cannot be told "none" from QML.
class FrameView : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(Previews *previews READ previews WRITE setPreviews NOTIFY previewsChanged)

public:
  explicit FrameView(QQuickItem *parent = nullptr);

  Previews *previews() const { return m_previews; }
  void setPreviews(Previews *previews);

signals:
  void previewsChanged();

protected:
  QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
  void take();

  QPointer<Previews> m_previews;
  QImage m_image;
  bool m_changed = false;
};
