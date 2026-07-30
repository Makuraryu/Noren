#ifndef NOREN_RAW_BRIDGE_H
#define NOREN_RAW_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct NorenRawTerminal NorenRawTerminal;

enum {
    NOREN_POLL_STDIN = 1 << 0,
    NOREN_POLL_PTY = 1 << 1,
    NOREN_POLL_SIGNAL = 1 << 2,
};

NorenRawTerminal *noren_raw_enter(void);
void noren_raw_restore(NorenRawTerminal *terminal);
int noren_raw_get_size(uint16_t *rows, uint16_t *cols);
int noren_raw_poll(
    NorenRawTerminal *terminal,
    int pty_fd,
    int timeout_ms,
    int *ready_mask
);
int noren_raw_read(uint8_t *buffer, size_t capacity, size_t *read_count);
int noren_raw_write(const uint8_t *buffer, size_t length);
int noren_raw_take_signal(NorenRawTerminal *terminal);

#endif
