#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int fd;

static void emit_event(unsigned short type, unsigned short code, int value)
{
    struct input_event event = {.type = type, .code = code, .value = value};
    if (write(fd, &event, sizeof(event)) != sizeof(event)) {
        fprintf(stderr, "write event failed: %s\n", strerror(errno));
        exit(1);
    }
}

static void query_abs(void)
{
    const int codes[] = {ABS_X, ABS_Y, ABS_MT_POSITION_X, ABS_MT_POSITION_Y,
        ABS_MT_TRACKING_ID, ABS_MT_TOUCH_MAJOR, ABS_MT_PRESSURE, ABS_MT_SLOT};
    for (size_t i = 0; i < sizeof(codes) / sizeof(codes[0]); ++i) {
        struct input_absinfo info;
        if (ioctl(fd, EVIOCGABS(codes[i]), &info) == 0) {
            printf("abs %#x: min=%d max=%d fuzz=%d flat=%d resolution=%d\n",
                codes[i], info.minimum, info.maximum, info.fuzz, info.flat, info.resolution);
        } else {
            printf("abs %#x: %s\n", codes[i], strerror(errno));
        }
    }
}

static void swipe(int x0, int y0, int x1, int y1)
{
    emit_event(EV_ABS, ABS_MT_TRACKING_ID, 100);
    emit_event(EV_KEY, BTN_TOUCH, 1);
    for (int i = 0; i <= 20; ++i) {
        int x = x0 + (x1 - x0) * i / 20;
        int y = y0 + (y1 - y0) * i / 20;
        emit_event(EV_ABS, ABS_MT_POSITION_X, x);
        emit_event(EV_ABS, ABS_MT_POSITION_Y, y);
        emit_event(EV_SYN, SYN_REPORT, 0);
        usleep(15000);
    }
    emit_event(EV_ABS, ABS_MT_TRACKING_ID, -1);
    emit_event(EV_KEY, BTN_TOUCH, 0);
    emit_event(EV_SYN, SYN_REPORT, 0);
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "/dev/input/event2";
    fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (argc == 2 || strcmp(argv[2], "query") == 0) {
        query_abs();
    } else if (strcmp(argv[2], "power") == 0) {
        emit_event(EV_KEY, KEY_POWER, 1);
        emit_event(EV_SYN, SYN_REPORT, 0);
        usleep(100000);
        emit_event(EV_KEY, KEY_POWER, 0);
        emit_event(EV_SYN, SYN_REPORT, 0);
    } else if (argc == 7 && strcmp(argv[2], "swipe") == 0) {
        swipe(atoi(argv[3]), atoi(argv[4]), atoi(argv[5]), atoi(argv[6]));
    } else {
        fprintf(stderr, "usage: %s [eventN] query|power|swipe x0 y0 x1 y1\n", argv[0]);
        return 2;
    }
    close(fd);
    return 0;
}
