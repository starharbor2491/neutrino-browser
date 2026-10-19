// SPDX-License-Identifier: MPL-2.0
#ifndef NEUTRINO_ENGINE_ABI_H
#define NEUTRINO_ENGINE_ABI_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void NeutrinoBootstrapApplication(void);
typedef void (*neutrino_cef_event_callback)(void *context, int event, const char *json);
typedef int (*neutrino_cef_popup_callback)(void *context, void *child, const char *url);

enum { NEUTRINO_CEF_STATE = 1, NEUTRINO_CEF_FINISHED, NEUTRINO_CEF_ERROR,
       NEUTRINO_CEF_CLOSED, NEUTRINO_CEF_RESULT, NEUTRINO_CEF_NOTICE,
       NEUTRINO_CEF_READER_CONTEXT, NEUTRINO_CEF_DOWNLOAD_BEGIN, NEUTRINO_CEF_DOWNLOAD_UPDATE,
       NEUTRINO_CEF_ACTIVATE, NEUTRINO_CEF_BROWSER_COMMAND,
       /* A sign-in reported by Neutrino's isolated password world. */
       NEUTRINO_CEF_CREDENTIAL };
enum { NEUTRINO_CEF_LOAD = 1, NEUTRINO_CEF_RELOAD, NEUTRINO_CEF_STOP,
       NEUTRINO_CEF_BACK, NEUTRINO_CEF_FORWARD, NEUTRINO_CEF_ZOOM,
       NEUTRINO_CEF_FIND, NEUTRINO_CEF_POPUPS, NEUTRINO_CEF_FOCUS,
       NEUTRINO_CEF_EXTENSIONS, NEUTRINO_CEF_FOCUS_LOCATION, NEUTRINO_CEF_DOWNLOAD_PATH, NEUTRINO_CEF_DOWNLOAD_CANCEL,
       NEUTRINO_CEF_HOME, NEUTRINO_CEF_RESTORE_TABS, NEUTRINO_CEF_SYNC_ACTIVE,
       NEUTRINO_CEF_NEW_TAB, NEUTRINO_CEF_CLOSE_TAB, NEUTRINO_CEF_CLOSE_WINDOW, /* Reserved. */
       NEUTRINO_CEF_STOP_ADMISSION,
       NEUTRINO_CEF_REOPEN_TAB, NEUTRINO_CEF_PREVIOUS_TAB, NEUTRINO_CEF_NEXT_TAB,
       NEUTRINO_CEF_SET_BLOCKING, NEUTRINO_CEF_REQUEST_CLOSE,
       NEUTRINO_CEF_SUSPEND_INPUT, NEUTRINO_CEF_SELECT_INNER_PAGE,
       NEUTRINO_CEF_CLOSE_INNER_PAGE,
       /* Value 1 mutes the active page, 0 unmutes it. */
       NEUTRINO_CEF_MUTE,
       /* Text names an allowed Chrome command such as IDC_PRINT. */
       NEUTRINO_CEF_CHROME_COMMAND,
       /* Text names an allowed profile preference; value is its number or 0/1. */
       NEUTRINO_CEF_PREFERENCE,
       /* Value is a download ID; text "1" pauses it and "0" resumes it. */
       NEUTRINO_CEF_DOWNLOAD_PAUSE };

/// Versioned ABI loaded only from an explicitly installed engine package.
typedef struct neutrino_cef_api {
    uint32_t version;
    int (*initialize)(const char *package_path, const char *data_path, const char *main_bundle_path);
    const char *(*last_error)(void);
    void *(*create_page)(const char *profile_id, const char *private_window_id);
    void *(*native_view)(void *page);
    void (*set_callbacks)(void *page, void *context, neutrino_cef_event_callback event, neutrino_cef_popup_callback popup);
    void (*command)(void *page, int command, const char *text, double value);
    void (*devtools)(void *page, int request_id, const char *method, const char *parameters);
    void (*close_page)(void *page);
    int (*live_pages)(void);
    int (*shutdown)(void);
    /// Release a private window's contexts, or all contexts of a deleted Profile
    /// when window ID is empty. At least one field must be nonempty.
    void (*release_private_contexts)(const char *private_window_id, const char *profile_id);
    /// Execute a supported normal Chrome tab command; zero means unavailable.
    int (*native_tab_command)(void *page, int command);
    /// Freeze user commands/adoption while the final quit snapshot is saved.
    void (*set_final_quit_frozen)(int frozen);
} neutrino_cef_api;
typedef const neutrino_cef_api *(*neutrino_cef_get_api_function)(void);

#ifdef __cplusplus
}
#endif
#endif
