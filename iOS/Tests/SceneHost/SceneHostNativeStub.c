#if !defined(WM_SCENE_HOST_TESTING) || WM_SCENE_HOST_TESTING != 1
#error "SceneHostNativeStub.c is test-only; never compile it into the production app."
#endif

#include "SceneHostNativeStub.h"

#include <stdlib.h>
#include <string.h>

/* Registry membership is checked before dereferencing any caller-supplied handle. */
struct owe_scene_wallpaper {
    uint64_t serial;
    bool live;
    struct owe_scene_wallpaper* next;
};

typedef struct event_node {
    wm_scene_test_event event;
    struct event_node* next;
} event_node;

static owe_scene_wallpaper* handles;
static uint64_t next_serial = 1;
static size_t live_handles;
static size_t invalid_handle_calls;
static event_node* first_event;
static event_node* last_event;
static size_t event_count;
static bool return_null_handle;
static char failure_operation[128];
static char failure_message[2048];
static char backend_reason[2048];
static owe_surface_health simulated_health = {0, 0, 0, UINT64_MAX, OWE_SURFACE_STOP_RUNNING};
static wm_scene_test_observer observer;
static void* observer_context;
static _Thread_local char last_error[2048];

static void copy_buffer(char* out, size_t capacity, const char* text)
{
    const char* source = text ? text : "";
    if (capacity == 0) return;
    size_t length = strlen(source);
    if (length >= capacity) length = capacity - 1;
    memcpy(out, source, length);
    out[length] = '\0';
}

static char* copy_string(const char* text)
{
    const char* source = text ? text : "";
    size_t length = strlen(source) + 1;
    char* copy = (char*)malloc(length);
    /* A recorder allocation failure must never look like a passing test. */
    if (!copy) abort();
    memcpy(copy, source, length);
    return copy;
}

static owe_scene_wallpaper* registered_handle(const void* pointer)
{
    for (owe_scene_wallpaper* handle = handles; handle; handle = handle->next) {
        if ((const void*)handle == pointer) return handle;
    }
    return NULL;
}

static void fail_event(wm_scene_test_event* event, const char* message)
{
    event->result = 1;
    copy_buffer(last_error, sizeof(last_error), message);
}

static wm_scene_test_event* append_event(const char* operation)
{
    event_node* node = (event_node*)calloc(1, sizeof(*node));
    if (!node) abort();
    node->event.operation = operation; /* All operation names are static literals. */
    if (last_event) last_event->next = node;
    else first_event = node;
    last_event = node;
    ++event_count;
    last_error[0] = '\0';
    return &node->event;
}

static void inject_failure(wm_scene_test_event* event)
{
    if (failure_operation[0] && strcmp(event->operation, failure_operation) == 0) {
        fail_event(event, failure_message);
        failure_operation[0] = '\0';
        failure_message[0] = '\0';
    }
}

static wm_scene_test_event* start_call(const char* operation, const void* pointer, bool allow_null)
{
    wm_scene_test_event* event = append_event(operation);
    owe_scene_wallpaper* handle = registered_handle(pointer);
    event->handle_serial = handle ? handle->serial : 0;
    event->valid_handle = (handle && handle->live) || (allow_null && !pointer);
    if (!event->valid_handle) {
        ++invalid_handle_calls;
        fail_event(event, "invalid or deleted test scene handle");
    } else {
        inject_failure(event);
    }
    return event;
}

static int complete(wm_scene_test_event* event)
{
    if (observer) observer(event->operation, observer_context);
    return event->result;
}

bool wm_scene_test_reset(void)
{
    /* Do not hide a missing teardown, free live state, or clear its evidence. */
    if (live_handles != 0) return false;
    while (handles) {
        owe_scene_wallpaper* next = handles->next;
        free(handles);
        handles = next;
    }
    while (first_event) {
        event_node* next = first_event->next;
        free((void*)first_event->event.source);
        free((void*)first_event->event.assets);
        free((void*)first_event->event.cache_path);
        free((void*)first_event->event.property_name);
        free((void*)first_event->event.string_value);
        free(first_event);
        first_event = next;
    }
    last_event = NULL;
    event_count = 0;
    invalid_handle_calls = 0;
    return_null_handle = false;
    failure_operation[0] = '\0';
    failure_message[0] = '\0';
    backend_reason[0] = '\0';
    last_error[0] = '\0';
    simulated_health = (owe_surface_health){0, 0, 0, UINT64_MAX, OWE_SURFACE_STOP_RUNNING};
    observer = NULL;
    observer_context = NULL;
    /* Serials stay process-unique, even across successful resets. */
    return true;
}

