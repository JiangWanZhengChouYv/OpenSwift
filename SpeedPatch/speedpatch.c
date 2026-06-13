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

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."
#define SHARED_MEMORY_SIZE 4096

// 魔术数字，用于验证共享内存已正确初始化
#define SPDM_MAGIC 0x5350444D
#define SPDM_VERSION 1

// 共享内存 header - 自然对齐，字段顺序保证跨平台一致性
// Swift 端按相同的字节偏移读写，所以这里的字段顺序必须与 Swift 端完全一致
//
// 重要: 移除了 os_unfair_lock（不支持跨进程），改为无锁原子读写
// speed_ratio (4 bytes, float) 和 is_active (1 byte, uint8_t)
// 在现代 CPU 上的单字节/4 字节自然对齐读写是原子操作
typedef struct {
    uint32_t magic;               // 4 bytes, offset 0   - 魔术数字 0x5350444D
    uint32_t version;             // 4 bytes, offset 4   - 协议版本
    uint32_t owner_pid;           // 4 bytes, offset 8   - 创建者 PID (用于验证)
    float    speed_ratio;         // 4 bytes, offset 12  - 速度倍率
    uint8_t  is_active;           // 1 byte,  offset 16  - 是否启用
    uint8_t  padding[7];          // 7 bytes, offset 17-23 (填充到 8 字节边界)
    uint64_t timestamp;           // 8 bytes, offset 24  - 最后修改时间戳
    uint8_t  reserved[40];        // 40 bytes, offset 32-71
} SharedMemoryHeader;             // 总大小: 72 bytes

// 编译时断言：验证结构体大小和字段偏移
_Static_assert(sizeof(SharedMemoryHeader) == 72, "SharedMemoryHeader size mismatch");
_Static_assert(offsetof(SharedMemoryHeader, magic) == 0, "magic offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, version) == 4, "version offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, owner_pid) == 8, "owner_pid offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, speed_ratio) == 12, "speed_ratio offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, is_active) == 16, "is_active offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, timestamp) == 24, "timestamp offset mismatch");

static SharedMemoryHeader* g_shared_memory = NULL;
static int g_shm_fd = -1;
static pid_t g_own_pid = 0;
static mach_timebase_info_data_t g_timebase_info;

static const uint32_t CURRENT_VERSION = SPDM_VERSION;
static const uint32_t MAGIC_NUMBER = SPDM_MAGIC;
static const float MIN_SPEED_RATIO = 0.1f;
static const float MAX_SPEED_RATIO = 10.0f;
static const float DEFAULT_SPEED_RATIO = 1.0f;

