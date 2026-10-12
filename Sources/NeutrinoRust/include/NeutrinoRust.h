// SPDX-License-Identifier: MPL-2.0
#ifndef NEUTRINO_RUST_H
#define NEUTRINO_RUST_H
#ifdef __cplusplus
extern "C" {
#endif
void *neutrino_shell_new(void);
void neutrino_shell_free(void *handle);
char *neutrino_shell_dispatch(void *handle, const char *request);
char *neutrino_shell_asset(const char *name);
void neutrino_string_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
