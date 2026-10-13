#pragma once

#include <QString>

#include <functional>

// Passwords live in the OS keychain (Windows Credential Manager, macOS
// Keychain, libsecret on Linux), keyed by saved-connection id.
namespace Credentials {

void read(const QString& key, std::function<void(bool found, const QString& password)> done);
void write(const QString& key, const QString& password);
void remove(const QString& key);

} // namespace Credentials
