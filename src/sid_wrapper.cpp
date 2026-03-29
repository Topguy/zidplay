/*
 * MySidPlayer - A high-fidelity Zig SID player
 * Copyright (C) 2026 Steinar Barbakken <topguyz@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */
#include "sid_wrapper.h"
#include "sidplayfp/sidplayfp.h"
#include "sidplayfp/SidTune.h"
#include "sidplayfp/SidTuneInfo.h"
#include "sidplayfp/SidInfo.h"
#include "builders/residfp-builder/residfp.h"
#include "sidplayfp/SidConfig.h"
#include <mutex>

struct sidplayfp_c {
    sidplayfp player;
    std::recursive_mutex mutex;
};

extern "C" {

sidplayfp_t* sid_new() {
    return (sidplayfp_t*) new sidplayfp_c();
}

void sid_delete(sidplayfp_t* s) {
    delete (sidplayfp_c*) s;
}

SIDLiteBuilder_t* builder_new(const char* name) {
    return (SIDLiteBuilder_t*) new ReSIDfpBuilder(name);
}

void builder_delete(SIDLiteBuilder_t* b) {
    delete (ReSIDfpBuilder*) b;
}

SidTune_t* tune_new(const char* filename) {
    return (SidTune_t*) new SidTune(filename);
}

void tune_delete(SidTune_t* t) {
    delete (SidTune*) t;
}

bool tune_status(SidTune_t* t) {
    return ((SidTune*) t)->getStatus();
}

unsigned int tune_select_song(SidTune_t* t, unsigned int songNum) {
    return ((SidTune*) t)->selectSong(songNum);
}

const char* tune_title(SidTune_t* t) {
    return ((SidTune*) t)->getInfo()->infoString(0);
}

const char* tune_author(SidTune_t* t) {
    return ((SidTune*) t)->getInfo()->infoString(1);
}

const char* tune_released(SidTune_t* t) {
    return ((SidTune*) t)->getInfo()->infoString(2);
}

uint32_t tune_get_clock_speed(SidTune_t* t) {
    int clock = ((SidTune*) t)->getInfo()->clockSpeed();
    if (clock == 2) { // CLOCK_NTSC
        return 1022727;
    }
    return 985248; // Default to PAL
}

uint32_t tune_songs(SidTune_t* t) {
    return ((SidTune*) t)->getInfo()->songs();
}

uint32_t tune_start_song(SidTune_t* t) {
    return ((SidTune*) t)->getInfo()->startSong();
}

uint32_t tune_info_count(SidTune_t* t) {
    return ((SidTune*) t)->getInfo()->numberOfInfoStrings();
}

const char* tune_info_string(SidTune_t* t, uint32_t index) {
    return ((SidTune*) t)->getInfo()->infoString(index);
}

bool sid_load(sidplayfp_t* s, SidTune_t* t) {
    sidplayfp_c* ctx = (sidplayfp_c*) s;
    ctx->mutex.lock();
    bool ok = ctx->player.load((SidTune*) t);
    ctx->mutex.unlock();
    return ok;
}

const char* sid_error(sidplayfp_t* s) {
    return ((sidplayfp_c*) s)->player.error();
}

void sid_set_roms(sidplayfp_t* s, const uint8_t* kernal, const uint8_t* basic, const uint8_t* chargen) {
    sidplayfp_c* ctx = (sidplayfp_c*) s;
    ctx->mutex.lock();
    ctx->player.setRoms(kernal, basic, chargen);
    ctx->mutex.unlock();
}

bool sid_config(sidplayfp_t* s, SIDLiteBuilder_t* b, uint32_t freq) {
    sidplayfp_c* ctx = (sidplayfp_c*) s;
    ctx->mutex.lock();
    SidConfig cfg = ctx->player.config();
    cfg.sidEmulation = (ReSIDfpBuilder*) b;
    cfg.frequency = freq;
    cfg.samplingMethod = SidConfig::RESAMPLE_INTERPOLATE;
    bool ok = ctx->player.config(cfg);
    ctx->mutex.unlock();
    return ok;
}

void sid_init_mixer(sidplayfp_t* s) {
    sidplayfp_c* ctx = (sidplayfp_c*) s;
    ctx->mutex.lock();
    ctx->player.initMixer(true);
    ctx->mutex.unlock();
}

void sid_lock(sidplayfp_t* s) {
    ((sidplayfp_c*) s)->mutex.lock();
}

void sid_unlock(sidplayfp_t* s) {
    ((sidplayfp_c*) s)->mutex.unlock();
}

int sid_play(sidplayfp_t* s, uint32_t cycles) {
    sidplayfp_c* ctx = (sidplayfp_c*) s;
    return ctx->player.play(cycles);
}

unsigned int sid_mix(sidplayfp_t* s, int16_t* buffer, uint32_t samples) {
    sidplayfp_c* ctx = (sidplayfp_c*) s;
    return ctx->player.mix(buffer, samples);
}

}
