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
#include <spawn.h>

#include "fishhook.h"

// 递归注入：需要访问进程自身环境变量的链式表（用于退回到当前进程 env）
extern char **environ;

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
    uint8_t  recursive_inject;    // 1 byte,  offset 40  - 是否允许递归注入子进程（默认0=关）
    uint8_t  reserved[31];        // 31 bytes, offset 41-71
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
_Static_assert(offsetof(SharedMemoryHeader, recursive_inject) == 40, "recursive_inject offset mismatch");

static SharedMemoryHeader* g_shared_memory = NULL;
static int g_shm_fd = -1;
static pid_t g_own_pid = 0;
static mach_timebase_info_data_t g_timebase_info;

// 递归注入：本 dylib 的绝对路径（在构造函数中解析一次）。NULL 时递归注入整体失效。
static char* g_own_dylib_path = NULL;

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

bool speedpatch_is_recursive_inject(void) {
    if (g_shared_memory == NULL) {
        return false;
    }
    // magic number 验证
    if (g_shared_memory->magic != MAGIC_NUMBER) {
        return false;
    }
    return (g_shared_memory->recursive_inject != 0);
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
    bool state_changed = (ratio != g_last_known_ratio || active != g_last_known_active);

    if (!active) {
        int64_t current_real_ns = (int64_t)tp->tv_sec * 1000000000LL + (int64_t)tp->tv_nsec;
        if (state_changed) {
            g_clock_time_offset_ns = g_last_clock_ns - current_real_ns;
        }
        int64_t new_total_ns = current_real_ns + g_clock_time_offset_ns;
        if (new_total_ns <= g_last_clock_ns) {
            new_total_ns = g_last_clock_ns + 1;
        }
        g_last_clock_ns = new_total_ns;
        g_last_known_ratio = ratio;
        g_last_known_active = active;

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
            g_clock_time_offset_ns = g_last_clock_ns - current_real_ns;
        }
        int64_t new_total_ns = current_real_ns + g_clock_time_offset_ns;
        if (new_total_ns <= g_last_clock_ns) {
            new_total_ns = g_last_clock_ns + 1;
        }
        g_last_clock_ns = new_total_ns;
        g_last_known_ratio = ratio;
        g_last_known_active = active;

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
        double d_last_clock_ns = (double)g_last_clock_ns;
        double d_new_base_total_ns = (d_current_real_ns * d_ratio - d_last_clock_ns - 1.0) / (d_ratio - 1.0);
        int64_t new_base_total_ns = (int64_t)d_new_base_total_ns;
        g_base_clock_gettime_sec = new_base_total_ns / 1000000000LL;
        g_base_clock_gettime_nsec = (long)(new_base_total_ns - g_base_clock_gettime_sec * 1000000000LL);
        g_last_known_ratio = ratio;
        g_last_known_active = active;
    }

    int64_t base_total_ns =
        (int64_t)g_base_clock_gettime_sec * 1000000000LL +
        (int64_t)g_base_clock_gettime_nsec;
    int64_t delta_total_ns = current_real_ns - base_total_ns;

    int64_t adjusted_ns = (int64_t)((double)delta_total_ns * (double)ratio);
    int64_t new_total_ns = base_total_ns + adjusted_ns;

    if (new_total_ns <= g_last_clock_ns) {
        new_total_ns = g_last_clock_ns + 1;
    }

    g_last_clock_ns = new_total_ns;

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

// ============================================================================
// 递归注入 Hook（仅 recursive_inject=1 时生效）
// ============================================================================
//
// 默认关闭。开启后，SpeedPatch 会在进程 exec*/posix_spawn* 子进程时，把
// 本 dylib 通过全新构造的 DYLD_INSERT_LIBRARIES 环境变量递归注入到子进程，
// 使 Electron/Qt 等多进程应用的子进程同样被加速。
// 关闭时对现有行为零影响：四个 hook 全部原样透传。
//

typedef int (*execve_t)(const char* path, char* const argv[], char* const envp[]);
typedef int (*execvpe_t)(const char* file, char* const argv[], char* const envp[]);
typedef int (*posix_spawn_t)(pid_t* pid, const char* path,
                             const posix_spawn_file_actions_t* file_actions,
                             const posix_spawnattr_t* attrp,
                             char* const argv[], char* const envp[]);
typedef int (*posix_spawnp_t)(pid_t* pid, const char* file,
                              const posix_spawn_file_actions_t* file_actions,
                              const posix_spawnattr_t* attrp,
                              char* const argv[], char* const envp[]);

static execve_t      original_execve = NULL;
static execvpe_t     original_execvpe = NULL;
static posix_spawn_t original_posix_spawn = NULL;
static posix_spawnp_t original_posix_spawnp = NULL;

