#ifndef WM_STEAM_TRANSPORT_H
#define WM_STEAM_TRANSPORT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint64_t wm_steam_start(const char *json);
char *wm_steam_poll(uint64_t task_id);
int wm_steam_guard(uint64_t task_id, const char *code);
void wm_steam_cancel(uint64_t task_id);
void wm_steam_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
