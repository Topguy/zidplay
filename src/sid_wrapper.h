/*
 * MySidPlayer - A high-fidelity Zig SID player
 * Copyright (C) 2026 Steinar Barbakken <topguyz@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */
#ifndef SID_WRAPPER_H
#define SID_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

typedef struct sidplayfp_c sidplayfp_t;
typedef struct SidTune_c SidTune_t;
typedef struct SIDLiteBuilder_c SIDLiteBuilder_t;

sidplayfp_t* sid_new();
void sid_delete(sidplayfp_t* s);

SIDLiteBuilder_t* builder_new(const char* name);
void builder_delete(SIDLiteBuilder_t* b);

SidTune_t* tune_new(const char* filename);
void tune_delete(SidTune_t* t);
bool tune_status(SidTune_t* t);
unsigned int tune_select_song(SidTune_t* t, unsigned int songNum);
const char* tune_md5(SidTune_t* t);
const char* tune_title(SidTune_t* t);
const char* tune_author(SidTune_t* t);
const char* tune_released(SidTune_t* t);
uint32_t tune_get_clock_speed(SidTune_t* t);
uint32_t tune_songs(SidTune_t* t);
uint32_t tune_start_song(SidTune_t* t);
uint32_t tune_info_count(SidTune_t* t);
const char* tune_info_string(SidTune_t* t, uint32_t index);

bool sid_load(sidplayfp_t* s, SidTune_t* t);
const char* sid_error(sidplayfp_t* s);
void sid_set_roms(sidplayfp_t* s, const uint8_t* kernal, const uint8_t* basic, const uint8_t* chargen);
bool sid_config(sidplayfp_t* s, SIDLiteBuilder_t* b, uint32_t freq);
void sid_init_mixer(sidplayfp_t* s);
void sid_lock(sidplayfp_t* s);
void sid_unlock(sidplayfp_t* s);
int sid_play(sidplayfp_t* s, uint32_t cycles);
unsigned int sid_mix(sidplayfp_t* s, int16_t* buffer, uint32_t samples);
void sid_mute(sidplayfp_t* s, unsigned int sidNum, unsigned int voice, bool enable);

#ifdef __cplusplus
}
#endif

#endif
