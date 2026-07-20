#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>

int swift_shm_open(const char *name, int oflag, mode_t mode) {
    return shm_open(name, oflag, mode);
}

int swift_shm_unlink(const char *name) {
    return shm_unlink(name);
}