// SPDX-License-Identifier: BSD-3-Clause-Clear
// Userspace test of AsusWmi's fan-curve checks (the CURVE-CHECKS block of kexts/AsusWmi/AsusWmi.cpp).
// Run: bash scripts/test-asuswmi.sh
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static void expect(const char *name, bool got, bool want)
{
    printf("%-44s %s\n", name, got == want ? "ok" : "FAIL");
    if (got != want) failures++;
}

// fanWrite's decision for a user-client curve, given what the firmware's three read-backs return.
static bool accepted(const uint8_t c[16], const uint8_t fw[][16], int nfw)
{
    bool firmware = false;
    if (fanFirmwarePlausible(c))
        for (int i = 0; i < nfw; i++) if (memcmp(fw[i], c, 16) == 0) firmware = true;
    return firmware || fanCurveSane(c);
}

int main()
{
    // Real GA403WM firmware samples (2026-11-16).
    const uint8_t perf[16]      = { 47, 62, 65, 68, 70, 72, 74, 76,   1, 8, 13, 18, 22, 32, 39, 53 };
    const uint8_t silentCpu[16] = { 43, 68, 70, 72, 74, 76, 78, 255,  1, 6, 8, 13, 18, 22, 32, 32 };
    const uint8_t silentGpu[16] = { 43, 67, 68, 70, 70, 70, 70, 255,  1, 6, 8, 13, 18, 22, 32, 32 };
    const uint8_t fwCpu[3][16]  = { {0}, {0}, {0} };
    uint8_t fwSet[3][16];
    memcpy(fwSet[0], perf, 16); memcpy(fwSet[1], silentCpu, 16); memcpy(fwSet[2], silentGpu, 16);

    expect("performance: generic check", fanCurveSane(perf), true);
    expect("silent CPU: generic check refuses", fanCurveSane(silentCpu), false);
    expect("silent GPU: generic check refuses", fanCurveSane(silentGpu), false);
    expect("silent CPU: accepted as firmware curve", accepted(silentCpu, fwSet, 3), true);
    expect("silent GPU: accepted as firmware curve", accepted(silentGpu, fwSet, 3), true);
    expect("silent CPU: plausible read-back", fanFirmwarePlausible(silentCpu), true);
    expect("silent CPU without firmware match: refused", accepted(silentCpu, fwCpu, 3), false);

    uint8_t all255[16]; memset(all255, 255, 16);
    expect("all 255: refused", accepted(all255, fwSet, 3), false);

    uint8_t mid255[16]; memcpy(mid255, perf, 16); mid255[3] = 255;
    expect("mid-curve 255: refused", fanCurveSane(mid255), false);

    // Junk read-back: an all-zero DSTS buffer must not let an all-zero curve through.
    const uint8_t zero[16] = { 0 };
    const uint8_t junk[3][16] = { {0}, {0}, {0} };
    expect("all-zero read-back: not plausible", fanFirmwarePlausible(zero), false);
    expect("all-zero curve vs all-zero read-back", accepted(zero, junk, 3), false);
    uint8_t lowTemps[3][16]; memcpy(lowTemps[0], perf, 16); lowTemps[0][0] = 5; memcpy(lowTemps[1], lowTemps[0], 16); memcpy(lowTemps[2], lowTemps[0], 16);
    expect("read-back with a used temp < 20: not plausible", fanFirmwarePlausible(lowTemps[0]), false);
    uint8_t zeroTop[16]; memcpy(zeroTop, silentCpu, 16); for (int i = 8; i < 16; i++) zeroTop[i] = 0;
    expect("read-back with 0 % top: not plausible", fanFirmwarePlausible(zeroTop), false);

    // 0 % up to 105 C, then 40 %: the EC may step, so the fan would stay off until 105 C.
    const uint8_t late[16] = { 20, 20, 20, 20, 20, 20, 20, 105,  0, 0, 0, 0, 0, 0, 0, 40 };
    expect("0 % until 105 C: refused", fanCurveSane(late), false);
    const uint8_t hot[16] = { 30, 40, 50, 60, 70, 80, 85, 95,  0, 5, 10, 20, 30, 35, 39, 60 };
    expect("85 C point under 40 %: refused", fanCurveSane(hot), false);
    const uint8_t hotOk[16] = { 30, 40, 50, 60, 70, 80, 85, 95,  0, 5, 10, 20, 30, 35, 40, 60 };
    expect("85 C point at 40 %: accepted", fanCurveSane(hotOk), true);
    const uint8_t falling[16] = { 30, 40, 50, 45, 70, 80, 85, 95,  0, 5, 10, 20, 30, 35, 40, 60 };
    expect("falling temperature: refused", fanCurveSane(falling), false);
    const uint8_t dutyDrop[16] = { 30, 40, 50, 60, 70, 80, 85, 95,  0, 5, 10, 8, 30, 35, 40, 60 };
    expect("falling duty: refused", fanCurveSane(dutyDrop), false);

    printf(failures ? "%d failure(s)\n" : "AsusWmi curve tests passed\n", failures);
    return failures ? 1 : 0;
}
