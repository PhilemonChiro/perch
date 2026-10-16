#pragma once

#include <QClipboard>
#include <QGuiApplication>
#include <QObject>
#include <QQmlEngine>

// Minimal QML-accessible clipboard writer (QtQuick.Controls.Basic exposes no
// clipboard for arbitrary strings). Used to copy result cells/rows.
class Clipboard : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Clipboard(QObject* parent = nullptr) : QObject(parent) {}
    Q_INVOKABLE void copy(const QString& text) const
    {
        if (auto* cb = QGuiApplication::clipboard())
            cb->setText(text);
    }
};
