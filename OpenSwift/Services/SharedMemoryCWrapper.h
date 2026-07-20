#ifndef SharedMemoryCWrapper_h
#define SharedMemoryCWrapper_h

#include <sys/stat.h>

int swift_shm_open(const char *name, int oflag, mode_t mode);
int swift_shm_unlink(const char *name);

#endif /* SharedMemoryCWrapper_h */