#include "core.h"
#include "coreconnection.h"
#include "fakecore.h"
#include "folders.h"
#include "pins.h"

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

  // Longer than the request's own transfer timeout, so a slow runner's
  // handshake fails the test only when it would fail the app too.
  static constexpr int answered = 25000;

  QSslConfiguration original = QSslConfiguration::defaultConfiguration();
  QSslCertificate certificate;
  QSslKey key;

  // Serves [server] over TLS with the test's certificate, which this process
  // does not trust until trust(); its address, by number: Windows resolves
  // localhost to ::1 first and takes seconds to give up on a port nobody
  // listens to there.
  QString serveTLS(QHttpServer &server) { return serveTLS(server, certificate, key); }
  QString serveTLS(QHttpServer &server, const QSslCertificate &identity, const QSslKey &secret) {
    QSslConfiguration serverTLS = original;
    serverTLS.setLocalCertificate(identity);
    serverTLS.setPrivateKey(secret);
    serverTLS.setPeerVerifyMode(QSslSocket::VerifyNone);
    auto *listener = new QSslServer(&server);
    listener->setSslConfiguration(serverTLS);
    if (!listener->listen(QHostAddress::LocalHost) || !server.bind(listener))
      return {};
    return QString("https://127.0.0.1:%1").arg(listener->serverPort());
  }

  void trust() {
    QSslConfiguration trusted = original;
    trusted.addCaCertificate(certificate);
    QSslConfiguration::setDefaultConfiguration(trusted);
  }

  // A paired device as a server answers it, in [mode], with [proof] of the
  // code when the device sent one.
  static QHttpServerResponse pairedAnswer(const QString &mode, const QString &proof = {}) {
    QJsonObject answer{{"token", "ABCDEFGHIJKLMNOPQRSTUVW234"}, {"device", QJsonObject{{"id", "laptop"}}}, {"mode", mode}};
    if (!proof.isEmpty())
      answer["proof"] = proof;
    return QHttpServerResponse(answer, QHttpServerResponse::StatusCode::Created);
  }

  // The proofs of pairingCode over the test's certificate, as the core
  // works them out (core/internal/remote/proof.go): the same numbers on
  // both sides, or no device pairs with a core's own certificate.
  static constexpr const char *pairingCode = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  static constexpr const char *deviceProof = "5a8a166afdc7fd54a903320fb4362c6015731eecbad674e1ce72b148433fbce1";
  static constexpr const char *serverProof = "3ab5f6be8cff376ec7cfe5eb563db0dfbfd558f5ccfb135c3be9e6798996adf5";

  // A core with its own certificate, the test's: it pairs a device that
  // proves the code over it, answering in [mode] with its own proof, and
  // keeps what it was sent in [received].
  QString ownCertificateCore(QHttpServer &server, QJsonObject &received, const QString &mode = "full") {
    server.route("/api/v1/pair", QHttpServerRequest::Method::Post, [&received, mode](const QHttpServerRequest &request) {
      received = QJsonDocument::fromJson(request.body()).object();
      if (received.value("proof").toString() != deviceProof)
        return QHttpServerResponse(QHttpServerResponse::StatusCode::Unauthorized);
      return pairedAnswer(mode, serverProof);
    });
    server.route("/healthz", [] { return QHttpServerResponse(QHttpServerResponse::StatusCode::Unauthorized); });
    return serveTLS(server);
  }

  // This machine's core, faked, keeping a link it is handed.
  static void keepsLinks(FakeCore &local, int status = 200) {
    local.on("PUT", "/api/v1/link", [status](const QJsonValue &body) {
      return std::pair{status, QJsonValue(QJsonObject{{"url", body["url"]}, {"running", ""}})};
    });
  }

