#include "MacPasteboard.h"

// Non-macOS fallbacks; the real implementation is MacPasteboard.mm.
#include <QDesktopServices>
#include <QFileInfo>
#include <QUrl>

namespace MacPasteboard {

bool isConcealed() { return false; }
bool reduceMotion() { return false; }
void revealInFinder(const QStringList& paths)
{
    if (!paths.isEmpty())
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(paths.first()).absolutePath()));
}

} // namespace MacPasteboard
