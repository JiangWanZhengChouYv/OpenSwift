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
#include <math.h>

#include "fishhook.h"

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."
#define SHARED_MEMORY_SIZE 4096

// 魔术数字，用于验证共享内存已正确初始化
#define SPDM_MAGIC 0x5350444D
#define SPDM_VERSION 2

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
    uint8_t  hook_wallclock;      // 1 byte,  offset 32  - 是否 hook 挂钟时间（默认1=开）
    uint8_t  reserved2[7];        // 7 bytes, offset 33-39 (填充到 8 字节边界)
    uint8_t  reserved[32];        // 32 bytes, offset 40-71
} SharedMemoryHeader;             // 总大小: 72 bytes

// 编译时断言：验证结构体大小和字段偏移
_Static_assert(sizeof(SharedMemoryHeader) == 72, "SharedMemoryHeader size mismatch");
_Static_assert(offsetof(SharedMemoryHeader, magic) == 0, "magic offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, version) == 4, "version offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, owner_pid) == 8, "owner_pid offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, speed_ratio) == 12, "speed_ratio offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, is_active) == 16, "is_active offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, timestamp) == 24, "timestamp offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, hook_wallclock) == 32, "hook_wallclock offset mismatch");

static SharedMemoryHeader* g_shared_memory = NULL;
static int g_shm_fd = -1;
static pid_t g_own_pid = 0;
static mach_timebase_info_data_t g_timebase_info;

static const uint32_t CURRENT_VERSION = SPDM_VERSION;
static const uint32_t MAGIC_NUMBER = SPDM_MAGIC;
static const float MIN_SPEED_RATIO = 0.1f;
static const float MAX_SPEED_RATIO = 15.0f;
static const float DEFAULT_SPEED_RATIO = 1.0f;

// 时间函数 Hook 的基准时间值（由 speedpatch_init_time_base 初始化）
static uint64_t g_base_mach_absolute_time = 0;
static int64_t  g_base_clock_gettime_sec = 0;
static long     g_base_clock_gettime_nsec = 0;
static bool     g_time_base_initialized = false;

// 单调性保护变量：确保缩放后的时间始终单调递增
static uint64_t g_last_returned_mach_time = 0;
static int64_t  g_last_clock_ns = INT64_MIN;

// 时间偏移量：从加速状态切到 1x 或关闭时保持时间连续
static int64_t g_mach_time_offset = 0;
static int64_t g_clock_time_offset_ns = 0;

// 记录上一次的 ratio 和 active 状态，用于检测倍率变化并重置基准
static float g_last_known_ratio = 1.0f;
static bool  g_last_known_active = false;

// mach_continuous_time 专属状态变量（休眠时继续计数，与 mach_absolute_time 隔离）
static uint64_t g_base_mach_continuous_time = 0;
static uint64_t g_last_returned_mach_continuous = 0;
static int64_t  g_mach_continuous_offset = 0;
static float    g_last_known_continuous_ratio = 1.0f;
static bool     g_last_known_continuous_active = false;

// 挂钟时间 hook 专属状态变量（与单调时钟隔离）
static int64_t  g_base_wall_sec = 0;
static long     g_base_wall_nsec = 0;
static int64_t  g_last_wall_ns = INT64_MIN;
static int64_t  g_wall_time_offset_ns = 0;
static float    g_last_known_wall_ratio = 1.0f;
static bool     g_last_known_wall_active = false;

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
        g_shared_memory->hook_wallclock = 1;
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

