#ifndef NOREN_PTY_BRIDGE_H
#define NOREN_PTY_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

enum {
    NOREN_IO_OK = 0,
    NOREN_IO_WOULD_BLOCK = 1,
    NOREN_IO_EOF = 2,
};

typedef struct {
    int master_fd;
    int root_pid;
} NorenPtySpawnResult;

int noren_pty_spawn(
    const char *cwd,
    const char *const argv[],
    const char *const envp[],
    uint16_t rows,
    uint16_t cols,
    NorenPtySpawnResult *result
);
int noren_pty_resize(int master_fd, uint16_t rows, uint16_t cols);
int noren_pty_read(
    int master_fd,
    uint8_t *buffer,
    size_t capacity,
    size_t *read_count
);
int noren_pty_write(
    int master_fd,
    const uint8_t *buffer,
    size_t length,
    size_t *write_count
);
int noren_pty_poll_readable(int master_fd, int timeout_ms);
int noren_pty_signal_group(int root_pid, int signal_number);
int noren_pty_wait(int root_pid, int *status, int no_hang);
int noren_pty_close(int master_fd);

#endif
