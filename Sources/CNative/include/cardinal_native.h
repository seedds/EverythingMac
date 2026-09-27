#ifndef CARDINAL_NATIVE_H
#define CARDINAL_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
// One engine per process. Calls are serialized on Swift's engine queue, except
// request_new/cancel, which are thread-safe and invalidate older search tokens.
// Buffers are bounded UTF-8 JSON (rows: maximum 256), never whole result arrays.
// Copy/decode buffers before freeing. Close only after queued work has completed.
typedef struct Engine CNEngine;
typedef struct Request CNRequest;
typedef struct { uint8_t *data; size_t len; } CNBuffer;
CNBuffer cn_engine_open(const char *path, CNEngine **out);
void cn_engine_close(CNEngine *engine);
CNRequest *cn_request_new(void);
void cn_request_free(CNRequest *request);
void cn_cancel(void);
CNBuffer cn_search(CNEngine *engine, const CNRequest *request, uint64_t generation,
                   const char *query, const char *directory, bool case_sensitive);
// Indexed paths/cached metadata only; never performs filesystem metadata reads.
CNBuffer cn_rows(CNEngine *engine, uint64_t generation, size_t start, size_t count);
void cn_buffer_free(CNBuffer buffer);
CNRequest *cn_scan_request_new(void);
void cn_cancel_scan(void);
CNBuffer cn_watch(CNEngine *engine, bool enabled, const char *checkpoint);
CNBuffer cn_poll(CNEngine *engine);
CNBuffer cn_scan(const char *root, const char *ignores, const char *includes, const CNRequest *request, CNEngine **out);
CNBuffer cn_checkpoint(CNEngine *engine);
CNBuffer cn_sort(CNEngine *engine, const char *sort, size_t limit);
CNBuffer cn_paths(CNEngine *engine, uint64_t generation, const char *indices);
CNBuffer cn_locate(CNEngine *engine, uint64_t generation, const char *paths);
CNBuffer cn_select(CNEngine *engine, uint64_t generation, const char *ranges, const char *cached);
CNBuffer cn_selected(CNEngine *engine, uint64_t generation, bool paths);
CNBuffer cn_transfer_selection(CNEngine *from, CNEngine *to);
#endif
