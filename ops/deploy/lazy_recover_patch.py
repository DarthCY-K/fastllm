#!/usr/bin/env python3
"""lazy-recover patch：DiskPrefixCache 启动恢复惰性化 + 进度遥测。幂等；锚点计数不唯一则中止。"""
import sys

W = "/home/ai-agent/builds/upgrade-test/wt-lazy"
C = W + "/src/utils/disk_prefix_cache.cpp"
M = W + "/CMakeLists.txt"


def sub_once(text, old, new, tag):
    n = text.count(old)
    if n != 1:
        sys.exit("anchor %s count=%d -> abort" % (tag, n))
    return text.replace(old, new)


s = open(C, encoding="utf-8").read()
if "IndexUsable" in s:
    print("already patched")
    sys.exit(0)

s = sub_once(s, "#include <fcntl.h>\n#include <poll.h>",
             "#include <fcntl.h>\n#include <fstream>\n#include <poll.h>", "fstream")
s = sub_once(s, "#include <cerrno>\n", "#include <cerrno>\n#include <cstdlib>\n", "cstdlib")

s = sub_once(s, """        SyncDirectory(root); SyncDirectory(base);
        Recover();
        connector.reset(new lmcache::connector::FSConnector(transport.string(), workers, "", false));""",
"""        SyncDirectory(root); SyncDirectory(base);
        if (IndexUsable()) {
            printf("[Prefix SSD] index ok: fast startup, full recovery skipped.\\n"); fflush(stdout);
            WriteProgress(Json::object{{"phase", "fast-skip"}, {"started_ns", (double)NowNs()},
                {"updated_ns", (double)NowNs()}, {"detail", "existing index accepted"}});
        } else {
            Recover();
        }
        connector.reset(new lmcache::connector::FSConnector(transport.string(), workers, "", false));""",
             "ctor")

s = sub_once(s, """            Lease lease(root / ".lease", LOCK_EX | LOCK_NB);
            Recover();
            Lease metadata(root / ".metadata", LOCK_EX);""",
"""            Lease lease(root / ".lease", LOCK_EX | LOCK_NB);
            if (!IndexUsable()) Recover();
            Lease metadata(root / ".metadata", LOCK_EX);""",
             "maintain")

s = sub_once(s, """    void Recover() {
        // Caller owns exclusive lifecycle lease,""",
"""    bool ForceRecover() const {
        const char *value = std::getenv("FASTLLM_PREFIX_CACHE_FORCE_RECOVER");
        return value != nullptr && value[0] != '\\0' && std::string(value) != "0";
    }
    bool IndexUsable() {
        if (ForceRecover()) return false;
        try {
            Database db(dbPath);
            Statement check(db.value, "PRAGMA quick_check");
            if (!(check.Row() && check.Text(0) == "ok")) return false;
            if (db.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN "
                          "('objects','checkpoints','refs')") != 3) return false;
            if (db.Scalar("SELECT COUNT(*) FROM intents") != 0) return false;
            return true;
        } catch (...) { return false; }
    }
    void WriteProgress(const Json &state) const {
        try {
            auto path = base / "recover-progress.json";
            auto temporary = path.string() + ".tmp";
            { std::ofstream out(temporary, std::ios::binary | std::ios::trunc); out << state.dump(); }
            fs::rename(temporary, path);
        } catch (...) {}
    }
    void Recover() {
        // Caller owns exclusive lifecycle lease,""",
             "helpers")

s = sub_once(s, """        Schema(*db);
        db->Exec("DELETE FROM refs; DELETE FROM checkpoints; DELETE FROM objects; DELETE FROM reservations; DELETE FROM intents;");
        std::set<std::string> reachable;
        for (const auto &directory : fs::directory_iterator(commits)) {
            if (!directory.is_directory() || directory.is_symlink() || !IsDigest(directory.path().filename().string())) continue;
            auto id = directory.path().filename().string();""",
"""        Schema(*db);
        db->Exec("DELETE FROM refs; DELETE FROM checkpoints; DELETE FROM objects; DELETE FROM reservations; DELETE FROM intents;");
        std::set<std::string> reachable;
        std::uint64_t totalCommits = 0, doneCommits = 0, refsChecked = 0, objectsRemoved = 0;
        for (const auto &directory : fs::directory_iterator(commits)) {
            if (!directory.is_directory() || directory.is_symlink() || !IsDigest(directory.path().filename().string())) continue;
            for (const auto &file : fs::directory_iterator(directory.path()))
                if (file.is_regular_file() && !file.is_symlink() && file.path().extension() == ".commit") ++totalCommits;
        }
        const auto recoveryStarted = NowNs();
        auto progress = [&](const char *phase, const char *detail) {
            WriteProgress(Json::object{{"phase", phase}, {"commits_done", (double)doneCommits},
                {"commits_total", (double)totalCommits}, {"refs_checked", (double)refsChecked},
                {"objects_removed", (double)objectsRemoved}, {"started_ns", (double)recoveryStarted},
                {"updated_ns", (double)NowNs()}, {"detail", detail}});
        };
        progress("recover", "start");
        printf("[Prefix SSD] full recovery starting: commits=%llu (index missing or dirty).\\n",
               (unsigned long long)totalCommits); fflush(stdout);
        for (const auto &directory : fs::directory_iterator(commits)) {
            if (!directory.is_directory() || directory.is_symlink() || !IsDigest(directory.path().filename().string())) continue;
            auto id = directory.path().filename().string();""",
             "precount")