//
// 共享内存初始化
//
static bool speedpatch_init_shared_memory(void) {
    g_own_pid = getpid();

    size_t key_length = strlen(SHARED_MEMORY_KEY_PREFIX) + 32;
    char* shm_key = (char*)malloc(key_length);
    if (!shm_key) {
        fprintf(stderr, "[SpeedPatch] Failed to allocate memory for key\n");
        return false;
    }

    snprintf(shm_key, key_length, "%s%u", SHARED_MEMORY_KEY_PREFIX, g_own_pid);

    // 权限: 0600 - 仅所有者可读可写 (与 Swift 端保持一致)
    mode_t shm_mode = S_IRUSR | S_IWUSR;

    // 先尝试打开已存在的共享内存（可能由 Swift 端预先创建）
    g_shm_fd = shm_open(shm_key, O_RDWR, shm_mode);

    // 如果打开失败，创建新的
    if (g_shm_fd == -1) {
        printf("[SpeedPatch] Shared memory not found, creating new one (mode=0600, key=%s)\n", shm_key);
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

    // 检查是否需要初始化: magic number 不匹配或 PID 复用
    bool need_init = false;

    // 读取 magic number 验证（volatile 确保从内存读取而非缓存）
    uint32_t current_magic = g_shared_memory->magic;
    uint32_t current_version = g_shared_memory->version;
    uint32_t current_owner = g_shared_memory->owner_pid;

    if (current_magic != MAGIC_NUMBER || current_version == 0) {
        // 共享内存未初始化或被损坏
        printf("[SpeedPatch] Shared memory not initialized (magic=0x%08X, version=%u), initializing...\n",
               current_magic, current_version);
        need_init = true;
    } else if (current_owner != (uint32_t)g_own_pid) {
        // 检测到 PID 复用: 旧共享内存属于另一个已死进程
        printf("[SpeedPatch] Detected stale shared memory (old_owner_pid=%u, new_pid=%u), reinitializing...\n",
               current_owner, g_own_pid);
        need_init = true;
    }

    if (need_init) {
        memset(g_shared_memory, 0, sizeof(SharedMemoryHeader));
        g_shared_memory->magic = MAGIC_NUMBER;
        g_shared_memory->version = CURRENT_VERSION;
        g_shared_memory->owner_pid = (uint32_t)g_own_pid;
        g_shared_memory->speed_ratio = DEFAULT_SPEED_RATIO;
        g_shared_memory->is_active = 0;
        g_shared_memory->timestamp = (uint64_t)time(NULL);
        msync(g_shared_memory, SHARED_MEMORY_SIZE, MS_SYNC);
        printf("[SpeedPatch] Shared memory initialized (owner_pid=%u, magic=0x%08X)\n",
               g_own_pid, MAGIC_NUMBER);
    } else {
        printf("[SpeedPatch] Connected to existing shared memory (owner_pid=%u, current_speed=%.2f, active=%s)\n",
               g_shared_memory->owner_pid,
               g_shared_memory->speed_ratio,
               g_shared_memory->is_active ? "true" : "false");
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

    // 注意：不调用 shm_unlink，因为 Swift 端可能仍然需要这个共享内存
    // 由 Swift 端在确认进程终止后负责清理
    printf("[SpeedPatch] Shared memory cleaned up (local mapping only)\n");
}

//
// 无锁原子读取 speed_ratio 和 is_active
//
// 由于 speed_ratio (4 bytes, float) 和 is_active (1 byte, uint8_t)
// 在现代 CPU 上的单字节/4 字节自然对齐读写是原子的，
// 不需要跨进程锁。Swift 端写，C 端读。
//
float speedpatch_get_speed_ratio(void) {
    if (g_shared_memory == NULL) {
        return DEFAULT_SPEED_RATIO;
    }

    // owner_pid 验证: 如果当前进程不是所有者，读到的数据可能无效
    if (g_shared_memory->owner_pid != (uint32_t)g_own_pid && g_shared_memory->owner_pid != 0) {
        return DEFAULT_SPEED_RATIO;
    }

    // magic number 验证: 确保共享内存结构有效
    if (g_shared_memory->magic != MAGIC_NUMBER) {
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

    // magic number 验证
    if (g_shared_memory->magic != MAGIC_NUMBER) {
        return false;
    }

    return (g_shared_memory->is_active != 0);
}

// ============================================================================
// 时间函数 Hook
// ============================================================================

typedef uint64_t (*mach_absolute_time_t)(void);
typedef int (*clock_gettime_t)(clockid_t clk_id, struct timespec *tp);
typedef int (*gettimeofday_t)(struct timeval *tp, void *tzp);
typedef unsigned int (*sleep_t)(unsigned int seconds);
typedef int (*usleep_t)(useconds_t usec);
typedef clock_t (*clock_t_func_t)(void);
typedef double (*CFAbsoluteTimeGetCurrent_t)(void);

static mach_absolute_time_t original_mach_absolute_time = NULL;
static clock_gettime_t original_clock_gettime = NULL;
static gettimeofday_t original_gettimeofday = NULL;
static sleep_t original_sleep = NULL;
static usleep_t original_usleep = NULL;
static clock_t_func_t original_clock = NULL;
static CFAbsoluteTimeGetCurrent_t original_CFAbsoluteTimeGetCurrent = NULL;

static uint64_t mach_absolute_time_to_units(uint64_t mach_time);
static uint64_t units_to_mach_absolute_time(uint64_t units);

//
// mach_absolute_time: 返回系统启动后的绝对时间（单位依赖 mach_timebase_info）
// 被 hook 后，如果 speed_ratio != 1.0，返回被缩放的时间
//
static uint64_t hooked_mach_absolute_time(void) {
    uint64_t current_time = original_mach_absolute_time();

    if (!speedpatch_is_active()) {
        return current_time;
    }

    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return current_time;
    }

    // 将 mach 时间转换为纳秒，按比例缩放，再转回来
    // 加速时 (ratio > 1.0): 纳秒值 / ratio = 更小的值 → 时间看起来更慢
    // 减速时 (ratio < 1.0): 纳秒值 / ratio = 更大的值 → 时间看起来更快
    uint64_t nanoseconds = mach_absolute_time_to_units(current_time);
    uint64_t modified_nanoseconds = (uint64_t)((double)nanoseconds / (double)ratio);

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

//
// clock_gettime: 获取指定时钟的时间
// 只修改单调时钟 (CLOCK_MONOTONIC*)，不修改挂钟时间 (CLOCK_REALTIME)
//
static int hooked_clock_gettime(clockid_t clk_id, struct timespec *tp) {
    // 只修改单调时钟，不修改真实挂钟时间
    if (clk_id != CLOCK_MONOTONIC && clk_id != CLOCK_MONOTONIC_RAW) {
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

//
// gettimeofday: 返回真实挂钟时间（不修改，保持真实时间）
// 加速通过修改 sleep/usleep 的等待时间来实现
//
static int hooked_gettimeofday(struct timeval *tp, void *tzp) {
    return original_gettimeofday(tp, tzp);
}

//
// sleep: 按 speed_ratio 缩短等待时间（加速 = 睡得更少）
//
static unsigned int hooked_sleep(unsigned int seconds) {
    if (!speedpatch_is_active() || seconds == 0) {
        return original_sleep(seconds);
    }

    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return original_sleep(seconds);
    }

    // 转换为微秒，按比例缩短
    // 加速时 (ratio > 1.0): total_usec / ratio = 更短的等待时间
    // 减速时 (ratio < 1.0): total_usec / ratio = 更长的等待时间
    unsigned long long total_usec = (unsigned long long)seconds * 1000000ULL;
    unsigned long long modified_usec = (unsigned long long)((double)total_usec / (double)ratio);

    if (modified_usec == 0) modified_usec = 1;

    // 通过原始 usleep 实现亚秒精度（避免被 fishhook 再次拦截）
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

//
// usleep: 按 speed_ratio 缩短等待时间
//
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

//
// clock: 返回进程 CPU 时间
// 被 hook 后，如果 speed_ratio != 1.0，返回被缩放的 CPU 时间
//
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

//
// CFAbsoluteTimeGetCurrent: 返回当前绝对时间（相对 2001-01-01 00:00:00 GMT）
// 被 hook 后，如果 speed_ratio != 1.0，返回被缩放的时间
//
// 注意：这会影响 CoreFoundation/Foundation 框架中基于 CFAbsoluteTimeGetCurrent 的计时
//
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

// ============================================================================
// fishhook 注册
// ============================================================================
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
               (unsigned long)(sizeof(rebindings) / sizeof(rebindings[0])));
    } else {
        fprintf(stderr, "[SpeedPatch] Failed to hook time functions, error code: %d\n", result);
    }

    // 尝试从 CoreFoundation 加载 CFAbsoluteTimeGetCurrent（作为备份）
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
    printf("[SpeedPatch] DYLIB loaded successfully (PID: %d)\n", getpid());

    uint32_t count = _dyld_image_count();
    printf("[SpeedPatch] %u images loaded in current process\n", count);

    if (speedpatch_init_shared_memory()) {
        printf("[SpeedPatch] Speed control initialized\n");
    } else {
        fprintf(stderr, "[SpeedPatch] Failed to initialize speed control\n");
    }

    speedpatch_hook_time_functions();

    printf("[SpeedPatch] ✅ Initialization complete. Waiting for speed control commands...\n");
}

__attribute__((destructor))
void speedpatch_cleanup(void) {
    printf("[SpeedPatch] DYLIB unloading (PID: %d)\n", getpid());
    speedpatch_cleanup_shared_memory();
}
