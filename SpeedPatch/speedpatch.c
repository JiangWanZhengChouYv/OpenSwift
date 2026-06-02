#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>
#include <pthread.h>
#include <errno.h>

#include "fishhook.h"

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
static mach_timebase_info_data_t g_timebase_info;
static pthread_mutex_t g_speed_mutex = PTHREAD_MUTEX_INITIALIZER;

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
    pthread_mutex_lock(&g_speed_mutex);
    if (g_shared_memory == NULL) {
        pthread_mutex_unlock(&g_speed_mutex);
        return DEFAULT_SPEED_RATIO;
    }
    
    float ratio = g_shared_memory->speed_ratio;
    
    if (ratio < MIN_SPEED_RATIO) ratio = MIN_SPEED_RATIO;
    if (ratio > MAX_SPEED_RATIO) ratio = MAX_SPEED_RATIO;
    
    pthread_mutex_unlock(&g_speed_mutex);
    return ratio;
}

bool speedpatch_is_active(void) {
    pthread_mutex_lock(&g_speed_mutex);
    if (g_shared_memory == NULL) {
        pthread_mutex_unlock(&g_speed_mutex);
        return false;
    }
    bool active = g_shared_memory->is_active;
    pthread_mutex_unlock(&g_speed_mutex);
    return active;
}

static inline double apply_speed_multiplier(double original_value) {
    if (!speedpatch_is_active()) {
        return original_value;
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return original_value;
    }
    
    return original_value / ratio;
}

typedef uint64_t (*mach_absolute_time_t)(void);
typedef int (*clock_gettime_t)(clockid_t clk_id, struct timespec *tp);
typedef int (*gettimeofday_t)(struct timeval *tp, void *tzp);
typedef unsigned int (*sleep_t)(unsigned int seconds);
typedef int (*usleep_t)(useconds_t usec);
typedef clock_t (*clock_t_func_t)(void);
typedef double (*CFAbsoluteTimeGetCurrent_t)(void);
typedef uint64_t (*mach_physical_time_t)(void);

static mach_absolute_time_t original_mach_absolute_time = NULL;
static clock_gettime_t original_clock_gettime = NULL;
static gettimeofday_t original_gettimeofday = NULL;
static sleep_t original_sleep = NULL;
static usleep_t original_usleep = NULL;
static clock_t_func_t original_clock = NULL;
static CFAbsoluteTimeGetCurrent_t original_CFAbsoluteTimeGetCurrent = NULL;
static mach_physical_time_t original_mach_physical_time = NULL;

static uint64_t mach_absolute_time_to_units(uint64_t mach_time);
static uint64_t units_to_mach_absolute_time(uint64_t units);

static uint64_t hooked_mach_absolute_time(void) {
    uint64_t current_time = original_mach_absolute_time();
    
    if (!speedpatch_is_active()) {
        return current_time;
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return current_time;
    }
    
    uint64_t nanoseconds = mach_absolute_time_to_units(current_time);
    uint64_t modified_nanoseconds = (uint64_t)((double)nanoseconds / ratio);
    
    return units_to_mach_absolute_time(modified_nanoseconds);
}

static uint64_t mach_absolute_time_to_units(uint64_t mach_time) {
    mach_timebase_info_data_t timebase;
    kern_return_t kr = mach_timebase_info(&timebase);
    if (kr != KERN_SUCCESS) {
        return mach_time;
    }
    
    return (mach_time * timebase.numer) / timebase.denom;
}

static uint64_t units_to_mach_absolute_time(uint64_t units) {
    mach_timebase_info_data_t timebase;
    kern_return_t kr = mach_timebase_info(&timebase);
    if (kr != KERN_SUCCESS) {
        return units;
    }
    
    return (units * timebase.denom) / timebase.numer;
}

static int hooked_clock_gettime(clockid_t clk_id, struct timespec *tp) {
    int result = original_clock_gettime(clk_id, tp);
    
    if (result != 0 || !speedpatch_is_active() || tp == NULL) {
        return result;
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return result;
    }
    
    if (clk_id == CLOCK_MONOTONIC || clk_id == CLOCK_MONOTONIC_RAW || 
        clk_id == _CLOCK_MONOTONIC_RAW) {
        
        double seconds = (double)tp->tv_sec;
        double nanoseconds = (double)tp->tv_nsec;
        double total_nanoseconds = seconds * 1000000000.0 + nanoseconds;
        double modified_nanoseconds = total_nanoseconds / ratio;
        
        uint64_t total_ns = (uint64_t)modified_nanoseconds;
        tp->tv_sec = (time_t)(total_ns / 1000000000ULL);
        tp->tv_nsec = (long)(total_ns % 1000000000ULL);
    }
    
    return result;
}