size_t wm_scene_test_event_count(void) { return event_count; }
size_t wm_scene_test_invalid_handle_calls(void) { return invalid_handle_calls; }
size_t wm_scene_test_live_handle_count(void) { return live_handles; }

const wm_scene_test_event* wm_scene_test_event_at(size_t index)
{
    if (index >= event_count) return NULL;
    event_node* node = first_event;
    while (index--) node = node->next;
    return &node->event;
}

void wm_scene_test_fail_next(const char* operation, const char* error)
{
    copy_buffer(failure_operation, sizeof(failure_operation), operation);
    copy_buffer(failure_message, sizeof(failure_message),
                error && error[0] ? error : "injected native scene failure");
}

void wm_scene_test_return_null_handle(bool enabled) { return_null_handle = enabled; }

void wm_scene_test_set_health(uint64_t frames_completed, uint64_t frames_presented,
                              uint64_t failed_frames, uint64_t last_present_age_ms,
                              uint32_t stop_reason)
{
    simulated_health = (owe_surface_health){frames_completed, frames_presented, failed_frames,
                                           last_present_age_ms, stop_reason};
}

void wm_scene_test_set_backend_reason(const char* reason)
{
    copy_buffer(backend_reason, sizeof(backend_reason), reason);
}

void wm_scene_test_set_observer(wm_scene_test_observer callback, void* context)
{
    observer = callback;
    observer_context = context;
}

int owe_scene_wallpaper_new(owe_scene_wallpaper** out_scene)
{
    wm_scene_test_event* event = append_event("new");
    event->valid_handle = true;
    if (!out_scene) {
        fail_event(event, "the output scene pointer is NULL");
        return complete(event);
    }
    *out_scene = NULL;
    inject_failure(event);
    if (event->result == 0 && !return_null_handle) {
        owe_scene_wallpaper* handle = (owe_scene_wallpaper*)calloc(1, sizeof(*handle));
        if (!handle) {
            fail_event(event, "test scene handle allocation failed");
        } else {
            handle->serial = next_serial++;
            handle->live = true;
            handle->next = handles;
            handles = handle;
            ++live_handles;
            *out_scene = handle;
            event->handle_serial = handle->serial;
        }
    }
    return complete(event);
}

int owe_scene_wallpaper_delete(owe_scene_wallpaper* scene)
{
    wm_scene_test_event* event = start_call("delete", scene, true);
    if (event->result == 0 && scene) {
        owe_scene_wallpaper* handle = registered_handle(scene);
        handle->live = false;
        --live_handles;
    }
    return complete(event);
}

int owe_scene_wallpaper_init(owe_scene_wallpaper* scene)
{
    return complete(start_call("init", scene, false));
}

int owe_scene_wallpaper_shutdown(owe_scene_wallpaper* scene)
{
    return complete(start_call("shutdown", scene, true));
}

static int record_surface(const char* operation, owe_scene_wallpaper* scene, void* metal_layer,
                          uint32_t width, uint32_t height, uint32_t render_width,
                          uint32_t render_height, double display_scale_factor)
{
    wm_scene_test_event* event = start_call(operation, scene, false);
    event->metal_layer = metal_layer;
    event->width = width;
    event->height = height;
    event->render_width = render_width;
    event->render_height = render_height;
    event->display_scale_factor = display_scale_factor;
    return complete(event);
}

int owe_scene_wallpaper_init_metal(owe_scene_wallpaper* scene, void* metal_layer,
                                    uint32_t width, uint32_t height, uint32_t render_width,
                                    uint32_t render_height, double display_scale_factor)
{
    return record_surface("init_metal", scene, metal_layer, width, height,
                          render_width, render_height, display_scale_factor);
}

int owe_scene_wallpaper_begin_surface_reconfigure(owe_scene_wallpaper* scene)
{
    return complete(start_call("begin", scene, false));
}

int owe_scene_wallpaper_finish_surface_reconfigure(owe_scene_wallpaper* scene, void* metal_layer,
                                                   uint32_t width, uint32_t height,
                                                   uint32_t render_width, uint32_t render_height,
                                                   double display_scale_factor)
{
    return record_surface("finish", scene, metal_layer, width, height,
                          render_width, render_height, display_scale_factor);
}

