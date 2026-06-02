#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#define SHARED_MEMORY_KEY_PREFIX "com.openspeedy.speedpatch."
#define SHARED_MEMORY_SIZE 4096

typedef struct {
    uint32_t version;
    float speed_ratio;
    bool is_active;
    uint64_t timestamp;
    uint8_t reserved[56];
} __attribute__((packed)) SharedMemoryHeader;

static SharedMemoryHeader* g_shared_memory = NULL;
static int g_shm_fd = -1;
static pid_t g_own_pid = 0;

static const uint32_t CURRENT_VERSION = 1;
static const float MIN_SPEED_RATIO = 0.1f;
static const float MAX_SPEED_RATIO = 10.0f;
static const float DEFAULT_SPEED_RATIO = 1.0f;

static bool speedpatch_init_shared_memory(void) {
    g_own_pid = getpid();
    
    size_t key_length = strlen(SHARED_MEMORY_KEY_PREFIX) + 32;
    char* shm_key = (char*)malloc(key_length);
    if (!shm_key) {
        fprintf(stderr, "[SpeedPatch] Failed to allocate memory for key\n");
        return false;
    }
    
    snprintf(shm_key, key_length, "%s%u", SHARED_MEMORY_KEY_PREFIX, g_own_pid);
    
    shm_unlink(shm_key);
    
    g_shm_fd = shm_open(shm_key, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP);
    if (g_shm_fd == -1) {
        fprintf(stderr, "[SpeedPatch] Failed to create shared memory: %s\n", strerror(errno));
        free(shm_key);
        return false;
    }
    
    if (ftruncate(g_shm_fd, SHARED_MEMORY_SIZE) == -1) {
        fprintf(stderr, "[SpeedPatch] Failed to set shared memory size: %s\n", strerror(errno));
        close(g_shm_fd);
        g_shm_fd = -1;
        free(shm_key);
        return false;
    }
    
    g_shared_memory = (SharedMemoryHeader*)mmap(NULL, SHARED_MEMORY_SIZE,
                                                  PROT_READ | PROT_WRITE, MAP_SHARED,
                                                  g_shm_fd, 0);
    if (g_shared_memory == MAP_FAILED) {
        fprintf(stderr, "[SpeedPatch] Failed to map shared memory: %s\n", strerror(errno));
        close(g_shm_fd);
        g_shm_fd = -1;
        free(shm_key);
        return false;
    }
    
    memset(g_shared_memory, 0, sizeof(SharedMemoryHeader));
    g_shared_memory->version = CURRENT_VERSION;
    g_shared_memory->speed_ratio = DEFAULT_SPEED_RATIO;
    g_shared_memory->is_active = false;
    g_shared_memory->timestamp = (uint64_t)time(NULL);
    
    msync(g_shared_memory, SHARED_MEMORY_SIZE, MS_SYNC);
    
    free(shm_key);
    
    printf("[SpeedPatch] Shared memory initialized successfully (PID: %u)\n", g_own_pid);
    return true;
}

static void speedpatch_cleanup_shared_memory(void) {
    if (g_shared_memory != NULL) {
        munmap(g_shared_memory, SHARED_MEMORY_SIZE);
        g_shared_memory = NULL;
    }
    
    if (g_shm_fd != -1) {
        close(g_shm_fd);
        g_shm_fd = -1;
    }
    
    if (g_own_pid > 0) {
        size_t key_length = strlen(SHARED_MEMORY_KEY_PREFIX) + 32;
        char* shm_key = (char*)malloc(key_length);
        if (shm_key) {
            snprintf(shm_key, key_length, "%s%u", SHARED_MEMORY_KEY_PREFIX, g_own_pid);
            shm_unlink(shm_key);
            free(shm_key);
        }
    }
    
    printf("[SpeedPatch] Shared memory cleaned up\n");
}

float speedpatch_get_speed_ratio(void) {
    if (g_shared_memory == NULL) {
        return DEFAULT_SPEED_RATIO;
    }
    
    float ratio = g_shared_memory->speed_ratio;
    
    if (ratio < MIN_SPEED_RATIO) ratio = MIN_SPEED_RATIO;
    if (ratio > MAX_SPEED_RATIO) ratio = MAX_SPEED_RATIO;
    
    return ratio;
}

bool speedpatch_is_active(void) {
    if (g_shared_memory == NULL) {
        return false;
    }
    return g_shared_memory->is_active;
}

static inline uint64_t get_time_nanoseconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static inline uint64_t apply_speed_ratio(uint64_t original_time) {
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f) return original_time;
    
    return (uint64_t)((float)original_time / ratio);
}

__attribute__((constructor))
void speedpatch_init(void) {
    printf("[SpeedPatch] DYLIB loaded successfully\n");
    
    uint32_t count = _dyld_image_count();
    printf("[SpeedPatch] %u images loaded in current process\n", count);
    
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name) {
            printf("[SpeedPatch] Image %u: %s\n", i, name);
        }
    }
    
    if (speedpatch_init_shared_memory()) {
        printf("[SpeedPatch] Speed control initialized\n");
    } else {
        fprintf(stderr, "[SpeedPatch] Failed to initialize speed control\n");
    }
}

__attribute__((destructor))
void speedpatch_cleanup(void) {
    printf("[SpeedPatch] DYLIB unloading\n");
    speedpatch_cleanup_shared_memory();
}
