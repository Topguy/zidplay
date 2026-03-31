/*
 * MySidPlayer - A high-fidelity Zig SID player
 * Copyright (C) 2026 Steinar Barbakken <topguyz@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include "audio_engine.h"
#include <stdlib.h>
#include <stdio.h>

struct audio_engine_s {
    ma_context context;
    ma_device device;
    audio_callback_t callback;
    void* pUserData;
    bool contextInitialized;
};

static void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    audio_engine_t* engine = (audio_engine_t*)pDevice->pUserData;
    if (engine && engine->callback) {
        engine->callback((int16_t*)pOutput, frameCount, engine->pUserData);
    }
    (void)pInput;
}

audio_engine_t* audio_init(audio_callback_t callback, void* pUserData, int deviceIndex) {
    audio_engine_t* engine = (audio_engine_t*)calloc(1, sizeof(audio_engine_t));
    if (!engine) return NULL;

    if (ma_context_init(NULL, 0, NULL, &engine->context) != MA_SUCCESS) {
        printf("Failed to initialize context.\n");
        free(engine);
        return NULL;
    }
    engine->contextInitialized = true;

    ma_device_info* pPlaybackDeviceInfos;
    ma_uint32 playbackDeviceCount;
    if (ma_context_get_devices(&engine->context, &pPlaybackDeviceInfos, &playbackDeviceCount, NULL, NULL) != MA_SUCCESS) {
        printf("Failed to get devices.\n");
        ma_context_uninit(&engine->context);
        free(engine);
        return NULL;
    }

    engine->callback = callback;
    engine->pUserData = pUserData;

    ma_device_config deviceConfig;
    deviceConfig = ma_device_config_init(ma_device_type_playback);
    
    if (deviceIndex >= 0 && (ma_uint32)deviceIndex < playbackDeviceCount) {
        deviceConfig.playback.pDeviceID = &pPlaybackDeviceInfos[deviceIndex].id;
    }

    deviceConfig.playback.format   = ma_format_s16;
    deviceConfig.playback.channels = 2;
    deviceConfig.sampleRate        = 44100;
    deviceConfig.dataCallback      = data_callback;
    deviceConfig.pUserData         = engine;

    if (ma_device_init(&engine->context, &deviceConfig, &engine->device) != MA_SUCCESS) {
        ma_context_uninit(&engine->context);
        free(engine);
        return NULL;
    }

    return engine;
}

void audio_list_devices(void) {
    ma_context context;
    if (ma_context_init(NULL, 0, NULL, &context) != MA_SUCCESS) {
        printf("Failed to initialize audio context for device listing.\n");
        return;
    }

    ma_device_info* pPlaybackDeviceInfos;
    ma_uint32 playbackDeviceCount;
    if (ma_context_get_devices(&context, &pPlaybackDeviceInfos, &playbackDeviceCount, NULL, NULL) == MA_SUCCESS) {
        printf("Available playback devices:\n");
        for (ma_uint32 i = 0; i < playbackDeviceCount; i++) {
            printf("  [%u] %s %s\n", i, pPlaybackDeviceInfos[i].name, pPlaybackDeviceInfos[i].isDefault ? "(Default)" : "");
        }
    } else {
        printf("Failed to get audio devices.\n");
    }

    ma_context_uninit(&context);
}

void audio_start(audio_engine_t* engine) {
    if (engine) ma_device_start(&engine->device);
}

void audio_stop(audio_engine_t* engine) {
    if (engine) ma_device_stop(&engine->device);
}

void audio_deinit(audio_engine_t* engine) {
    if (engine) {
        ma_device_uninit(&engine->device);
        if (engine->contextInitialized) {
            ma_context_uninit(&engine->context);
        }
        free(engine);
    }
}

