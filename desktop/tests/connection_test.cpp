#include "core.h"
#include "coreconnection.h"
#include "folders.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QHttpServer>
#include <QHttpServerResponse>
#include <QSignalSpy>
#include <QScopeGuard>
#include <QSslCertificate>
#include <QSslConfiguration>
#include <QSslKey>
#include <QSslServer>
#include <QTemporaryDir>
#include <QtTest>

class ConnectionTest : public QObject {
  Q_OBJECT

  QTemporaryDir temporary;

  void write(const QString &path, const QJsonObject &object) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QVERIFY(file.write(QJsonDocument(object).toJson()) > 0);
  }

  QJsonObject saved() const {
    return {{"address", "https://lumeo.example.com"}, {"token", "ABCDEFGHIJKLMNOPQRSTUVW234"},
            {"deviceId", "laptop"}, {"enabled", true}};
  }

private slots:
  void init() {
    qunsetenv("LUMEO_CORE");
  }

  void pairingRequiresAnHTTPSOriginBeforeSendingAnything() {
    CoreConnection connection(temporary.filePath("invalid.json"));
    for (const QString &address : {"http://example.com", "https://user:secret@example.com", "https://example.com/api", "https://example.com?query", "https://example.com#fragment"}) {
      connection.pair(address, "one-time-code", "Laptop");
      QVERIFY(!connection.error().isEmpty());
      QVERIFY(!connection.busy());
      QVERIFY(!connection.restartNeeded());
    }
    QCOMPARE(CoreConnection::origin(" https://lumeo.example.com/ "), QUrl("https://lumeo.example.com"));
  }

  void switchingKeepsCredentialsPrivateAndOnlyChangesTheNextLaunch() {
    const QString path = temporary.filePath("switch/core.json");
    write(path, saved());
    CoreConnection connection(path);
    QVERIFY(connection.remote());
    QVERIFY(!connection.restartNeeded());
    connection.useLocal();
    QVERIFY(!connection.remote());
    QVERIFY(connection.restartNeeded());
    const auto stored = CoreConnection::read(path);
    QCOMPARE(stored.value("token"), saved().value("token"));
#ifndef Q_OS_WIN
    const auto permissions = QFile::permissions(path);
    QVERIFY(!(permissions & (QFile::ReadGroup | QFile::WriteGroup | QFile::ReadOther | QFile::WriteOther)));
#endif
    connection.useRemote();
    QVERIFY(connection.remote());
    QVERIFY(!connection.restartNeeded());
    connection.forget();
    QVERIFY(CoreConnection::read(path).isEmpty());
    QVERIFY(connection.address().isEmpty());
    QVERIFY(connection.restartNeeded());
  }

  void theSavedCredentialNeverFollowsAnEnvironmentOverride() {
    const QByteArray previous = qgetenv("XDG_CONFIG_HOME");
    qputenv("XDG_CONFIG_HOME", temporary.filePath("startup").toUtf8());
#ifdef Q_OS_WIN
    const QByteArray appData = qgetenv("APPDATA");
    qputenv("APPDATA", temporary.filePath("startup").toUtf8());
#endif
    write(CoreConnection::file(), saved());
    {
      Core core;
      QCOMPARE(core.address(), QUrl("https://lumeo.example.com"));
      QCOMPARE(core.headers(), QStringList{"Authorization: Bearer ABCDEFGHIJKLMNOPQRSTUVW234"});
    }
    qputenv("LUMEO_CORE", "https://another.example.com");
    {
      Core core;
      QCOMPARE(core.address(), QUrl("https://another.example.com"));
      QVERIFY(core.headers().isEmpty());
      CoreConnection connection;
      QVERIFY(connection.overridden());
    }
    qunsetenv("LUMEO_CORE");
    qputenv("XDG_CONFIG_HOME", previous);
#ifdef Q_OS_WIN
    qputenv("APPDATA", appData);
#endif
  }

  void aFailedSaveKeepsThePreviousConnection() {
    const QString path = temporary.filePath("is-a-directory");
    QVERIFY(QDir().mkpath(path));
    CoreConnection connection(path);
    connection.useLocal();
    QVERIFY(!connection.error().isEmpty());
    QVERIFY(!connection.restartNeeded());
  }

  void pairingOverVerifiedTLSStoresOnlyTheIssuedDeviceCredential() {
    QFile identity(LUMEO_TEST_TLS);
    QVERIFY(identity.open(QIODevice::ReadOnly));
    const QByteArray pem = identity.readAll();
    const QSslCertificate certificate(pem);
    const QSslKey key(pem, QSsl::Rsa);
    QVERIFY(!certificate.isNull());
    QVERIFY(!key.isNull());
    const QSslConfiguration original = QSslConfiguration::defaultConfiguration();
    QSslConfiguration trusted = original;
    trusted.addCaCertificate(certificate);
    const auto restore = qScopeGuard([original] { QSslConfiguration::setDefaultConfiguration(original); });
    QSslConfiguration serverTLS = original;
    serverTLS.setLocalCertificate(certificate);
    serverTLS.setPrivateKey(key);
    serverTLS.setPeerVerifyMode(QSslSocket::VerifyNone);
    QHttpServer server;
    auto *listener = new QSslServer(&server);
    listener->setSslConfiguration(serverTLS);
    QVERIFY(listener->listen(QHostAddress::LocalHost));
    QVERIFY(server.bind(listener));
    bool redirect = false;
    bool stolen = false;
    QJsonObject received;
    server.route("/api/v1/pair", QHttpServerRequest::Method::Post,
                 [&](const QHttpServerRequest &request) {
      received = QJsonDocument::fromJson(request.body()).object();
      if (redirect) {
        QHttpServerResponse response(QHttpServerResponse::StatusCode::Found);
        auto headers = response.headers();
        headers.append("Location", "/stolen");
        response.setHeaders(headers);
        return response;
      }
      return QHttpServerResponse(QJsonObject{{"token", "ABCDEFGHIJKLMNOPQRSTUVW234"},
          {"device", QJsonObject{{"id", "laptop"}}}}, QHttpServerResponse::StatusCode::Created);
    });
    server.route("/stolen", [&] { stolen = true; return QHttpServerResponse("unexpected"); });
    const QString address = QString("https://localhost:%1").arg(listener->serverPort());
    CoreConnection untrusted(temporary.filePath("untrusted/core.json"));
    untrusted.pair(address, "one-time-code", "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!untrusted.busy(), 5000);
    QVERIFY(!untrusted.error().isEmpty());
    QVERIFY(!untrusted.restartNeeded());
    QVERIFY(received.isEmpty());
    QSslConfiguration::setDefaultConfiguration(trusted);
    const QString path = temporary.filePath("tls/core.json");
    CoreConnection connection(path);
    connection.pair(address, "one-time-code", "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), 5000);
    QVERIFY2(connection.error().isEmpty(), qPrintable(connection.error()));
    QCOMPARE(received.value("code").toString(), QString("one-time-code"));
    QCOMPARE(received.value("name").toString(), QString("Laptop"));
    const auto stored = CoreConnection::read(path);
    QCOMPARE(stored.value("token").toString(), QString("ABCDEFGHIJKLMNOPQRSTUVW234"));
    QVERIFY(!stored.contains("code"));
    QVERIFY(connection.remote());
    QVERIFY(connection.restartNeeded());
    redirect = true;
    connection.pair(address, "another-code", "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), 5000);
    QVERIFY(!connection.error().isEmpty());
    QVERIFY(!stolen);
    QCOMPARE(CoreConnection::read(path), stored);
  }
};

QTEST_GUILESS_MAIN(ConnectionTest)
#include "connection_test.moc"
