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

#define SHARED_MEMORY_KEY_PREFIX "com.openswift.speedpatch."
#define SHARED_MEMORY_SIZE 4096

// 魔术数字，用于验证共享内存已正确初始化
#define SPDM_MAGIC 0x5350444D
#define SPDM_VERSION 1

// 与 Swift/C 端相同的布局（无锁，原子读写）
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

    // 验证 magic number，确保内存布局正确
    printf("=== Magic Number Verification ===\n");
    printf("magic:        0x%08X (expected: 0x%08X)\n", header->magic, SPDM_MAGIC);
    if (header->magic != SPDM_MAGIC) {
        printf("⚠️  Magic mismatch! Shared memory may not be initialized.\n");
        printf("    Initializing shared memory...\n");
        memset(header, 0, sizeof(SharedMemoryHeader));
        header->magic = SPDM_MAGIC;
        header->version = SPDM_VERSION;
        header->owner_pid = (uint32_t)target_pid;
        header->speed_ratio = 1.0f;
        header->is_active = 0;
        header->timestamp = (uint64_t)time(NULL);
        msync(header, SHARED_MEMORY_SIZE, MS_SYNC);
        printf("✅ Shared memory initialized.\n");
    } else {
        printf("✅ Magic number matches\n");
    }
    printf("\n");

    // 读取当前状态（无锁原子读取）
    printf("=== Current State (before modification) ===\n");
    printf("magic:       0x%08X\n", header->magic);
    printf("version:     %u\n", header->version);
    printf("owner_pid:   %u\n", header->owner_pid);
    printf("speed_ratio: %.2f\n", header->speed_ratio);
    printf("is_active:   %u\n", header->is_active);
    printf("timestamp:   %llu\n", (unsigned long long)header->timestamp);
    printf("\n");

    // 修改状态（无锁原子写入）
    printf("=== Modifying State ===\n");
    header->speed_ratio = ratio;
    header->is_active = enable ? 1 : 0;
    header->timestamp = (uint64_t)time(NULL);
    msync(header, SHARED_MEMORY_SIZE, MS_SYNC);
    printf("✅ Wrote new state to shared memory\n");
    printf("\n");

    // 读取验证（无锁原子读取）
    printf("=== Verification ===\n");
    float r_ratio = header->speed_ratio;
    uint8_t r_active = header->is_active;
    uint32_t r_owner = header->owner_pid;

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

    // 保持连接，让用户观察 TestApp 的输出变化（无锁原子读取）
    for (int i = 0; i < 5; i++) {
        sleep(1);
        float live_ratio = header->speed_ratio;
        uint8_t live_active = header->is_active;
        printf("  [%d] live: speed_ratio=%.2f, is_active=%u\n", i + 1, live_ratio, live_active);
    }

    // 清理
    munmap(header, SHARED_MEMORY_SIZE);
    close(fd);
    printf("\n✅ Test complete.\n");

    return 0;
}
