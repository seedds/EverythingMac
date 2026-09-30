#ifndef EVERYTHING_MAC_NATIVE_H
#define EVERYTHING_MAC_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
// One engine per process. Calls are serialized on Swift's engine queue, except
// request creation/cancellation and scan-count reads, which are thread-safe.
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
// Thread-safe while request is alive; does not access the engine.
size_t cn_scan_count(const CNRequest *request);
CNBuffer cn_watch(CNEngine *engine, bool enabled, const char *checkpoint);
// Includes `events` only when include_events is set and processed_events differs
// from since_processed. `changed` invalidates row IDs; `metadata_changed` (indexed
// sizes/dates) keeps them valid. `watcher_stopped` reports a lost FSEvents stream.
CNBuffer cn_poll(CNEngine *engine, uint64_t since_processed, bool include_events);
CNBuffer cn_scan(const char *root, const char *ignores, const char *includes, const char *patterns, const CNRequest *request, CNEngine **out);
CNBuffer cn_validate_exclusions(const char *patterns);
// Skips the write when the index is unchanged since it was opened from, or last
// saved to, the configured checkpoint.
CNBuffer cn_checkpoint(CNEngine *engine);
CNBuffer cn_sort(CNEngine *engine, const char *sort);
CNBuffer cn_paths(CNEngine *engine, uint64_t generation, const char *indices);
CNBuffer cn_locate(CNEngine *engine, uint64_t generation, const char *paths);
CNBuffer cn_select(CNEngine *engine, uint64_t generation, const char *ranges, const char *cached);
CNBuffer cn_selected(CNEngine *engine, uint64_t generation, bool paths);
// Explicit actions resolve retained selection identities across live row invalidation.
CNBuffer cn_selection_paths(CNEngine *engine);
CNBuffer cn_transfer_selection(CNEngine *from, CNEngine *to);
#endif
