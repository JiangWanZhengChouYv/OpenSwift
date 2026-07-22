#ifndef speedpatch_h
#define speedpatch_h

#include <stdint.h>
#include <stdbool.h>

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."

#define SPDM_MAGIC 0x5350444D
#define SPDM_VERSION 2
#define MIN_SPEED_RATIO 0.1f
#define MAX_SPEED_RATIO 15.0f
#define DEFAULT_SPEED_RATIO 1.0f

// 共享内存 header - 自然对齐布局（与 Swift 端完全一致）
// 注意: 不使用跨进程锁 (os_unfair_lock 不支持跨进程)
// speed_ratio (4 bytes, float) 和 is_active (1 byte, uint8_t)
// 的自然对齐读写在现代 CPU 上是原子的，因此无锁读写是安全的
//
// 字段偏移:
//   magic:        0  (uint32_t, 4 bytes) - 魔术数字 0x5350444D
//   version:      4  (uint32_t, 4 bytes) - 协议版本
//   owner_pid:    8  (uint32_t, 4 bytes) - 创建者 PID
//   speed_ratio:  12 (float, 4 bytes)    - 速度倍率
//   is_active:    16 (uint8_t, 1 byte)   - 是否启用
//   padding:      17-23 (7 bytes)        - 对齐填充
//   timestamp:    24 (uint64_t, 8 bytes) - 时间戳
//   reserved:     32-71 (40 bytes)       - 预留
// 总大小: 72 bytes
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t owner_pid;
    float    speed_ratio;
    uint8_t  is_active;
    uint8_t  padding[7];
    uint64_t timestamp;
    uint8_t  reserved[40];
} SharedMemoryHeader;

// 编译时断言：验证结构体大小和字段偏移
_Static_assert(sizeof(SharedMemoryHeader) == 72, "SharedMemoryHeader size mismatch");
_Static_assert(offsetof(SharedMemoryHeader, magic) == 0, "magic offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, version) == 4, "version offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, owner_pid) == 8, "owner_pid offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, speed_ratio) == 12, "speed_ratio offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, is_active) == 16, "is_active offset mismatch");
_Static_assert(offsetof(SharedMemoryHeader, timestamp) == 24, "timestamp offset mismatch");

#ifdef __cplusplus
extern "C" {
#endif

extern float speedpatch_get_speed_ratio(void);
extern bool speedpatch_is_active(void);

#ifdef __cplusplus
}
#endif

#endif
