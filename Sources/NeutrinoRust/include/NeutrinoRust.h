// SPDX-License-Identifier: MPL-2.0
#ifndef NEUTRINO_RUST_H
#define NEUTRINO_RUST_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *neutrino_database_open(const char *path, char **error);
void neutrino_database_free(void *handle);
char *neutrino_database_load(void *handle, char **error);
char *neutrino_database_save(void *handle, const uint8_t *data, size_t length, uint64_t revision);
char *neutrino_database_checkpoint(void *handle);
void *neutrino_shell_new(void);
void neutrino_shell_free(void *handle);
char *neutrino_shell_dispatch(void *handle, const char *request);
char *neutrino_core_request(const char *input);
char *neutrino_shell_asset(const char *name);
void neutrino_string_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