s = sub_once(s, """                try {
                    record = LoadRecord(file.path(), id, key);
                    CollectRefs(record["objects"], refs);
                    for (const auto &ref : refs) Check(HeaderValid(ref.first, ref.second), "incomplete_checkpoint");
                } catch (...) { fs::remove(file.path()); continue; }
                // SQL/storage failures abort maintenance, never delete an
                // otherwise valid commit merely because indexing failed.
                IndexRecord(*db, record, FileSize(file.path()));
                for (const auto &ref : refs) reachable.insert(BlobFilename(ref.first));
            }
            SyncDirectory(directory.path());""",
"""                try {
                    record = LoadRecord(file.path(), id, key);
                    CollectRefs(record["objects"], refs);
                    for (const auto &ref : refs) {
                        Check(HeaderValid(ref.first, ref.second), "incomplete_checkpoint");
                        ++refsChecked;
                    }
                } catch (...) { fs::remove(file.path()); ++doneCommits; progress("recover", "pruned invalid commit"); continue; }
                // SQL/storage failures abort maintenance, never delete an
                // otherwise valid commit merely because indexing failed.
                IndexRecord(*db, record, FileSize(file.path()));
                for (const auto &ref : refs) reachable.insert(BlobFilename(ref.first));
                ++doneCommits;
                if (doneCommits % 4 == 0 || doneCommits == totalCommits) progress("recover", "indexing commits");
            }
            SyncDirectory(directory.path());""",
             "percommit")

s = sub_once(s, """        for (const auto &file : fs::directory_iterator(transport)) {
            if (file.is_regular_file() && !file.is_symlink() && !reachable.count(file.path().filename().string())) fs::remove(file.path());
        }
        SyncDirectory(transport); SyncDirectory(commits);
        db->Exec("PRAGMA wal_checkpoint(TRUNCATE)");
    }""",
"""        for (const auto &file : fs::directory_iterator(transport)) {
            if (file.is_regular_file() && !file.is_symlink() && !reachable.count(file.path().filename().string())) {
                fs::remove(file.path());
                ++objectsRemoved;
            }
        }
        SyncDirectory(transport); SyncDirectory(commits);
        db->Exec("PRAGMA wal_checkpoint(TRUNCATE)");
        progress("done", "recovery complete");
        printf("[Prefix SSD] full recovery done: commits=%llu refs=%llu objects_removed=%llu elapsed=%.2fs.\\n",
               (unsigned long long)doneCommits, (unsigned long long)refsChecked,
               (unsigned long long)objectsRemoved, (NowNs() - recoveryStarted) / 1e9); fflush(stdout);
    }""",
             "sweep")

open(C, "w", encoding="utf-8").write(s)
print("disk_prefix_cache.cpp patched")

m = open(M, encoding="utf-8").read()
old = """        set_tests_properties(disk_prefix_cache PROPERTIES TIMEOUT 90)
    endif()"""
new = """        set_tests_properties(disk_prefix_cache PROPERTIES TIMEOUT 90)
        add_executable(lazy_recover_bench test/basic/lazy_recover_bench.cpp
            src/utils/disk_prefix_cache.cpp third_party/lmcache_fs/fs/connector.cpp
            third_party/json11/json11.cpp)
        target_link_libraries(lazy_recover_bench PRIVATE OpenSSL::Crypto SQLite::SQLite3 Threads::Threads)
    endif()"""
n = m.count(old)
if n != 1:
    sys.exit("cmake anchor count=%d -> abort (cpp patched, cmake NOT)" % n)
open(M, "w", encoding="utf-8").write(m.replace(old, new))
print("CMakeLists patched")
