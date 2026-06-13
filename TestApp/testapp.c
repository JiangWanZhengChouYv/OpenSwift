#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>

int main() {
    printf("TestApp started - PID: %d\n", getpid());
    printf("Using gettimeofday() for high-precision timestamps\n");
    printf("If speed control is active, timestamps will print faster/slower\n\n");
    fflush(stdout);

    int count = 0;
    while (count < 30) {
        struct timeval tv;
        gettimeofday(&tv, NULL);

        time_t sec = tv.tv_sec;
        struct tm *tm_info = localtime(&sec);
        char time_buf[32];
        strftime(time_buf, sizeof(time_buf), "%H:%M:%S", tm_info);

        printf("[%02d] %s.%03ld\n", count, time_buf, (long)(tv.tv_usec / 1000));
        fflush(stdout);

        count++;
        // 用 usleep 而不是 sleep —— fishhook 对 usleep 的符号更可靠
        usleep(1000000);
    }

    printf("TestApp finished\n");
    return 0;
}