// 在构造函数中解析一次本 dylib 的绝对路径（用于注入子进程）。
static void speedpatch_resolve_own_dylib(void) {
    if (g_own_dylib_path != NULL) return;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name != NULL && strstr(name, "SpeedPatch") != NULL) {
            g_own_dylib_path = strdup(name);
            break;
        }
    }

    if (g_own_dylib_path != NULL) {
        printf("[SpeedPatch] Own dylib path for recursive injection: %s\n", g_own_dylib_path);
    } else {
        printf("[SpeedPatch] WARNING: could not resolve own dylib path; recursive injection disabled\n");
    }
}

// Chromium/Electron 子进程跳过：renderer/gpu/utility/zygote/broker 子进程
// 必须跳过（符号冲突会导致隔离容器崩溃，见项目历史）。
static bool speedpatch_chromium_skip(char* const argv[]) {
    if (argv == NULL) return false;

    static const char* const markers[] = {
        "--type=renderer",
        "--type=gpu-process",
        "--type=utility",
        "--type=zygote",
        "--type=broker",
    };

    for (size_t i = 0; argv[i] != NULL; i++) {
        for (size_t j = 0; j < sizeof(markers) / sizeof(markers[0]); j++) {
            if (strstr(argv[i], markers[j]) != NULL) return true;
        }
    }
    return false;
}

// argv 中已直接含有本 dylib 路径（防御性检查，避免二次注入）。
static bool speedpatch_argv_already_injected(char* const argv[]) {
    if (g_own_dylib_path == NULL || argv == NULL) return false;
    for (size_t i = 0; argv[i] != NULL; i++) {
        if (strstr(argv[i], g_own_dylib_path) != NULL) return true;
    }
    return false;
}

// 目标环境项是否应被剔除：
// 覆盖 DYLD_INSERT_LIBRARIES / OPENSWIFT_CONTAINER / DYLD_FORCE_FLAT_NAMESPACE
// （这三类都会被我们重建并重新注入）。
static bool speedpatch_env_should_drop(const char* entry) {
    if (strncmp(entry, "DYLD_INSERT_LIBRARIES=",
                sizeof("DYLD_INSERT_LIBRARIES=") - 1) == 0) return true;
    if (strncmp(entry, "OPENSWIFT_CONTAINER=",
                sizeof("OPENSWIFT_CONTAINER=") - 1) == 0) return true;
    if (strncmp(entry, "DYLD_FORCE_FLAT_NAMESPACE=",
                sizeof("DYLD_FORCE_FLAT_NAMESPACE=") - 1) == 0) return true;
    return false;
}

// 构造用于子进程的注入环境：
// - g_own_dylib_path 为 NULL 时放弃注入（返回 NULL）；
// - 拷贝原始环境，剔除上述三类键；
// - 末尾追加两条 malloc 字符串：DYLD_INSERT_LIBRARIES=<own> 和 DYLD_FORCE_FLAT_NAMESPACE=1。
// 返回值：新分配的 NULL 结尾数组；其中的两个追加键字符串为新增分配，
// 原始环境项不归我们所有（调用方用 speedpatch_free_injected_env 释放）。
static char** speedpatch_build_injected_env(char* const envp[]) {
    if (g_own_dylib_path == NULL) return NULL;

    char** base = (char**)envp;
    if (base == NULL) base = environ;
    if (base == NULL) return NULL; // 环境完全为空

    // 先统计保留的条目数
    size_t kept = 0;
    for (size_t i = 0; base[i] != NULL; i++) {
        if (!speedpatch_env_should_drop(base[i])) kept++;
    }

    // kept 个保留项 + 2 个追加键 + 1 个 NULL 结尾
    char** result = (char**)malloc((kept + 3) * sizeof(char*));
    if (result == NULL) return NULL;

    size_t idx = 0;
    for (size_t i = 0; base[i] != NULL; i++) {
        if (!speedpatch_env_should_drop(base[i])) result[idx++] = base[i];
    }

    // 追加 DYLD_INSERT_LIBRARIES=<own>
    static const char kInsertKey[] = "DYLD_INSERT_LIBRARIES=";
    size_t key_len = sizeof(kInsertKey) - 1;
    size_t path_len = strlen(g_own_dylib_path);
    char* inject = (char*)malloc(key_len + path_len + 1);
    if (inject == NULL) {
        free(result);
        return NULL;
    }
    memcpy(inject, kInsertKey, key_len);
    memcpy(inject + key_len, g_own_dylib_path, path_len);
    inject[key_len + path_len] = '\0';
    result[idx++] = inject;

    // 追加 DYLD_FORCE_FLAT_NAMESPACE=1
    static const char kFlatKey[] = "DYLD_FORCE_FLAT_NAMESPACE=1";
    char* flat = (char*)malloc(sizeof(kFlatKey));
    if (flat == NULL) {
        free(inject);
        free(result);
        return NULL;
    }
    memcpy(flat, kFlatKey, sizeof(kFlatKey));
    result[idx++] = flat;

    result[idx] = NULL;
    return result;
}

