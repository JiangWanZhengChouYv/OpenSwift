#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <os/lock.h>
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

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."
#define SHARED_MEMORY_SIZE 4096

// 共享内存 header - 自然对齐，字段顺序保证跨平台一致性
// Swift 端按相同的字节偏移读写，所以这里的字段顺序必须与 Swift 端完全一致
// 注意：不使用 __attribute__((packed))，避免非对齐访问导致崩溃
typedef struct {
    os_unfair_lock lock;        // 4 bytes, offset 0   - 跨进程锁
    uint32_t version;            // 4 bytes, offset 4   - 协议版本
    uint32_t owner_pid;          // 4 bytes, offset 8   - 创建者 PID (用于验证)
    float speed_ratio;           // 4 bytes, offset 12  - 速度倍率
    uint8_t is_active;           // 1 byte,  offset 16  - 是否启用
    uint8_t padding[7];          // 7 bytes, offset 17-23 (填充到 8 字节边界)
    uint64_t timestamp;          // 8 bytes, offset 24  - 时间戳
    uint8_t reserved[40];        // 40 bytes, offset 32-71
} SharedMemoryHeader;             // 总大小: 72 bytes

// 编译时断言：验证结构体大小和字段偏移
_Static_assert(sizeof(SharedMemoryHeader) == 72, "SharedMemoryHeader size mismatch");
_Static_assert(offsetof(SharedMemoryHeader, lock) == 0, "lock offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, version) == 4, "version offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, owner_pid) == 8, "owner_pid offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, speed_ratio) == 12, "speed_ratio offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, is_active) == 16, "is_active offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, timestamp) == 24, "timestamp offset mismatch");

static SharedMemoryHeader* g_shared_memory = NULL;
static int g_shm_fd = -1;
static pid_t g_own_pid = 0;
static mach_timebase_info_data_t g_timebase_info;

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
    
    // 权限: 0600 - 仅所有者可读可写 (修复: 之前是 0660)
    mode_t shm_mode = S_IRUSR | S_IWUSR;
    
    // 先尝试打开已存在的共享内存
    g_shm_fd = shm_open(shm_key, O_RDWR, shm_mode);
    
    // 如果打开失败，创建新的
    if (g_shm_fd == -1) {
        printf("[SpeedPatch] Shared memory not found, creating new one (mode=0600)\n");
        g_shm_fd = shm_open(shm_key, O_CREAT | O_RDWR, shm_mode);
        if (g_shm_fd == -1) {
            fprintf(stderr, "[SpeedPatch] Failed to create shared memory: %s\n", strerror(errno));
            free(shm_key);
            return false;
        }
        
        // 设置共享内存大小
        if (ftruncate(g_shm_fd, SHARED_MEMORY_SIZE) == -1) {
            fprintf(stderr, "[SpeedPatch] Failed to set shared memory size: %s\n", strerror(errno));
            close(g_shm_fd);
            g_shm_fd = -1;
            free(shm_key);
            return false;
        }
    }
    
    // 映射共享内存
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
    
    // 检查是否需要初始化: PID 复用时，旧共享内存可能还存在
    bool need_init = false;
    if (g_shared_memory->version == 0) {
        need_init = true;
    } else if (g_shared_memory->owner_pid != (uint32_t)g_own_pid) {
        // 检测到 PID 复用: 旧共享内存属于另一个已死进程
        printf("[SpeedPatch] Detected stale shared memory (old_owner_pid=%u), reinitializing\n",
               g_shared_memory->owner_pid);
        need_init = true;
    }
    
    if (need_init) {
        memset(g_shared_memory, 0, sizeof(SharedMemoryHeader));
        g_shared_memory->lock = OS_UNFAIR_LOCK_INIT;
        g_shared_memory->version = CURRENT_VERSION;
        g_shared_memory->owner_pid = (uint32_t)g_own_pid;
        g_shared_memory->speed_ratio = DEFAULT_SPEED_RATIO;
        g_shared_memory->is_active = 0;
        g_shared_memory->timestamp = (uint64_t)time(NULL);
        msync(g_shared_memory, SHARED_MEMORY_SIZE, MS_SYNC);
        printf("[SpeedPatch] Shared memory initialized (owner_pid=%u)\n", g_own_pid);
    } else {
        printf("[SpeedPatch] Connected to existing shared memory (owner_pid=%u)\n",
               g_shared_memory->owner_pid);
    }
    
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
    
    // 使用 os_unfair_lock 跨进程同步读取
    os_unfair_lock_lock(&g_shared_memory->lock);
    
    // owner_pid 验证: 如果当前进程不是所有者，读到的数据可能无效
    if (g_shared_memory->owner_pid != (uint32_t)g_own_pid && g_shared_memory->owner_pid != 0) {
        // PID 已被复用但共享内存未更新，返回默认值
        os_unfair_lock_unlock(&g_shared_memory->lock);
        return DEFAULT_SPEED_RATIO;
    }
    
    float ratio = g_shared_memory->speed_ratio;
    os_unfair_lock_unlock(&g_shared_memory->lock);
    
    if (ratio < MIN_SPEED_RATIO) ratio = MIN_SPEED_RATIO;
    if (ratio > MAX_SPEED_RATIO) ratio = MAX_SPEED_RATIO;
    
    return ratio;
}

