#ifndef speedpatch_h
#define speedpatch_h

#include <stdint.h>
#include <stdbool.h>
#include <os/lock.h>

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."

#define MIN_SPEED_RATIO 0.1f
#define MAX_SPEED_RATIO 10.0f
#define DEFAULT_SPEED_RATIO 1.0f

// 共享内存 header - 自然对齐布局（与 Swift 端完全一致）
// 字段偏移:
//   lock:         0  (os_unfair_lock, 4 bytes) - 跨进程锁
//   version:      4  (uint32_t, 4 bytes)       - 协议版本
//   owner_pid:    8  (uint32_t, 4 bytes)       - 创建者 PID
//   speed_ratio:  12 (float, 4 bytes)          - 速度倍率
//   is_active:    16 (uint8_t, 1 byte)         - 是否启用
//   padding:      17-23 (7 bytes)              - 对齐填充
//   timestamp:    24 (uint64_t, 8 bytes)       - 时间戳
//   reserved:     32-71 (40 bytes)             - 预留
// 总大小: 72 bytes
typedef struct {
    os_unfair_lock lock;
    uint32_t version;
    uint32_t owner_pid;
    float speed_ratio;
    uint8_t is_active;
    uint8_t padding[7];
    uint64_t timestamp;
    uint8_t reserved[40];
} SharedMemoryHeader;

#ifdef __cplusplus
extern "C" {
#endif

extern float speedpatch_get_speed_ratio(void);
extern bool speedpatch_is_active(void);

#ifdef __cplusplus
}
#endif

#endif
