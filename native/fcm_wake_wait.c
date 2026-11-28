// SPDX-License-Identifier: MIT
// Minimal Android alarmtimer wakeup waiter for a root-owned Magisk service.
// No wakelock, network access, global alarm modifications, files or daemon.
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/timerfd.h>
#include <unistd.h>
#include <time.h>

#ifndef CLOCK_BOOTTIME_ALARM
#define CLOCK_BOOTTIME_ALARM 9
#endif

static int wakefd(void) {
    return timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_CLOEXEC);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
        int fd = wakefd();
        if (fd < 0) {
            fprintf(stderr, "fcm_wake_wait: alarmtimer unavailable: %s\n", strerror(errno));
            return 3;
        }
        close(fd);
        return 0;
    }
    if (argc != 2 || argv[1][0] == '-') {
        fprintf(stderr, "usage: fcm_wake_wait --probe | SECONDS(60..3600)\n");
        return 2;
    }
    char *end = NULL;
    errno = 0;
    unsigned long sec = strtoul(argv[1], &end, 10);
    if (errno || end == argv[1] || *end || sec < 60 || sec > 3600) {
        fprintf(stderr, "fcm_wake_wait: invalid wait interval\n");
        return 2;
    }
    int fd = wakefd();
    if (fd < 0) {
        fprintf(stderr, "fcm_wake_wait: alarmtimer unavailable: %s\n", strerror(errno));
        return 3;
    }
    struct itimerspec t = {0};
    t.it_value.tv_sec = (time_t)sec;
    if (timerfd_settime(fd, 0, &t, NULL) != 0) {
        fprintf(stderr, "fcm_wake_wait: arming failed: %s\n", strerror(errno));
        close(fd);
        return 3;
    }
    uint64_t fired = 0;
    ssize_t n;
    do {
        n = read(fd, &fired, sizeof fired);
    } while (n < 0 && errno == EINTR);
    int ok = (n == (ssize_t)sizeof fired && fired >= 1);
    if (!ok) {
        fprintf(stderr, "fcm_wake_wait: alarm read failed: %s\n", strerror(errno));
    }
    close(fd);
    return ok ? 0 : 3;
}