private slots:
  void initTestCase() {
    QFile identity(LUMEO_TEST_TLS);
    QVERIFY(identity.open(QIODevice::ReadOnly));
    const QByteArray pem = identity.readAll();
    certificate = QSslCertificate(pem);
    key = QSslKey(pem, QSsl::Rsa);
    QVERIFY(!certificate.isNull());
    QVERIFY(!key.isNull());
  }

  void init() {
    qunsetenv("LUMEO_CORE");
  }

  void cleanup() { QSslConfiguration::setDefaultConfiguration(original); }

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
      CoreConnection connection(CoreConnection::file());
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
    QHttpServer server;
    const QString address = serveTLS(server);
    QVERIFY(!address.isEmpty());
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
      return pairedAnswer("full");
    });
    server.route("/stolen", [&] { stolen = true; return QHttpServerResponse("unexpected"); });
    CoreConnection untrusted(temporary.filePath("untrusted/core.json"));
    untrusted.pair(address, "one-time-code", "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!untrusted.busy(), answered);
    // A certificate no authority vouches for gets a proof, never the code,
    // and a server that cannot prove the code back is not kept.
    QVERIFY(!untrusted.error().isEmpty());
    QVERIFY(!untrusted.restartNeeded());
    QVERIFY(!received.contains("code"));
    QVERIFY(received.contains("proof"));
    QVERIFY(CoreConnection::read(temporary.filePath("untrusted/core.json")).isEmpty());
    received = {};
    trust();
    const QString path = temporary.filePath("tls/core.json");
    CoreConnection connection(path);
    connection.pair(address, "one-time-code", "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), answered);
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
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), answered);
    QVERIFY(!connection.error().isEmpty());
    QVERIFY(!stolen);
    QCOMPARE(CoreConnection::read(path), stored);
  }

  // A core serving its own certificate is paired by proving the code over
  // that certificate, which is pinned: the code never leaves this machine,
  // and from then on the core is reached over that certificate alone.
  void pairingWithACoresOwnCertificatePinsIt() {
    QHttpServer server;
    QJsonObject received;
    const QString address = ownCertificateCore(server, received);
    QVERIFY(!address.isEmpty());
    server.route("/api/v1/catalogs", [] { return QHttpServerResponse(QJsonObject{}); });
    const QString path = temporary.filePath("own/core.json");
    CoreConnection connection(path);
    connection.pair(address, pairingCode, "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), answered);
    QVERIFY2(connection.error().isEmpty(), qPrintable(connection.error()));
    QCOMPARE(received, (QJsonObject{{"proof", deviceProof}, {"name", "Laptop"}}));
    const QJsonObject stored = CoreConnection::read(path);
    QCOMPARE(QSslCertificate(stored.value("certificate").toString().toLatin1()), certificate);
    QCOMPARE(stored.value("token").toString(), QString("ABCDEFGHIJKLMNOPQRSTUVW234"));

    Core unpinned(QUrl(address), {});
    QObject context;
    std::optional<bool> reached;
    unpinned.get("/api/v1/catalogs", {}, &context, [&](const Core::Reply &reply) { reached = reply.ok(); });
    QTRY_VERIFY_WITH_TIMEOUT(reached.has_value(), answered);
    QVERIFY(!*reached);
    Pins::add(QUrl(address), certificate);
    Core pinned(QUrl(address), {});
    reached.reset();
    pinned.get("/api/v1/catalogs", {}, &context, [&](const Core::Reply &reply) { reached = reply.ok(); });
    QTRY_VERIFY_WITH_TIMEOUT(reached.has_value(), answered);
    QVERIFY(*reached);
  }

  // The player checks the certificate's name too, so one for another name is
  // turned down before anything is sent, with a reason.
  void pairingRefusesACertificateForAnotherAddress() {
    QFile identity(QFINDTESTDATA("fixtures/lumeo-lan.pem"));
    QVERIFY(identity.open(QIODevice::ReadOnly));
    const QByteArray pem = identity.readAll();
    QHttpServer server;
    int asked = 0;
    server.route("/<arg>", [&asked](const QString &) { ++asked; return QHttpServerResponse(QJsonObject{}); });
    const QString address = serveTLS(server, QSslCertificate(pem), QSslKey(pem, QSsl::Ec));
    QVERIFY(!address.isEmpty());
    CoreConnection connection(temporary.filePath("name/core.json"));
    connection.pair(address, pairingCode, "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), answered);
    QCOMPARE(connection.error(), qtTrId("connectionWrongAddress"));
    QCOMPARE(asked, 0);
  }

  // A media server with its own certificate is handed to this machine's core
  // with the certificate, which that core pins.
  void aMediaServersOwnCertificateGoesWithItsCredential() {
    QHttpServer server;
    QJsonObject received;
    const QString address = ownCertificateCore(server, received, "media");
    QVERIFY(!address.isEmpty());
    FakeCore local;
    QVERIFY(local.listen());
    keepsLinks(local);
    Core core(local.address(), {});
    CoreConnection connection(temporary.filePath("own-media/core.json"), nullptr, &core);
    connection.pair(address, pairingCode, "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), answered);
    QVERIFY2(connection.error().isEmpty(), qPrintable(connection.error()));
    const QJsonObject handed = QJsonDocument::fromJson(local.requests().last().section(' ', 2, -1).toUtf8()).object();
    QCOMPARE(QSslCertificate(handed.value("certificate").toString().toLatin1()), certificate);
  }

  // A media server keeps none of the viewer's data, so the client does not
  // talk to it: the credential goes to this machine's core, and core.json
  // never holds it. A server remembered before is kept, not used.
  void pairingWithAMediaServerHandsTheCredentialToThisMachinesCore() {
    QHttpServer server;
    const QString address = serveTLS(server);
    QVERIFY(!address.isEmpty());
    server.route("/api/v1/pair", QHttpServerRequest::Method::Post,
                 [](const QHttpServerRequest &) { return pairedAnswer("media"); });
    trust();
    FakeCore local;
    QVERIFY(local.listen());
    Core core(local.address(), {});
    const QString path = temporary.filePath("media/core.json");
    write(path, saved());

    keepsLinks(local, 409);
    CoreConnection refused(path, nullptr, &core);
    refused.pair(address, "one-time-code", "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!refused.busy(), answered);
    QVERIFY(!refused.error().isEmpty());
    QVERIFY(refused.server().isEmpty());
    QCOMPARE(CoreConnection::read(path), saved());

    keepsLinks(local);
    CoreConnection connection(path, nullptr, &core);
    QSignalSpy paired(&connection, &CoreConnection::paired);
    connection.pair(address, "one-time-code", "Laptop");
    QTRY_VERIFY_WITH_TIMEOUT(!connection.busy(), answered);
    QVERIFY2(connection.error().isEmpty(), qPrintable(connection.error()));
    QCOMPARE(paired.count(), 1);
    const QJsonObject handed = QJsonDocument::fromJson(
        local.requests().last().section(' ', 2, -1).toUtf8()).object();
    QCOMPARE(handed, (QJsonObject{{"url", address}, {"token", "ABCDEFGHIJKLMNOPQRSTUVW234"}}));
    QCOMPARE(connection.server(), address);
    QVERIFY(!connection.remote());
    QVERIFY(connection.restartNeeded());
    QJsonObject kept = saved();
    kept["enabled"] = false;
    QCOMPARE(CoreConnection::read(path), kept);
  }

  // A full server used directly that turns into a media server hands over
  // the credential in use, and is no longer used directly. Its answers saying
  // full change nothing.
  void aServerThatBecomesAMediaServerIsReachedThroughThisMachinesCore() {
    const QString path = temporary.filePath("follow/core.json");
    write(path, saved());
    FakeCore server;
    QVERIFY(server.listen());
    server.answer("GET", "/api/v1/catalogs", 200, QJsonObject{});
    FakeCore local;
    QVERIFY(local.listen());
    keepsLinks(local);
    Core app(server.address(), {});
    Core core(local.address(), {});
    CoreConnection connection(path, &app, &core);
    QObject context;
    int answers = 0;
    server.mode = "full";
    app.get("/api/v1/catalogs", {}, &context, [&](const Core::Reply &) { ++answers; });
    QTRY_COMPARE(answers, 1);
    server.mode = "media";
    app.get("/api/v1/catalogs", {}, &context, [&](const Core::Reply &) { ++answers; });
    QTRY_VERIFY(!connection.server().isEmpty());
    QVERIFY(!connection.busy());
    QCOMPARE(local.requests().size(), 1);
    QCOMPARE(QJsonDocument::fromJson(local.requests().first().section(' ', 2, -1).toUtf8()).object(),
             (QJsonObject{{"url", "https://lumeo.example.com"}, {"token", "ABCDEFGHIJKLMNOPQRSTUVW234"}}));
    QVERIFY(CoreConnection::read(path).isEmpty());
    QVERIFY(connection.restartNeeded());
  }

  // This machine's core says which media server it forwards to now and which
  // from its next start; a restart is due while they differ.
  void theLinkOfThisMachinesCoreAsksForARestartUntilItIsInUse() {
    FakeCore local;
    QVERIFY(local.listen());
    Core core(local.address(), {});
    const QString media = "https://media.example.com";
    local.answer("GET", "/api/v1/link", 200, QJsonObject{{"url", media}, {"running", media}});
    local.answer("DELETE", "/api/v1/link", 200, QJsonObject{{"url", ""}, {"running", media}});
    CoreConnection connection(temporary.filePath("link/core.json"), nullptr, &core);
    connection.readLink();
    QTRY_COMPARE(connection.server(), media);
    QVERIFY(!connection.restartNeeded());
    connection.unlink();
    QTRY_VERIFY(connection.server().isEmpty());
    QVERIFY(!connection.busy());
    QVERIFY(connection.restartNeeded());
  }
};

QTEST_GUILESS_MAIN(ConnectionTest)
#include "connection_test.moc"
