/*
 * MySidPlayer - A high-fidelity Zig SID player
 * Copyright (C) 2026 Steinar Barbakken <topguyz@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */
#ifndef AUDIO_ENGINE_H
#define AUDIO_ENGINE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct audio_engine_s audio_engine_t;

// Callback type for the audio engine to request samples
// buffer: where to write samples (interleaved stereo i16)
// frameCount: number of samples per channel to write
typedef void (*audio_callback_t)(int16_t* buffer, uint32_t frameCount, void* pUserData);

audio_engine_t* audio_init(audio_callback_t callback, void* pUserData, int deviceIndex);
void audio_start(audio_engine_t* engine);
void audio_stop(audio_engine_t* engine);
void audio_deinit(audio_engine_t* engine);

#ifdef __cplusplus
}
#endif

#endif

