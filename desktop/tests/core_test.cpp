#include "core.h"
#include "fakecore.h"

#include <QJsonObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>
#include <optional>

class CoreTest : public QObject {
  Q_OBJECT

  QTemporaryDir dir;
  QString tokenFile() const { return dir.filePath("api-token"); }
  void writeToken(const QByteArray &token) {
    QFile file(tokenFile());
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(token + "\n");
  }

  // The core's answer to one GET, once it came.
  static Core::Reply ask(Core &core, const QString &path = "/healthz") {
    std::optional<Core::Reply> got;
    core.get(path, {}, &core, [&](const Core::Reply &reply) { got = reply; });
    if (!QTest::qWaitFor([&] { return got.has_value(); }, 10000))
      qFatal("no answer to %s", qPrintable(path));
    return *got;
  }

  // A port nothing listens on.
  static quint16 freePort() {
    QTcpServer probe;
    probe.listen(QHostAddress::LocalHost);
    return probe.serverPort();
  }

private slots:
  void init() { QFile::remove(tokenFile()); }

  void everyRequestCarriesTheTokenFromTheFile() {
    writeToken("abc");
    FakeCore fake;
    QVERIFY(fake.listen());
    fake.token = "abc";
    fake.answer("GET", "/healthz", 200, QJsonObject{{"status", "ok"}});
    Core core(fake.address(), tokenFile());
    QCOMPARE(ask(core).status, 200);
    QCOMPARE(ask(core).status, 200);
    QCOMPARE(fake.requests().size(), 2);
    QCOMPARE(core.headers(), QStringList{"Authorization: Bearer abc"});
  }

  void aCoreThatWroteItsTokenAfterTheClientLookedIsAskedAgain() {
    FakeCore fake;
    QVERIFY(fake.listen());
    fake.token = "new";
    fake.answer("GET", "/healthz", 200, QJsonObject{{"status", "ok"}});
    Core core(fake.address(), tokenFile());
    QVERIFY(core.headers().isEmpty());
    writeToken("new");
    QCOMPARE(ask(core).status, 200);
    QCOMPARE(fake.requests().size(), 2);
  }

  void aRefusedTokenThatHasNotChangedIsAnErrorSentOnce() {
    writeToken("stale");
    FakeCore fake;
    QVERIFY(fake.listen());
    fake.token = "other";
    Core core(fake.address(), tokenFile());
    const Core::Reply reply = ask(core);
    QCOMPARE(reply.status, 401);
    QCOMPARE(reply.message(), "missing or wrong api token");
    QCOMPARE(fake.requests().size(), 1);
  }

  void theLocalCoreAloneIsSentTheLocalToken() {
    qputenv("LUMEO_CORE", "http://192.0.2.1:7666");
    QVERIFY(Core().tokenPath().isEmpty());
    qunsetenv("LUMEO_CORE");
    QVERIFY(Core().tokenPath().endsWith("/api-token"));
    QCOMPARE(Core().address(), Core::local);
  }

  void theDataDirectoryIsTheOneTheCorePicks() {
    qputenv("LUMEO_DATA", "/srv/lumeo");
    QCOMPARE(Core::dataDir(), "/srv/lumeo");
    qunsetenv("LUMEO_DATA");
#ifndef Q_OS_WIN
    const QByteArray xdg = qgetenv("XDG_DATA_HOME");
    qputenv("XDG_DATA_HOME", "/x");
    QCOMPARE(Core::dataDir(), "/x/lumeo");
    qunsetenv("XDG_DATA_HOME");
    QCOMPARE(Core::dataDir(), QDir::homePath() + "/.local/share/lumeo");
    if (!xdg.isEmpty())
      qputenv("XDG_DATA_HOME", xdg);
#endif
  }

  void idsAreOnePathSegmentAndPathsResolveAgainstTheAddress() {
    Core core(Core::local, {});
    QCOMPARE(core.url("/api/v1/downloads/" + Core::segment("a/b") + "/stream").toString(),
             "http://127.0.0.1:7666/api/v1/downloads/a%2Fb/stream");
  }

  void aRequestRefusedWhileTheCoreStartsIsSentAgainBodyAndAll() {
    const quint16 port = freePort();
    Core core(QUrl(QString("http://127.0.0.1:%1").arg(port)), {});
    core.firstDelay = 10;
    FakeCore fake;
    fake.on("PATCH", "/api/v1/preferences",
            [](const QJsonValue &body) { return std::pair{200, body}; });
    std::optional<Core::Reply> got;
    core.send("PATCH", "/api/v1/preferences", {}, QJsonObject{{"accent", "white"}}, &core,
              [&](const Core::Reply &reply) { got = reply; });
    QTest::qWait(100);
    QVERIFY(!got);
    QVERIFY(fake.listen(port));
    QTRY_VERIFY(got.has_value());
    QCOMPARE(got->status, 200);
    QCOMPARE(got->json()["accent"].toString(), "white");
  }

  void aCoreThatNeverListensIsGivenUpOnAfterThePatience() {
    Core core(QUrl(QString("http://127.0.0.1:%1").arg(freePort())), {});
    core.patience = 100;
    core.firstDelay = 10;
    const Core::Reply reply = ask(core);
    QCOMPARE(reply.status, 0);
    QVERIFY(!reply.message().isEmpty());
  }

  void anyOtherFailureIsNotWaitedOut() {
    // A server that takes the connection and drops it. Qt's own resending of
    // a dropped GET is quick; ours would wait the first delay.
    QTcpServer dropping;
    QVERIFY(dropping.listen(QHostAddress::LocalHost));
    connect(&dropping, &QTcpServer::newConnection, this,
            [&] { dropping.nextPendingConnection()->abort(); });
    Core core(QUrl(QString("http://127.0.0.1:%1").arg(dropping.serverPort())), {});
    core.firstDelay = 5000;
    QElapsedTimer took;
    took.start();
    QCOMPARE(ask(core).status, 0);
    QVERIFY(took.elapsed() < 2000);
  }

  void theCoresExplanationIsTheMessage() {
    QCOMPARE((Core::Reply{400, R"({"error":"no such addon"})", {}}).message(), "no such addon");
    QCOMPARE((Core::Reply{502, "Bad Gateway\n", {}}).message(), "Bad Gateway");
  }
};

QTEST_GUILESS_MAIN(CoreTest)
#include "core_test.moc"