// 释放注入环境：只释放数组本身和末尾 added 个追加键字符串。
static void speedpatch_free_injected_env(char** arr, size_t added) {
    if (arr == NULL) return;

    size_t total = 0;
    while (arr[total] != NULL) total++;

    size_t start = (total >= added) ? (total - added) : 0;
    for (size_t i = start; i < total; i++) {
        free(arr[i]);
    }
    free(arr);
}

//
// 四个 hook 包装：execve / execvpe / posix_spawn / posix_spawnp
// 关闭时（默认）全部原样透传；开启且条件满足时替换 envp 为注入环境。
//

static int hooked_execve(const char* path, char* const argv[], char* const envp[]) {
    if (!speedpatch_is_recursive_inject()
        || g_own_dylib_path == NULL
        || speedpatch_chromium_skip(argv)
        || speedpatch_argv_already_injected(argv)) {
        return original_execve(path, argv, envp);
    }

    char** injected = speedpatch_build_injected_env(envp);
    if (injected == NULL) return original_execve(path, argv, envp);

    // exec 成功不会返回；只有失败才返回，此时释放注入环境
    int result = original_execve(path, argv, injected);
    speedpatch_free_injected_env(injected, 2);
    return result;
}

static int hooked_execvpe(const char* file, char* const argv[], char* const envp[]) {
    if (!speedpatch_is_recursive_inject()
        || g_own_dylib_path == NULL
        || speedpatch_chromium_skip(argv)
        || speedpatch_argv_already_injected(argv)) {
        return original_execvpe(file, argv, envp);
    }

    char** injected = speedpatch_build_injected_env(envp);
    if (injected == NULL) return original_execvpe(file, argv, envp);

    int result = original_execvpe(file, argv, injected);
    speedpatch_free_injected_env(injected, 2);
    return result;
}

static int hooked_posix_spawn(pid_t* pid, const char* path,
                              const posix_spawn_file_actions_t* file_actions,
                              const posix_spawnattr_t* attrp,
                              char* const argv[], char* const envp[]) {
    if (!speedpatch_is_recursive_inject()
        || g_own_dylib_path == NULL
        || speedpatch_chromium_skip(argv)
        || speedpatch_argv_already_injected(argv)) {
        return original_posix_spawn(pid, path, file_actions, attrp, argv, envp);
    }

    char** injected = speedpatch_build_injected_env(envp);
    if (injected == NULL) return original_posix_spawn(pid, path, file_actions, attrp, argv, envp);

    int result = original_posix_spawn(pid, path, file_actions, attrp, argv, injected);
    speedpatch_free_injected_env(injected, 2);
    return result;
}

static int hooked_posix_spawnp(pid_t* pid, const char* file,
                               const posix_spawn_file_actions_t* file_actions,
                               const posix_spawnattr_t* attrp,
                               char* const argv[], char* const envp[]) {
    if (!speedpatch_is_recursive_inject()
        || g_own_dylib_path == NULL
        || speedpatch_chromium_skip(argv)
        || speedpatch_argv_already_injected(argv)) {
        return original_posix_spawnp(pid, file, file_actions, attrp, argv, envp);
    }

    char** injected = speedpatch_build_injected_env(envp);
    if (injected == NULL) return original_posix_spawnp(pid, file, file_actions, attrp, argv, envp);

    int result = original_posix_spawnp(pid, file, file_actions, attrp, argv, injected);
    speedpatch_free_injected_env(injected, 2);
    return result;
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
        {"execve", hooked_execve, (void**)&original_execve},
        {"execvpe", hooked_execvpe, (void**)&original_execvpe},
        {"posix_spawn", hooked_posix_spawn, (void**)&original_posix_spawn},
        {"posix_spawnp", hooked_posix_spawnp, (void**)&original_posix_spawnp},
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

    // 解析本 dylib 的绝对路径（递归注入子进程用；找不到则递归注入整体失效）
    speedpatch_resolve_own_dylib();

    printf("[SpeedPatch] ✅ Initialization complete. Waiting for speed control commands...\n");
}

__attribute__((destructor))
void speedpatch_cleanup(void) {
    printf("[SpeedPatch] DYLIB unloading (PID: %d)\n", getpid());
    speedpatch_cleanup_shared_memory();
}
