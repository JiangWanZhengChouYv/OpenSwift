#ifndef speedpatch_h
#define speedpatch_h

#include <stdint.h>
#include <stdbool.h>

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."

#define MIN_SPEED_RATIO 0.1f
#define MAX_SPEED_RATIO 10.0f
#define DEFAULT_SPEED_RATIO 1.0f

typedef struct {
    uint32_t version;
    float speed_ratio;
    bool is_active;
    uint64_t timestamp;
    uint8_t reserved[56];
} __attribute__((packed)) SharedMemoryHeader;

#ifdef __cplusplus
extern "C" {
#endif

extern float speedpatch_get_speed_ratio(void);
extern bool speedpatch_is_active(void);

#ifdef __cplusplus
}
#endif

#endif
