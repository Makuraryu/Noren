#ifndef NOREN_SOCKET_BRIDGE_H
#define NOREN_SOCKET_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

enum {
    NOREN_SOCKET_OK = 0,
    NOREN_SOCKET_WOULD_BLOCK = 1,
    NOREN_SOCKET_EOF = 2,
};

int noren_socket_listen(const char *path);
int noren_socket_prepare(const char *path);
int noren_socket_accept(int listener);
int noren_socket_connect(const char *path);
int noren_socket_read(
    int fd,
    uint8_t *buffer,
    size_t capacity,
    size_t *read_count
);
int noren_socket_write_all(int fd, const uint8_t *buffer, size_t length);
int noren_socket_write_some(
    int fd,
    const uint8_t *buffer,
    size_t length,
    size_t *write_count
);
int noren_socket_poll3(
    int first,
    int second,
    int third,
    int timeout_ms,
    int watch_second_write,
    int *ready_mask
);
int noren_poll_many(
    const int *fds,
    const uint8_t *interests,
    size_t count,
    int timeout_ms,
    uint8_t *ready
);
uint64_t noren_monotonic_millis(void);
uint64_t noren_wall_clock_minute(void);
int noren_format_local_hhmm(char *buffer, size_t capacity);
int noren_socket_close(int fd);
int noren_socket_remove(const char *path);
unsigned long noren_user_id(void);

#endif