int owe_scene_wallpaper_apply_config(owe_scene_wallpaper* scene, const char* source,
                                      const char* assets, const char* cache_path, uint32_t fps,
                                      bool paused, float volume, bool muted,
                                      bool force_shader_refresh,
                                      const char* project_property_override_json)
{
    wm_scene_test_event* event = start_call("apply_config", scene, false);
    event->source = copy_string(source);
    event->assets = copy_string(assets);
    event->cache_path = copy_string(cache_path);
    event->string_value = copy_string(project_property_override_json);
    event->fps = fps;
    event->paused = paused;
    event->volume = volume;
    event->muted = muted;
    event->force_shader_refresh = force_shader_refresh;
    return complete(event);
}

int owe_scene_wallpaper_set_render_scale(owe_scene_wallpaper* scene, double scale)
{
    wm_scene_test_event* event = start_call("render_scale", scene, false);
    event->render_scale = scale;
    return complete(event);
}

int owe_scene_wallpaper_set_target_fps(owe_scene_wallpaper* scene, uint32_t fps)
{
    wm_scene_test_event* event = start_call("fps", scene, false);
    event->fps = fps;
    return complete(event);
}

int owe_scene_wallpaper_set_audio_volume(owe_scene_wallpaper* scene, float volume)
{
    wm_scene_test_event* event = start_call("volume", scene, false);
    event->volume = volume;
    return complete(event);
}

int owe_scene_wallpaper_set_audio_muted(owe_scene_wallpaper* scene, bool muted)
{
    wm_scene_test_event* event = start_call("muted", scene, false);
    event->muted = muted;
    return complete(event);
}

int owe_scene_wallpaper_set_property_int32(owe_scene_wallpaper* scene, const char* name,
                                           int32_t value)
{
    wm_scene_test_event* event = start_call("set_property_int32", scene, false);
    event->property_name = copy_string(name);
    event->int32_value = value;
    return complete(event);
}

int owe_scene_wallpaper_set_property_bool(owe_scene_wallpaper* scene, const char* name, bool value)
{
    wm_scene_test_event* event = start_call("set_property_bool", scene, false);
    event->property_name = copy_string(name);
    event->bool_value = value;
    return complete(event);
}

int owe_scene_wallpaper_set_property_string(owe_scene_wallpaper* scene, const char* name,
                                            const char* value)
{
    wm_scene_test_event* event = start_call("set_property_string", scene, false);
    event->property_name = copy_string(name);
    event->string_value = copy_string(value);
    return complete(event);
}

int owe_scene_wallpaper_set_paused(owe_scene_wallpaper* scene, bool paused)
{
    wm_scene_test_event* event = start_call("pause", scene, false);
    event->paused = paused;
    return complete(event);
}

size_t owe_scene_wallpaper_backend_failure_reason(void* scene, char* out, size_t out_len)
{
    wm_scene_test_event* event = start_call("backend_reason", scene, false);
    const char* reason = event->result == 0 ? backend_reason : last_error;
    event->string_value = copy_string(reason);
    if (out && out_len) copy_buffer(out, out_len, reason);
    size_t length = strlen(reason);
    (void)complete(event);
    return length;
}

int owe_scene_wallpaper_surface_health(void* scene, owe_surface_health* out)
{
    wm_scene_test_event* event = start_call("health", scene, false);
    if (!out && event->result == 0) fail_event(event, "the surface health output is NULL");
    if (event->result == 0) *out = simulated_health;
    return complete(event);
}

int owe_scene_wallpaper_mouse_enter(owe_scene_wallpaper* scene, bool entered)
{
    wm_scene_test_event* event = start_call("mouse_enter", scene, false);
    event->bool_value = entered;
    return complete(event);
}

int owe_scene_wallpaper_mouse_input(owe_scene_wallpaper* scene, double x, double y)
{
    wm_scene_test_event* event = start_call("mouse_input", scene, false);
    event->x = x;
    event->y = y;
    return complete(event);
}

int owe_scene_wallpaper_mouse_button(owe_scene_wallpaper* scene, int button, bool pressed)
{
    wm_scene_test_event* event = start_call("mouse_button", scene, false);
    event->button = button;
    event->bool_value = pressed;
    return complete(event);
}

/* Match the production property's stable spelling; getters do not touch errors. */
const char* owe_property_scaling_mode(void) { return "scalingmode"; }
const char* owe_property_audio_response_enabled(void) { return "audio_response_enabled"; }
const char* owe_property_project_property_preview_json(void) { return "project_property_preview_json"; }
const char* owe_last_error(void) { return last_error; }
