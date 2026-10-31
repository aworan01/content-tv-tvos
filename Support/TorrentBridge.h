#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *ctv_torrent_create(const char *root, int network);
void ctv_torrent_destroy(void *engine);
int ctv_torrent_magnet(void *engine, const char *uri);
int ctv_torrent_metadata(void *engine, const uint8_t *data, size_t length);
char *ctv_torrent_status(void *engine);
int ctv_torrent_select(void *engine, int file, int64_t limit);
int ctv_torrent_read(void *engine, int64_t offset, uint8_t *buffer, int length);
void ctv_torrent_free(char *value);
int ctv_torrent_loopback_test(const char *root);
#ifdef __cplusplus
}
#endif
