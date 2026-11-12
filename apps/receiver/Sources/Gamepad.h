#pragma once
#include <stdint.h>
void *tapping_gamepad_create(void);
int32_t tapping_gamepad_send(void *device, const uint8_t *report);
void tapping_gamepad_destroy(void *device);
void tapping_gamepad_convert(const uint8_t *x360, uint8_t *out);
