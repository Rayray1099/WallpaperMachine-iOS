#ifndef WM_SCENE_HOST_NATIVE_STUB_H
#define WM_SCENE_HOST_NATIVE_STUB_H

/* Import the production ABI, including its opaque handle and surface-health layout. */
#include "SceneWallpaperBindings.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * TEST ONLY. Compile SceneHostNativeStub.c with WM_SCENE_HOST_TESTING=1 in the
 * isolated SceneHost test target, never in an application/native-engine target.
 * This recorder does not inspect a Metal layer, render, play audio, or perform I/O.
 * All controls and production ABI calls must run serially on the test's main
 * thread / MainActor. No locks or background work are created.
 *
 * Set up with a successful reset, configure failures/health, exercise the real
 * Swift host, then explicitly tear down every host before resetting again.
 * Events and their copied strings remain valid until the next successful reset.
 * Handle allocations are retained after delete so stale calls can be diagnosed
 * safely. Reset refuses to free anything while any handle is still live. After
 * a successful reset, old handles and event pointers must never be used again.
 */
typedef struct wm_scene_test_event {
    const char* operation;
    uint64_t handle_serial;
    bool valid_handle;
    int result;
    void* metal_layer; /* Borrowed identity only; never retained or dereferenced. */
    uint32_t width;
    uint32_t height;
    uint32_t render_width;
    uint32_t render_height;
    double display_scale_factor;
    double render_scale;
    uint32_t fps;
    float volume;
    bool muted;
    bool paused;
    bool force_shader_refresh;
    const char* source;
    const char* assets;
    const char* cache_path;
    const char* property_name;
    const char* string_value;
    int32_t int32_value;
    bool bool_value;
    double x;
    double y;
    int button;
} wm_scene_test_event;

/* Returns false without clearing state when teardown left a live handle. */
bool wm_scene_test_reset(void);
size_t wm_scene_test_event_count(void);
const wm_scene_test_event* wm_scene_test_event_at(size_t index);
size_t wm_scene_test_invalid_handle_calls(void);
size_t wm_scene_test_live_handle_count(void);

/*
 * Fail the next call matching this exact operation name; unrelated calls do not
 * consume the failure. Both strings are copied. A null/empty operation clears it.
 * Failable int-returning calls return 1; a health failure leaves its out unchanged.
 * A backend_reason failure returns a nonempty injected explanation (its ABI
 * returns a length, not a status). Getters and owe_last_error are not recorded.
 *
 * Operation names: new, init, init_metal, begin, finish, apply_config,
 * render_scale, fps, volume, muted, set_property_int32, set_property_bool,
 * set_property_string, pause, backend_reason, health, shutdown, delete,
 * mouse_enter, mouse_input, mouse_button.
 */
void wm_scene_test_fail_next(const char* operation, const char* error);
/* Makes successful new return a null handle without allocating one. */
void wm_scene_test_return_null_handle(bool enabled);

/* Health/reason controls apply to every live handle; no frames advance by time. */
void wm_scene_test_set_health(uint64_t frames_completed, uint64_t frames_presented,
                              uint64_t failed_frames, uint64_t last_present_age_ms,
                              uint32_t stop_reason);
void wm_scene_test_set_backend_reason(const char* reason);

/*
 * Invoked synchronously after appending the fully populated event and updating
 * stub state, before returning to Swift (including failed operations). Inspect
 * the existing host layer here to compare begin's old geometry with finish's new
 * geometry. The observer must not call the native ABI or mutate recorder state.
 * Read-only wm_scene_test_event_* access is permitted. Clear the observer in a
 * test defer before destroying its context; the context is borrowed, not owned.
 */
typedef void (*wm_scene_test_observer)(const char* operation, void* context);
void wm_scene_test_set_observer(wm_scene_test_observer observer, void* context);

#ifdef __cplusplus
}
#endif

#endif
