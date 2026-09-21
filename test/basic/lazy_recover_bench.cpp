// lazy_recover_bench — DiskPrefixCache 启动恢复行为基准/验收（CPU 级，无需 GPU）
// 用法: lazy_recover_bench <store_dir> [--force] [--dirty]
//   --force : 设 FASTLLM_PREFIX_CACHE_FORCE_RECOVER=1（强制全量恢复）
//   --dirty : 先往 index.sqlite3 插入一条 intents 行（模拟中断写）→ ctor 应走全量恢复并清掉
// 输出: ctor_ms / checkpoints / intents 行数 / recover-progress.json 内容
#include "utils/disk_prefix_cache.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <sqlite3.h>

using Cache = fastllm::DiskPrefixCache;

static long long intent_rows(const std::string &db) {
    sqlite3 *h = nullptr;
    long long n = -1;
    if (sqlite3_open(db.c_str(), &h) == SQLITE_OK) {
        sqlite3_stmt *st = nullptr;
        if (sqlite3_prepare_v2(h, "SELECT COUNT(*) FROM intents", -1, &st, nullptr) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int64(st, 0);
        }
        if (st) sqlite3_finalize(st);
    }
    if (h) sqlite3_close(h);
    return n;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <store_dir> [--force] [--dirty]\n", argv[0]); return 2; }
    std::string dir = argv[1];
    bool force = false, dirty = false;
    for (int i = 2; i < argc; ++i) {
        if (!strcmp(argv[i], "--force")) force = true;
        if (!strcmp(argv[i], "--dirty")) dirty = true;
    }
    std::string db = dir + "/v2/index.sqlite3";
    if (dirty) {
        sqlite3 *h = nullptr;
        if (sqlite3_open(db.c_str(), &h) != SQLITE_OK) { fprintf(stderr, "dirty: open failed\n"); return 2; }
        char *err = nullptr;
        if (sqlite3_exec(h, "INSERT OR IGNORE INTO intents VALUES('bench-dirty');", nullptr, nullptr, &err) != SQLITE_OK) {
            fprintf(stderr, "dirty: insert failed: %s\n", err ? err : "?");
            sqlite3_free(err);
            sqlite3_close(h);
            return 2;
        }
        sqlite3_close(h);
        printf("dirty_marker_inserted intents=%lld\n", intent_rows(db));
    }
    if (force) setenv("FASTLLM_PREFIX_CACHE_FORCE_RECOVER", "1", 1);
    auto t0 = std::chrono::steady_clock::now();
    {
        Cache cache(dir, Cache::Digest("bench-identity"), (uint64_t)256 << 30, Cache::Digest("bench-family"));
        auto t1 = std::chrono::steady_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        auto cps = cache.ListCheckpoints("", "", 1 << 30);
        printf("ctor_ms=%.1f checkpoints=%zu\n", ms, cps.size());
    }
    printf("intents_after=%lld\n", intent_rows(db));
    std::ifstream f(dir + "/v2/recover-progress.json");
    std::stringstream ss;
    ss << f.rdbuf();
    printf("progress_file=%s\n", ss.str().empty() ? "(none)" : ss.str().c_str());
    return 0;
}