bool speedpatch_is_wallclock_hooked(void) {
    if (g_shared_memory == NULL) {
        return true;  // 默认开启
    }
    if (g_shared_memory->magic != MAGIC_NUMBER) {
        return true;  // magic 校验失败默认开启
    }
    return (g_shared_memory->hook_wallclock != 0);
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
typedef int (*nanosleep_t)(const struct timespec *req, struct timespec *rem);
typedef time_t (*time_t_func_t)(time_t *tloc);
typedef uint64_t (*mach_continuous_time_t)(void);
typedef uint64_t (*mach_approximate_time_t)(void);
typedef uint64_t (*clock_gettime_nsec_np_t)(clockid_t clk_id);

static mach_absolute_time_t original_mach_absolute_time = NULL;
static clock_gettime_t original_clock_gettime = NULL;
static gettimeofday_t original_gettimeofday = NULL;
static sleep_t original_sleep = NULL;
static usleep_t original_usleep = NULL;
static clock_t_func_t original_clock = NULL;
static CFAbsoluteTimeGetCurrent_t original_CFAbsoluteTimeGetCurrent = NULL;
static nanosleep_t original_nanosleep = NULL;
static time_t_func_t original_time = NULL;
static mach_continuous_time_t original_mach_continuous_time = NULL;
static mach_approximate_time_t original_mach_continuous_approximate_time = NULL;
static mach_approximate_time_t original_mach_approximate_time = NULL;
static clock_gettime_nsec_np_t original_clock_gettime_nsec_np = NULL;

//
// mach_absolute_time: 返回系统启动后的绝对时间（单位依赖 mach_timebase_info）
// 被 hook 后，如果 speed_ratio != 1.0，返回被缩放的时间（基于基准时间法）
// 保持单调递增语义。
//
static uint64_t hooked_mach_absolute_time(void) {
    uint64_t current_time = original_mach_absolute_time();

    bool active = speedpatch_is_active();
    float ratio = speedpatch_get_speed_ratio();
    bool state_changed = (ratio != g_last_known_ratio || active != g_last_known_active);

    if (!active) {
        if (state_changed) {
            g_mach_time_offset = (int64_t)g_last_returned_mach_time - (int64_t)current_time;
        }
        uint64_t result = current_time + (uint64_t)g_mach_time_offset;
        if (result <= g_last_returned_mach_time) {
            result = g_last_returned_mach_time + 1;
        }
        g_last_returned_mach_time = result;
        g_last_known_ratio = ratio;
        g_last_known_active = active;
        return result;
    }

    if (ratio <= 0.0f || ratio == 1.0f) {
        if (state_changed) {
            g_mach_time_offset = (int64_t)g_last_returned_mach_time - (int64_t)current_time;
        }
        uint64_t result = current_time + (uint64_t)g_mach_time_offset;
        if (result <= g_last_returned_mach_time) {
            result = g_last_returned_mach_time + 1;
        }
        g_last_returned_mach_time = result;
        g_last_known_ratio = ratio;
        g_last_known_active = active;
        return result;
    }

    if (state_changed) {
        double d_ratio = (double)ratio;
        double d_current_time = (double)current_time;
        double d_last_returned = (double)g_last_returned_mach_time;
        double d_new_base = (d_current_time * d_ratio - d_last_returned - 1.0) / (d_ratio - 1.0);
        g_base_mach_absolute_time = (uint64_t)d_new_base;
        g_last_known_ratio = ratio;
        g_last_known_active = active;
    }

    uint64_t base = g_base_mach_absolute_time;
    uint64_t result;

    int64_t delta = (int64_t)current_time - (int64_t)base;
    double scaled_delta = (double)delta * (double)ratio;
    result = (uint64_t)((double)base + scaled_delta);

    if (result <= g_last_returned_mach_time) {
        result = g_last_returned_mach_time + 1;
    }

    g_last_returned_mach_time = result;

    return result;
}

//
// mach_continuous_time: 返回系统启动后的连续时间（休眠时继续计数）
// libdispatch/GCD 内部使用此函数，需要独立缩放以避免与 mach_absolute_time 串扰
//
static uint64_t hooked_mach_continuous_time(void) {
    uint64_t current_time = original_mach_continuous_time();

    bool active = speedpatch_is_active();
    float ratio = speedpatch_get_speed_ratio();
    bool state_changed = (ratio != g_last_known_continuous_ratio || active != g_last_known_continuous_active);

    if (!active) {
        if (state_changed) {
            g_mach_continuous_offset = (int64_t)g_last_returned_mach_continuous - (int64_t)current_time;
        }
        uint64_t result = current_time + (uint64_t)g_mach_continuous_offset;
        if (result <= g_last_returned_mach_continuous) {
            result = g_last_returned_mach_continuous + 1;
        }
        g_last_returned_mach_continuous = result;
        g_last_known_continuous_ratio = ratio;
        g_last_known_continuous_active = active;
        return result;
    }

    if (ratio <= 0.0f || ratio == 1.0f) {
        if (state_changed) {
            g_mach_continuous_offset = (int64_t)g_last_returned_mach_continuous - (int64_t)current_time;
        }
        uint64_t result = current_time + (uint64_t)g_mach_continuous_offset;
        if (result <= g_last_returned_mach_continuous) {
            result = g_last_returned_mach_continuous + 1;
        }
        g_last_returned_mach_continuous = result;
        g_last_known_continuous_ratio = ratio;
        g_last_known_continuous_active = active;
        return result;
    }

    if (state_changed) {
        double d_ratio = (double)ratio;
        double d_current_time = (double)current_time;
        double d_last_returned = (double)g_last_returned_mach_continuous;
        double d_new_base = (d_current_time * d_ratio - d_last_returned - 1.0) / (d_ratio - 1.0);
        g_base_mach_continuous_time = (uint64_t)d_new_base;
        g_last_known_continuous_ratio = ratio;
        g_last_known_continuous_active = active;
    }

    uint64_t base = g_base_mach_continuous_time;
    double delta = (double)(current_time - base);
    uint64_t adjusted = base + (uint64_t)(delta * (double)ratio);

    if (adjusted <= g_last_returned_mach_continuous) {
        adjusted = g_last_returned_mach_continuous + 1;
    }
    g_last_returned_mach_continuous = adjusted;

    return adjusted;
}

//
// mach_continuous_approximate_time: 低精度连续时间，委托给 hooked_mach_continuous_time
//
static uint64_t hooked_mach_continuous_approximate_time(void) {
    return hooked_mach_continuous_time();
}

//
// mach_approximate_time: 低精度绝对时间，委托给 hooked_mach_absolute_time
//
static uint64_t hooked_mach_approximate_time(void) {
    return hooked_mach_absolute_time();
}

//
// clock_gettime: 获取指定时钟的时间
// 缩放单调时钟 (CLOCK_MONOTONIC*) 和挂钟时间 (CLOCK_REALTIME*)，
// 挂钟时间受 hook_wallclock 开关控制。
// 使用基准时间法缩放，并保持单调性。
//
static int hooked_clock_gettime(clockid_t clk_id, struct timespec *tp) {
    bool is_monotonic = (clk_id == CLOCK_MONOTONIC || clk_id == CLOCK_MONOTONIC_RAW
#ifdef CLOCK_MONOTONIC_RAW_APPROX
                         || clk_id == CLOCK_MONOTONIC_RAW_APPROX
#endif
#ifdef CLOCK_UPTIME_RAW
                         || clk_id == CLOCK_UPTIME_RAW
#endif
#ifdef CLOCK_UPTIME_RAW_APPROX
                         || clk_id == CLOCK_UPTIME_RAW_APPROX
#endif
                        );
    bool is_realtime = (clk_id == CLOCK_REALTIME
#ifdef CLOCK_REALTIME_RAW
                        || clk_id == CLOCK_REALTIME_RAW
#endif
#ifdef CLOCK_REALTIME_RAW_APPROX
                        || clk_id == CLOCK_REALTIME_RAW_APPROX
#endif
                       );

    if (!is_monotonic && !is_realtime) {
        return original_clock_gettime(clk_id, tp);
    }

    // 挂钟时间需要检查 hook_wallclock 开关
    if (is_realtime && !speedpatch_is_wallclock_hooked()) {
        return original_clock_gettime(clk_id, tp);
    }

    int result = original_clock_gettime(clk_id, tp);
    if (result != 0 || tp == NULL) {
        return result;
    }

    bool active = speedpatch_is_active();
    float ratio = speedpatch_get_speed_ratio();

    // 根据时钟类型选择状态变量（CLOCK_REALTIME 使用挂钟专属变量，避免串扰）
    float *p_last_ratio = is_realtime ? &g_last_known_wall_ratio : &g_last_known_ratio;
    bool *p_last_active = is_realtime ? &g_last_known_wall_active : &g_last_known_active;
    int64_t *p_last_ns = is_realtime ? &g_last_wall_ns : &g_last_clock_ns;
    int64_t *p_offset_ns = is_realtime ? &g_wall_time_offset_ns : &g_clock_time_offset_ns;
    int64_t *p_base_sec = is_realtime ? &g_base_wall_sec : &g_base_clock_gettime_sec;
    long *p_base_nsec = is_realtime ? &g_base_wall_nsec : &g_base_clock_gettime_nsec;

    bool state_changed = (ratio != *p_last_ratio || active != *p_last_active);

    if (!active) {
        int64_t current_real_ns = (int64_t)tp->tv_sec * 1000000000LL + (int64_t)tp->tv_nsec;
        if (state_changed) {
            *p_offset_ns = *p_last_ns - current_real_ns;
        }
        int64_t new_total_ns = current_real_ns + *p_offset_ns;
        if (new_total_ns <= *p_last_ns) {
            new_total_ns = *p_last_ns + 1;
        }
        *p_last_ns = new_total_ns;
        *p_last_ratio = ratio;
        *p_last_active = active;

        int64_t out_sec  = new_total_ns / 1000000000LL;
        long    out_nsec = (long)(new_total_ns - out_sec * 1000000000LL);

        if (out_nsec < 0) {
            out_nsec += 1000000000L;
            out_sec  -= 1;
        } else if (out_nsec >= 1000000000L) {
            out_nsec -= 1000000000L;
            out_sec  += 1;
        }

        tp->tv_sec  = (time_t)out_sec;
        tp->tv_nsec = out_nsec;

        return result;
    }

    if (ratio <= 0.0f || ratio == 1.0f) {
        int64_t current_real_ns = (int64_t)tp->tv_sec * 1000000000LL + (int64_t)tp->tv_nsec;
        if (state_changed) {
            *p_offset_ns = *p_last_ns - current_real_ns;
        }
        int64_t new_total_ns = current_real_ns + *p_offset_ns;
        if (new_total_ns <= *p_last_ns) {
            new_total_ns = *p_last_ns + 1;
        }
        *p_last_ns = new_total_ns;
        *p_last_ratio = ratio;
        *p_last_active = active;

        int64_t out_sec  = new_total_ns / 1000000000LL;
        long    out_nsec = (long)(new_total_ns - out_sec * 1000000000LL);

        if (out_nsec < 0) {
            out_nsec += 1000000000L;
            out_sec  -= 1;
        } else if (out_nsec >= 1000000000L) {
            out_nsec -= 1000000000L;
            out_sec  += 1;
        }

        tp->tv_sec  = (time_t)out_sec;
        tp->tv_nsec = out_nsec;

        return result;
    }

    int64_t current_real_ns = (int64_t)tp->tv_sec * 1000000000LL + (int64_t)tp->tv_nsec;

    if (state_changed) {
        double d_ratio = (double)ratio;
        double d_current_real_ns = (double)current_real_ns;
        double d_last_ns = (double)*p_last_ns;
        double d_new_base_total_ns = (d_current_real_ns * d_ratio - d_last_ns - 1.0) / (d_ratio - 1.0);
        int64_t new_base_total_ns = (int64_t)d_new_base_total_ns;
        *p_base_sec = new_base_total_ns / 1000000000LL;
        *p_base_nsec = (long)(new_base_total_ns - *p_base_sec * 1000000000LL);
        *p_last_ratio = ratio;
        *p_last_active = active;
    }

    int64_t base_total_ns =
        (int64_t)*p_base_sec * 1000000000LL +
        (int64_t)*p_base_nsec;
    int64_t delta_total_ns = current_real_ns - base_total_ns;

    int64_t adjusted_ns = (int64_t)((double)delta_total_ns * (double)ratio);
    int64_t new_total_ns = base_total_ns + adjusted_ns;

    if (new_total_ns <= *p_last_ns) {
        new_total_ns = *p_last_ns + 1;
    }

    *p_last_ns = new_total_ns;

    int64_t out_sec  = new_total_ns / 1000000000LL;
    long    out_nsec = (long)(new_total_ns - out_sec * 1000000000LL);

    if (out_nsec < 0) {
        out_nsec += 1000000000L;
        out_sec  -= 1;
    } else if (out_nsec >= 1000000000L) {
        out_nsec -= 1000000000L;
        out_sec  += 1;
    }

    tp->tv_sec  = (time_t)out_sec;
    tp->tv_nsec = out_nsec;

    return result;
}

//
// gettimeofday: 返回挂钟时间，受 hook_wallclock 开关控制
// 使用基准时间法缩放，并保持单调性。算法与 hooked_clock_gettime 一致，
// 但使用挂钟专属状态变量，避免与单调时钟状态互相干扰。
//
static int hooked_gettimeofday(struct timeval *tp, void *tzp) {
    int result = original_gettimeofday(tp, tzp);
    if (result != 0 || tp == NULL) {
        return result;
    }

    // 如果有时区参数，不修改（保持原样）
    // 注意：tzp 参数现代 macOS 已废弃，通常为 NULL

    bool active = speedpatch_is_active();
    bool wallclock_hooked = speedpatch_is_wallclock_hooked();
    float ratio = speedpatch_get_speed_ratio();
    bool state_changed = (ratio != g_last_known_wall_ratio || active != g_last_known_wall_active);

    // 不满足缩放条件：返回真实时间（但通过 offset 保持连续）
    if (!active || !wallclock_hooked || ratio <= 0.0f || ratio == 1.0f) {
        int64_t current_real_ns = (int64_t)tp->tv_sec * 1000000000LL + (int64_t)tp->tv_usec * 1000;
        if (state_changed) {
            g_wall_time_offset_ns = g_last_wall_ns - current_real_ns;
        }
        int64_t new_total_ns = current_real_ns + g_wall_time_offset_ns;
        if (new_total_ns <= g_last_wall_ns) {
            new_total_ns = g_last_wall_ns + 1;
        }
        g_last_wall_ns = new_total_ns;
        g_last_known_wall_ratio = ratio;
        g_last_known_wall_active = active;

        int64_t out_sec = new_total_ns / 1000000000LL;
        long out_nsec = (long)(new_total_ns - out_sec * 1000000000LL);
        if (out_nsec < 0) {
            out_nsec += 1000000000L;
            out_sec -= 1;
        }
        tp->tv_sec = (time_t)out_sec;
        tp->tv_usec = (__darwin_suseconds_t)(out_nsec / 1000);
        return result;
    }

    // 缩放分支
    int64_t current_real_ns = (int64_t)tp->tv_sec * 1000000000LL + (int64_t)tp->tv_usec * 1000;

    if (state_changed) {
        double d_ratio = (double)ratio;
        double d_current_real_ns = (double)current_real_ns;
        double d_last_wall_ns = (double)g_last_wall_ns;
        double d_new_base_total_ns = (d_current_real_ns * d_ratio - d_last_wall_ns - 1.0) / (d_ratio - 1.0);
        int64_t new_base_total_ns = (int64_t)d_new_base_total_ns;
        g_base_wall_sec = new_base_total_ns / 1000000000LL;
        g_base_wall_nsec = (long)(new_base_total_ns - g_base_wall_sec * 1000000000LL);
        g_last_known_wall_ratio = ratio;
        g_last_known_wall_active = active;
    }

    int64_t base_total_ns = (int64_t)g_base_wall_sec * 1000000000LL + (int64_t)g_base_wall_nsec;
    int64_t delta_total_ns = current_real_ns - base_total_ns;
    int64_t adjusted_ns = (int64_t)((double)delta_total_ns * (double)ratio);
    int64_t new_total_ns = base_total_ns + adjusted_ns;

    if (new_total_ns <= g_last_wall_ns) {
        new_total_ns = g_last_wall_ns + 1;
    }
    g_last_wall_ns = new_total_ns;

    int64_t out_sec = new_total_ns / 1000000000LL;
    long out_nsec = (long)(new_total_ns - out_sec * 1000000000LL);
    if (out_nsec < 0) {
        out_nsec += 1000000000L;
        out_sec -= 1;
    }
    tp->tv_sec = (time_t)out_sec;
    tp->tv_usec = (__darwin_suseconds_t)(out_nsec / 1000);
    return result;
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
// nanosleep: 按 speed_ratio 缩短休眠时间（加速 = 睡得更少）
// 覆盖 Qt QThread::msleep、GCD dispatch_after 底层休眠等场景
//
static int hooked_nanosleep(const struct timespec *req, struct timespec *rem) {
    if (!speedpatch_is_active() || req == NULL) {
        return original_nanosleep(req, rem);
    }

    float ratio = speedpatch_get_speed_ratio();
    if (ratio <= 0.0f || ratio == 1.0f) {
        return original_nanosleep(req, rem);
    }

    // 按 1/ratio 缩放休眠时间
    double scaled_sec = (double)req->tv_sec / (double)ratio;
    double scaled_nsec = (double)req->tv_nsec / (double)ratio;

    // 归一化纳秒到 0-999999999
    scaled_sec += floor(scaled_nsec / 1000000000.0);
    scaled_nsec = fmod(scaled_nsec, 1000000000.0);
    if (scaled_nsec < 0) {
        scaled_nsec += 1000000000.0;
        scaled_sec -= 1.0;
    }

    struct timespec scaled_req;
    scaled_req.tv_sec = (time_t)scaled_sec;
    scaled_req.tv_nsec = (long)scaled_nsec;

    if (scaled_req.tv_sec == 0 && scaled_req.tv_nsec == 0) {
        scaled_req.tv_nsec = 1;  // 至少休眠 1ns 避免忙等
    }

    return original_nanosleep(&scaled_req, rem);
}

//
// time: 返回当前时间戳 (time_t)
// 受 hook_wallclock 开关控制，复用 hooked_gettimeofday 的缩放逻辑
//
static time_t hooked_time(time_t *tloc) {
    bool active = speedpatch_is_active();
    bool wallclock_hooked = speedpatch_is_wallclock_hooked();
    float ratio = speedpatch_get_speed_ratio();

    // 不满足缩放条件：透传原函数
    if (!active || !wallclock_hooked || ratio <= 0.0f || ratio == 1.0f) {
        return original_time(tloc);
    }

    // 满足缩放条件：通过 hooked_gettimeofday 获取缩放后的时间
    struct timeval tv;
    int result = hooked_gettimeofday(&tv, NULL);
    if (result != 0) {
        return original_time(tloc);
    }

    time_t scaled_time = (time_t)tv.tv_sec;
    if (tloc != NULL) {
        *tloc = scaled_time;
    }
    return scaled_time;
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

    return (clock_t)((double)result * (double)ratio);
}

//
// CFAbsoluteTimeGetCurrent: 返回当前绝对时间（相对 2001-01-01 00:00:00 GMT）
// 基于 hooked_gettimeofday 实现，与挂钟时间 hook 行为保持一致。
// 保留函数签名以维持 fishhook rebinding 表不变。
//
static double hooked_CFAbsoluteTimeGetCurrent(void) {
    struct timeval tv;
    if (hooked_gettimeofday(&tv, NULL) != 0) {
        // fallback：返回真实时间
        return original_CFAbsoluteTimeGetCurrent();
    }
    // CFAbsoluteTime 相对 2001-01-01 00:00:00 GMT
    // Unix time 相对 1970-01-01 00:00:00 GMT
    // 差值 = 978307200.0 秒
    double unix_time = (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
    return unix_time - 978307200.0;
}

//
// clock_gettime_nsec_np: 返回指定时钟的纳秒时间戳
// Apple 推荐用此替代 mach_absolute_time，需要根据 clk_id 选择缩放路径
//
static uint64_t hooked_clock_gettime_nsec_np(clockid_t clk_id) {
    bool active = speedpatch_is_active();
    float ratio = speedpatch_get_speed_ratio();

    // 不满足缩放条件：透传
    if (!active || ratio <= 0.0f || ratio == 1.0f) {
        return original_clock_gettime_nsec_np(clk_id);
    }

    // CLOCK_UPTIME_RAW / CLOCK_UPTIME_RAW_APPROX: 等价于 mach_absolute_time
    bool is_uptime = false;
#ifdef CLOCK_UPTIME_RAW
    if (clk_id == CLOCK_UPTIME_RAW) is_uptime = true;
#endif
#ifdef CLOCK_UPTIME_RAW_APPROX
    if (clk_id == CLOCK_UPTIME_RAW_APPROX) is_uptime = true;
#endif
    if (is_uptime) {
        uint64_t mach_time = hooked_mach_absolute_time();
        // 转换 tick 为纳秒
        static mach_timebase_info_data_t s_timebase = {0, 0};
        if (s_timebase.denom == 0) {
            mach_timebase_info(&s_timebase);
        }
        return mach_time * s_timebase.numer / s_timebase.denom;
    }

    // CLOCK_MONOTONIC_RAW / CLOCK_MONOTONIC_RAW_APPROX: 等价于 mach_continuous_time
    bool is_continuous = false;
#ifdef CLOCK_MONOTONIC_RAW
    if (clk_id == CLOCK_MONOTONIC_RAW) is_continuous = true;
#endif
#ifdef CLOCK_MONOTONIC_RAW_APPROX
    if (clk_id == CLOCK_MONOTONIC_RAW_APPROX) is_continuous = true;
#endif
    if (is_continuous) {
        uint64_t mach_time = hooked_mach_continuous_time();
        static mach_timebase_info_data_t s_timebase_c = {0, 0};
        if (s_timebase_c.denom == 0) {
            mach_timebase_info(&s_timebase_c);
        }
        return mach_time * s_timebase_c.numer / s_timebase_c.denom;
    }

    // CLOCK_REALTIME 等：委托给 hooked_clock_gettime
    bool is_realtime = (clk_id == CLOCK_REALTIME);
#ifdef CLOCK_REALTIME_RAW
    if (clk_id == CLOCK_REALTIME_RAW) is_realtime = true;
#endif
#ifdef CLOCK_REALTIME_RAW_APPROX
    if (clk_id == CLOCK_REALTIME_RAW_APPROX) is_realtime = true;
#endif
    if (is_realtime) {
        if (!speedpatch_is_wallclock_hooked()) {
            return original_clock_gettime_nsec_np(clk_id);
        }
        struct timespec ts;
        if (hooked_clock_gettime(clk_id, &ts) == 0) {
            return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
        }
        return original_clock_gettime_nsec_np(clk_id);
    }

    // 其他时钟类型：透传
    return original_clock_gettime_nsec_np(clk_id);
}

// ============================================================================
// fishhook 注册
// ============================================================================

// 初始化时间 Hook 的基准时间值，
// 必须在 fishhook 替换 original_* 指针之后、且在用户代码真正访问时间函数之前调用。
static void speedpatch_init_time_base(void) {
    if (g_time_base_initialized) return;

    if (original_mach_absolute_time != NULL) {
        g_base_mach_absolute_time = original_mach_absolute_time();
        g_last_returned_mach_time = g_base_mach_absolute_time;
    }

    if (original_mach_continuous_time != NULL) {
        g_base_mach_continuous_time = original_mach_continuous_time();
        g_last_returned_mach_continuous = g_base_mach_continuous_time;
    }

    if (original_clock_gettime != NULL) {
        struct timespec tp;
        if (original_clock_gettime(CLOCK_MONOTONIC, &tp) == 0) {
            g_base_clock_gettime_sec  = (int64_t)tp.tv_sec;
            g_base_clock_gettime_nsec = (long)tp.tv_nsec;
            g_last_clock_ns = (int64_t)tp.tv_sec * 1000000000LL + (int64_t)tp.tv_nsec;
        }
    }

    if (original_gettimeofday != NULL) {
        struct timeval tv;
        if (original_gettimeofday(&tv, NULL) == 0) {
            g_base_wall_sec = (int64_t)tv.tv_sec;
            g_base_wall_nsec = (long)tv.tv_usec * 1000;
            g_last_wall_ns = (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000;
        }
    }

    g_time_base_initialized = true;
    printf("[SpeedPatch] Time base initialized (mach_base=%llu, clock_monotonic_base_sec=%lld, nsec=%ld)\n",
           (unsigned long long)g_base_mach_absolute_time,
           (long long)g_base_clock_gettime_sec,
           g_base_clock_gettime_nsec);
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
        {"nanosleep", hooked_nanosleep, (void**)&original_nanosleep},
        {"time", hooked_time, (void**)&original_time},
        {"mach_continuous_time", hooked_mach_continuous_time, (void**)&original_mach_continuous_time},
        {"mach_continuous_approximate_time", hooked_mach_continuous_approximate_time, (void**)&original_mach_continuous_approximate_time},
        {"mach_approximate_time", hooked_mach_approximate_time, (void**)&original_mach_approximate_time},
        {"clock_gettime_nsec_np", hooked_clock_gettime_nsec_np, (void**)&original_clock_gettime_nsec_np},
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

    // 鱼钩替换完毕、original_* 指针已就绪，初始化时间基准值
    speedpatch_init_time_base();

    printf("[SpeedPatch] ✅ Initialization complete. Waiting for speed control commands...\n");
}

__attribute__((destructor))
void speedpatch_cleanup(void) {
    printf("[SpeedPatch] DYLIB unloading (PID: %d)\n", getpid());
    speedpatch_cleanup_shared_memory();
}
