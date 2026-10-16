// FreeTDS db-lib connectivity spike for the SQL Server (MSSQL) connector.
//
// Proves the hard part of the feature — linking FreeTDS and talking TDS to a
// real SQL Server — in isolation, before any app/UI work. Connection params
// come from the environment (never the command line) so no password lands in
// shell history or process args:
//
//   SQL_HOST (required)  SQL_PORT (default 1433)  SQL_USER (required)
//   SQL_PASS (required)  SQL_DB (optional)        SQL_QUERY (default "SELECT 1")
//
// Build (macOS, Homebrew FreeTDS):
//   clang++ -std=c++17 spike/sql_probe.cpp -I$(brew --prefix freetds)/include \
//     -L$(brew --prefix freetds)/lib -lsybdb -o /tmp/sql_probe
//
// Exit 0 on a successful query, non-zero otherwise.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <sybdb.h>
#include <sybfront.h>

static int handleErr(DBPROCESS*, int, int dberr, int, char* dberrstr, char*)
{
    if (dberrstr)
        std::fprintf(stderr, "db-lib error %d: %s\n", dberr, dberrstr);
    return INT_CANCEL;
}

static int handleMsg(DBPROCESS*, DBINT msgno, int, int severity, char* msgtext,
                     char*, char*, int)
{
    // Severity 0 with msgno 0 is routine chatter; surface real messages.
    if (severity > 0 || msgno != 0)
        std::fprintf(stderr, "server msg %ld (severity %d): %s\n",
                     static_cast<long>(msgno), severity, msgtext ? msgtext : "");
    return 0;
}

static std::string env(const char* k, const char* fallback = "")
{
    const char* v = std::getenv(k);
    return v ? std::string(v) : std::string(fallback);
}

int main()
{
    const std::string host = env("SQL_HOST");
    const std::string port = env("SQL_PORT", "1433");
    const std::string user = env("SQL_USER");
    const std::string pass = env("SQL_PASS");
    const std::string db = env("SQL_DB");
    const std::string query = env("SQL_QUERY", "SELECT 1");

    if (host.empty() || user.empty() || pass.empty()) {
        std::fprintf(stderr, "set SQL_HOST, SQL_USER, SQL_PASS (and optionally "
                             "SQL_PORT, SQL_DB, SQL_QUERY) in the environment\n");
        return 2;
    }

    if (dbinit() == FAIL) {
        std::fprintf(stderr, "dbinit failed\n");
        return 1;
    }
    dberrhandle(handleErr);
    dbmsghandle(handleMsg);

    LOGINREC* login = dblogin();
    if (!login) {
        std::fprintf(stderr, "dblogin failed\n");
        return 1;
    }
    DBSETLUSER(login, user.c_str());
    DBSETLPWD(login, pass.c_str());
    DBSETLAPP(login, "PerchSpike");
    // Modern SQL Server speaks TDS 7.4 (SQL Server 2012+); be explicit so we
    // don't fall back to an ancient default.
    DBSETLVERSION(login, DBVERSION_74);
    if (!db.empty())
        DBSETLDBNAME(login, db.c_str());

    // FreeTDS accepts "host:port" directly, so no freetds.conf entry is needed.
    const std::string server = host + ":" + port;
    DBPROCESS* dbproc = dbopen(login, server.c_str());
    dbloginfree(login);
    if (!dbproc) {
        std::fprintf(stderr, "dbopen failed for %s\n", server.c_str());
        return 1;
    }
    std::fprintf(stderr, "connected to %s\n", server.c_str());

    if (dbcmd(dbproc, query.c_str()) == FAIL || dbsqlexec(dbproc) == FAIL) {
        std::fprintf(stderr, "query submit failed\n");
        dbclose(dbproc);
        return 1;
    }

    RETCODE rc;
    int resultSet = 0;
    long totalRows = 0;
    while ((rc = dbresults(dbproc)) != NO_MORE_RESULTS) {
        if (rc == FAIL) {
            std::fprintf(stderr, "dbresults failed\n");
            dbclose(dbproc);
            return 1;
        }
        const int ncols = dbnumcols(dbproc);
        std::fprintf(stderr, "result set %d: %d column(s)\n", ++resultSet, ncols);

        // Print a header row of column names.
        for (int c = 1; c <= ncols; ++c)
            std::printf("%s%s", c > 1 ? "\t" : "", dbcolname(dbproc, c));
        std::printf("\n");

        // Bind each column to a generous string buffer and stream rows out.
        enum { BUFSZ = 4096 };
        static char cell[64][BUFSZ];
        const int bound = ncols < 64 ? ncols : 64;
        for (int c = 1; c <= bound; ++c)
            dbbind(dbproc, c, NTBSTRINGBIND, BUFSZ, reinterpret_cast<BYTE*>(cell[c - 1]));

        while (dbnextrow(dbproc) != NO_MORE_ROWS) {
            for (int c = 1; c <= bound; ++c)
                std::printf("%s%s", c > 1 ? "\t" : "", cell[c - 1]);
            std::printf("\n");
            ++totalRows;
        }
    }

    std::fprintf(stderr, "ok: %d result set(s), %ld row(s)\n", resultSet, totalRows);
    dbclose(dbproc);
    dbexit();
    return 0;
}
