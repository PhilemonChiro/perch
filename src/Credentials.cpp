#include "Credentials.h"

#include <qt6keychain/keychain.h>

namespace {
const QString kService = QStringLiteral("io.relay.app");
}

namespace Credentials {

void read(const QString& key, std::function<void(bool, const QString&)> done)
{
    auto* job = new QKeychain::ReadPasswordJob(kService);
    job->setAutoDelete(true);
    job->setKey(key);
    QObject::connect(job, &QKeychain::Job::finished, [done = std::move(done)](QKeychain::Job* j) {
        auto* r = static_cast<QKeychain::ReadPasswordJob*>(j);
        const bool ok = r->error() == QKeychain::NoError;
        done(ok, ok ? r->textData() : QString());
    });
    job->start();
}

void write(const QString& key, const QString& password)
{
    auto* job = new QKeychain::WritePasswordJob(kService);
    job->setAutoDelete(true);
    job->setKey(key);
    job->setTextData(password);
    job->start();
}

void remove(const QString& key)
{
    auto* job = new QKeychain::DeletePasswordJob(kService);
    job->setAutoDelete(true);
    job->setKey(key);
    job->start();
}

} // namespace Credentials
