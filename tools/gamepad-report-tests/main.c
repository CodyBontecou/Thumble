// Checks the Xbox 360-style → Xbox Series BLE report conversion in apps/receiver/Sources/Gamepad.c.
#include "../../apps/receiver/Sources/Gamepad.h"
#include <stdio.h>
#include <string.h>
static int failures = 0;
static void x360(uint8_t r[20], uint16_t buttons, uint8_t lt, uint8_t rt, int16_t lx, int16_t ly, int16_t rx, int16_t ry) {
    memset(r, 0, 20); r[1] = 20; r[2] = (uint8_t)buttons; r[3] = (uint8_t)(buttons >> 8); r[4] = lt; r[5] = rt;
    int16_t axes[4] = {lx, ly, rx, ry};
    for (int i = 0; i < 4; i++) { r[6 + i * 2] = (uint8_t)axes[i]; r[7 + i * 2] = (uint8_t)((uint16_t)axes[i] >> 8); }
}
static unsigned u16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static void expect(const char *name, unsigned got, unsigned want) {
    if (got != want) { printf("FAIL %s: got %u want %u\n", name, got, want); failures++; }
}
int main(void) {
    uint8_t in[20], out[17];
    x360(in, 0, 0, 0, 0, 0, 0, 0); tapping_gamepad_convert(in, out);
    expect("report id", out[0], 1); expect("neutral lx", u16(out + 1), 32768); expect("neutral ry", u16(out + 7), 32768);
    expect("neutral hat", out[13], 0); expect("neutral buttons", u16(out + 14), 0); expect("neutral share", out[16], 0);
    x360(in, 0, 255, 128, -32768, 32767, 32767, -32768); tapping_gamepad_convert(in, out);
    expect("lx min", u16(out + 1), 0); expect("ly max", u16(out + 3), 65535); expect("rx max", u16(out + 5), 65535); expect("ry min", u16(out + 7), 0);
    expect("lt full", u16(out + 9), 1023); expect("rt half", u16(out + 11), 514);
    // 360 bits → Series bits: A12→0 B13→1 X14→3 Y15→4 LB8→6 RB9→7 Back5→10 Start4→11 Guide10→12 LS6→13 RS7→14
    const int map[][2] = {{12, 0}, {13, 1}, {14, 3}, {15, 4}, {8, 6}, {9, 7}, {5, 10}, {4, 11}, {10, 12}, {6, 13}, {7, 14}};
    for (unsigned i = 0; i < sizeof map / sizeof map[0]; i++) {
        x360(in, (uint16_t)(1u << map[i][0]), 0, 0, 0, 0, 0, 0); tapping_gamepad_convert(in, out);
        char name[32]; snprintf(name, sizeof name, "button bit %d", map[i][0]); expect(name, u16(out + 14), 1u << map[i][1]);
        expect("no hat with buttons", out[13], 0);
    }
    // D-pad bits: 0 up, 1 down, 2 left, 3 right → hat 1..8 clockwise from up.
    const int hats[][2] = {{1, 1}, {1 | 8, 2}, {8, 3}, {2 | 8, 4}, {2, 5}, {2 | 4, 6}, {4, 7}, {1 | 4, 8}};
    for (unsigned i = 0; i < 8; i++) {
        x360(in, (uint16_t)hats[i][0], 0, 0, 0, 0, 0, 0); tapping_gamepad_convert(in, out);
        expect("hat", out[13], (unsigned)hats[i][1]); expect("dpad is not a button", u16(out + 14), 0);
    }
    if (failures) return 1;
    puts("gamepad report conversion: all checks passed");
    return 0;
}
