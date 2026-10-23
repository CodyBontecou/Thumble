#include "../../apps/receiver/Sources/Gamepad.h"
#include <stdio.h>
#include <stdlib.h>
void *tapping_gamepad_create(void) { return (void *)1; }
int32_t tapping_gamepad_send(void *device, const uint8_t *report) {
    const char *path = getenv("TAPPING_TEST_REPORTS");
    if (!path) return 0;
    FILE *file = fopen(path, "a");
    if (!file) return -1;
    for (int i = 0; i < 20; i++) fprintf(file, "%02x", report[i]);
    fprintf(file, "\n"); fclose(file); return 0;
}
void tapping_gamepad_destroy(void *device) { }
