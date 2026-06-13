// 模拟 OpenSwift 的行为：连接到共享内存，设置速度倍率，验证返回值
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <os/lock.h>

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."
#define SHARED_MEMORY_SIZE 4096

// 与 Swift/C 端相同的布局
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

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <target_pid> [speed_ratio] [enable]\n", argv[0]);
        fprintf(stderr, "  target_pid:  PID of the target process to connect to\n");
        fprintf(stderr, "  speed_ratio: 0.1 - 10.0 (default: 2.0)\n");
        fprintf(stderr, "  enable:      1 = enable, 0 = disable (default: 1)\n");
        return 1;
    }

    pid_t target_pid = (pid_t)atoi(argv[1]);
    float ratio = (argc > 2) ? atof(argv[2]) : 2.0f;
    int enable = (argc > 3) ? atoi(argv[3]) : 1;

    char shm_key[256];
    snprintf(shm_key, sizeof(shm_key), "%s%u", SHARED_MEMORY_KEY_PREFIX, target_pid);

    printf("=== OpenSwift Speed Control Test ===\n");
    printf("Target PID: %d\n", target_pid);
    printf("Shm key: %s\n", shm_key);
    printf("Target speed ratio: %.2f\n", ratio);
    printf("Enable: %s\n", enable ? "YES" : "NO");
    printf("\n");

    // 打开共享内存
    int fd = shm_open(shm_key, O_RDWR, 0600);
    if (fd == -1) {
        fprintf(stderr, "❌ Failed to open shared memory: %s\n", strerror(errno));
        return 1;
    }
    printf("✅ Shared memory opened (fd=%d)\n", fd);

    // 映射
    SharedMemoryHeader *header = (SharedMemoryHeader *)mmap(
        NULL, SHARED_MEMORY_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (header == MAP_FAILED) {
        fprintf(stderr, "❌ Failed to map shared memory: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    printf("✅ Shared memory mapped at %p\n", header);
    printf("\n");

    // 读取当前状态（先不加锁，后加锁验证）
    printf("=== Current State (before modification) ===\n");
    printf("version:     %u\n", header->version);
    printf("owner_pid:   %u\n", header->owner_pid);
    printf("speed_ratio: %.2f\n", header->speed_ratio);
    printf("is_active:   %u\n", header->is_active);
    printf("timestamp:   %llu\n", (unsigned long long)header->timestamp);
    printf("\n");

    // 加锁，修改状态
    printf("=== Modifying State ===\n");
    os_unfair_lock_lock(&header->lock);
    header->speed_ratio = ratio;
    header->is_active = enable ? 1 : 0;
    header->timestamp = (uint64_t)time(NULL);
    os_unfair_lock_unlock(&header->lock);

    msync(header, SHARED_MEMORY_SIZE, MS_SYNC);
    printf("✅ Wrote new state to shared memory\n");
    printf("\n");

    // 加锁读取，验证一致性
    printf("=== Verification (locked read) ===\n");
    os_unfair_lock_lock(&header->lock);
    float r_ratio = header->speed_ratio;
    uint8_t r_active = header->is_active;
    uint32_t r_owner = header->owner_pid;
    os_unfair_lock_unlock(&header->lock);

    printf("speed_ratio read back: %.2f\n", r_ratio);
    printf("is_active read back:   %u\n", r_active);
    printf("owner_pid read back:   %u\n", r_owner);
    printf("\n");

    int all_ok = 1;
    if (r_ratio != ratio) {
        printf("❌ speed_ratio mismatch! (expected %.2f, got %.2f)\n", ratio, r_ratio);
        all_ok = 0;
    } else {
        printf("✅ speed_ratio matches\n");
    }

    if (r_active != (enable ? 1 : 0)) {
        printf("❌ is_active mismatch! (expected %d, got %u)\n", enable, r_active);
        all_ok = 0;
    } else {
        printf("✅ is_active matches\n");
    }

    if (r_owner != (uint32_t)target_pid) {
        printf("⚠️  owner_pid mismatch! (expected %u, got %u) - PID might have been reused\n",
               target_pid, r_owner);
    } else {
        printf("✅ owner_pid matches target PID\n");
    }

    printf("\n");
    printf("=== RESULT: %s ===\n", all_ok ? "✅ ALL TESTS PASSED" : "❌ SOME TESTS FAILED");
    printf("\n");
    printf("Now wait 5 seconds. If TestApp is running with DYLD_INSERT_LIBRARIES pointing\n");
    printf("to SpeedPatch.dylib, it should be printing time at %.2fx speed.\n", ratio);
    printf("Press Ctrl+C to exit, or wait.\n");
    printf("\n");

    // 保持连接，让用户观察 TestApp 的输出变化
    for (int i = 0; i < 5; i++) {
        sleep(1);
        os_unfair_lock_lock(&header->lock);
        float live_ratio = header->speed_ratio;
        uint8_t live_active = header->is_active;
        os_unfair_lock_unlock(&header->lock);
        printf("  [%d] live: speed_ratio=%.2f, is_active=%u\n", i + 1, live_ratio, live_active);
    }

    // 清理
    munmap(header, SHARED_MEMORY_SIZE);
    close(fd);
    printf("\n✅ Test complete.\n");

    return 0;
}
