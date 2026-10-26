#include "desktop.h"

#include "folders.h"

#include <QClipboard>
#include <QFileDialog>
#include <QGuiApplication>
#include <QSysInfo>
#include <QWindow>

namespace {

void ask(QFileDialog::FileMode mode, const QString &title, const QString &start, QJSValue done) {
  auto *dialog = new QFileDialog(nullptr, title, start);
  dialog->setFileMode(mode);
  dialog->setAttribute(Qt::WA_DeleteOnClose);
  // Over the window it was asked from: the dialog has no parent widget, and
  // the system's dialog takes its parent from the transient parent, set on
  // the handle winId() makes.
  dialog->winId();
  dialog->windowHandle()->setTransientParent(QGuiApplication::focusWindow());
  QObject::connect(dialog, &QFileDialog::fileSelected, dialog,
                   [done](const QString &path) mutable { done.call({path}); });
  dialog->open();
}

} // namespace

QString Desktop::system() const {
  return QSysInfo::prettyProductName() + ", " + QSysInfo::kernelType() + " " + QSysInfo::kernelVersion();
}

QString Desktop::playerLog() const { return Folders::playerLog(); }

void Desktop::copy(const QString &text) const { QGuiApplication::clipboard()->setText(text); }

void Desktop::pickFolder(const QString &title, const QString &start, const QJSValue &done) const {
  ask(QFileDialog::Directory, title, start, done);
}

void Desktop::pickFile(const QString &title, const QJSValue &done) const {
  ask(QFileDialog::ExistingFile, title, QString(), done);
}