static int hooked_gettimeofday(struct timeval *tp, void *tzp) {
    int result = original_gettimeofday(tp, tzp);
    
    if (result != 0 || !speedpatch_is_active() || tp == NULL) {
        return result;
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return result;
    }
    
    double seconds = (double)tp->tv_sec;
    double microseconds = (double)tp->tv_usec;
    double total_microseconds = seconds * 1000000.0 + microseconds;
    double modified_microseconds = total_microseconds / ratio;
    
    uint64_t total_us = (uint64_t)modified_microseconds;
    tp->tv_sec = (time_t)(total_us / 1000000ULL);
    tp->tv_usec = (suseconds_t)(total_us % 1000000ULL);
    
    return result;
}

static unsigned int hooked_sleep(unsigned int seconds) {
    if (!speedpatch_is_active() || seconds == 0) {
        return original_sleep(seconds);
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return original_sleep(seconds);
    }
    
    unsigned int modified_seconds = (unsigned int)((double)seconds / ratio);
    if (modified_seconds == 0) {
        modified_seconds = 1;
    }
    
    return original_sleep(modified_seconds);
}

static int hooked_usleep(useconds_t usec) {
    if (!speedpatch_is_active() || usec == 0) {
        return original_usleep(usec);
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return original_usleep(usec);
    }
    
    useconds_t modified_usec = (useconds_t)((double)usec / ratio);
    if (modified_usec == 0) {
        modified_usec = 1;
    }
    
    return original_usleep(modified_usec);
}

static clock_t hooked_clock(void) {
    clock_t result = original_clock();
    
    if (!speedpatch_is_active()) {
        return result;
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return result;
    }
    
    return (clock_t)((double)result / ratio);
}

static double hooked_CFAbsoluteTimeGetCurrent(void) {
    double current_time = original_CFAbsoluteTimeGetCurrent();
    
    if (!speedpatch_is_active()) {
        return current_time;
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return current_time;
    }
    
    return current_time / ratio;
}

static uint64_t hooked_mach_physical_time(void) {
    uint64_t current_time = original_mach_physical_time();
    
    if (!speedpatch_is_active()) {
        return current_time;
    }
    
    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return current_time;
    }
    
    return (uint64_t)((double)current_time / ratio);
}

static void speedpatch_hook_time_functions(void) {
    printf("[SpeedPatch] Starting to hook time functions...\n");
    
    mach_timebase_info(&g_timebase_info);
    printf("[SpeedPatch] Mach timebase: numer=%u, denom=%u\n", 
           g_timebase_info.numer, g_timebase_info.denom);
    
    struct rebinding rebindings[] = {
        {"mach_absolute_time", hooked_mach_absolute_time, (void**)&original_mach_absolute_time},
        {"clock_gettime", hooked_clock_gettime, (void**)&original_clock_gettime},
        {"gettimeofday", hooked_gettimeofday, (void**)&original_gettimeofday},
        {"sleep", hooked_sleep, (void**)&original_sleep},
        {"usleep", hooked_usleep, (void**)&original_usleep},
        {"clock", hooked_clock, (void**)&original_clock},
        {"CFAbsoluteTimeGetCurrent", hooked_CFAbsoluteTimeGetCurrent, (void**)&original_CFAbsoluteTimeGetCurrent},
    };
    
    int result = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    
    if (result == 0) {
        printf("[SpeedPatch] Successfully hooked %lu time functions\n", 
               sizeof(rebindings) / sizeof(rebindings[0]));
    } else {
        fprintf(stderr, "[SpeedPatch] Failed to hook time functions, error code: %d\n", result);
    }
    
    void* corefoundation = dlopen("/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", RTLD_LAZY);
    if (corefoundation) {
        original_CFAbsoluteTimeGetCurrent = (CFAbsoluteTimeGetCurrent_t)dlsym(corefoundation, "CFAbsoluteTimeGetCurrent");
        if (original_CFAbsoluteTimeGetCurrent) {
            printf("[SpeedPatch] Found CFAbsoluteTimeGetCurrent in CoreFoundation\n");
        } else {
            printf("[SpeedPatch] CFAbsoluteTimeGetCurrent not found in CoreFoundation\n");
        }
        dlclose(corefoundation);
    } else {
        printf("[SpeedPatch] Failed to load CoreFoundation: %s\n", dlerror());
    }
    
    void* quartzcore = dlopen("/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore", RTLD_LAZY);
    if (quartzcore) {
        original_CFAbsoluteTimeGetCurrent = (CFAbsoluteTimeGetCurrent_t)dlsym(quartzcore, "CFAbsoluteTimeGetCurrent");
        if (original_CFAbsoluteTimeGetCurrent) {
            printf("[SpeedPatch] Found CFAbsoluteTimeGetCurrent in QuartzCore\n");
        }
        dlclose(quartzcore);
    }
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
    
    speedpatch_hook_time_functions();
}

__attribute__((destructor))
void speedpatch_cleanup(void) {
    printf("[SpeedPatch] DYLIB unloading\n");
    speedpatch_cleanup_shared_memory();
}