bool speedpatch_is_active(void) {
    if (g_shared_memory == NULL) {
        return false;
    }
    
    // 使用 os_unfair_lock 跨进程同步读取
    os_unfair_lock_lock(&g_shared_memory->lock);
    bool active = (g_shared_memory->is_active != 0);
    os_unfair_lock_unlock(&g_shared_memory->lock);
    
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
    // 只修改单调时钟，不修改真实挂钟时间
    if (clk_id != CLOCK_MONOTONIC && clk_id != CLOCK_MONOTONIC_RAW &&
        clk_id != CLOCK_MONOTONIC_RAW) {
        return original_clock_gettime(clk_id, tp);
    }

    int result = original_clock_gettime(clk_id, tp);
    if (result != 0 || !speedpatch_is_active() || tp == NULL) {
        return result;
    }

    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return result;
    }

    // 从进程启动开始的单调时间，按比例缩放
    double seconds = (double)tp->tv_sec;
    double nanoseconds = (double)tp->tv_nsec;
    double total_nanoseconds = seconds * 1000000000.0 + nanoseconds;
    double modified_nanoseconds = total_nanoseconds / ratio;

    uint64_t total_ns = (uint64_t)modified_nanoseconds;
    tp->tv_sec = (time_t)(total_ns / 1000000000ULL);
    tp->tv_nsec = (long)(total_ns % 1000000000ULL);

    return result;
}

static int hooked_gettimeofday(struct timeval *tp, void *tzp) {
    // gettimeofday 返回真实的挂钟时间，不应该被修改
    // 速度控制通过修改 sleep/usleep 的实际等待时间来实现
    int result = original_gettimeofday(tp, tzp);
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

    // 使用 usleep 来实现亚秒级精度的 sleep
    // sleep(1) 配合 ratio=2.0 应该变成 500ms
    unsigned long long total_usec = (unsigned long long)seconds * 1000000ULL;
    unsigned long long modified_usec = (unsigned long long)((double)total_usec / (double)ratio);

    if (modified_usec == 0) modified_usec = 1;

    // 通过函数指针直接调用 original_usleep，避免被 fishhook 再次拦截
    if (original_usleep != NULL) {
        original_usleep((useconds_t)modified_usec);
        return 0;
    }

    // fallback: 精度降级
    unsigned int modified_secs = (unsigned int)((double)seconds / ratio);
    if (modified_secs == 0) modified_secs = 1;
    original_sleep(modified_secs);
    return 0;
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
    if (modified_usec == 0) modified_usec = 1;

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
