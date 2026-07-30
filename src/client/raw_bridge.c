#if defined(__linux__)
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#endif

#include "raw_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

struct NorenRawTerminal {
    struct termios original;
    int signal_pipe[2];
    struct sigaction old_term;
    struct sigaction old_hup;
    struct sigaction old_winch;
    int active;
};

static NorenRawTerminal *active_terminal = NULL;

static void signal_handler(int signal_number) {
    if (active_terminal == NULL) {
        return;
    }
    const uint8_t byte = (uint8_t)signal_number;
    const ssize_t ignored = write(active_terminal->signal_pipe[1], &byte, 1);
    (void)ignored;
}

static int set_fd_flags(int fd) {
    const int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return -1;
    }
    return fcntl(fd, F_SETFD, FD_CLOEXEC);
}

NorenRawTerminal *noren_raw_enter(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) ||
        active_terminal != NULL) {
        errno = ENOTTY;
        return NULL;
    }
    NorenRawTerminal *terminal = calloc(1, sizeof(*terminal));
    if (terminal == NULL) {
        return NULL;
    }
    terminal->signal_pipe[0] = -1;
    terminal->signal_pipe[1] = -1;
    if (tcgetattr(STDIN_FILENO, &terminal->original) != 0) {
        free(terminal);
        return NULL;
    }
    struct termios raw = terminal->original;
    cfmakeraw(&raw);
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) {
        free(terminal);
        return NULL;
    }
    if (pipe(terminal->signal_pipe) != 0 ||
        set_fd_flags(terminal->signal_pipe[0]) != 0 ||
        set_fd_flags(terminal->signal_pipe[1]) != 0) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &terminal->original);
        if (terminal->signal_pipe[0] >= 0) close(terminal->signal_pipe[0]);
        if (terminal->signal_pipe[1] >= 0) close(terminal->signal_pipe[1]);
        free(terminal);
        return NULL;
    }

    struct sigaction action = {
        .sa_handler = signal_handler,
        .sa_flags = 0,
    };
    sigemptyset(&action.sa_mask);
    active_terminal = terminal;
    if (sigaction(SIGTERM, &action, &terminal->old_term) != 0 ||
        sigaction(SIGHUP, &action, &terminal->old_hup) != 0 ||
        sigaction(SIGWINCH, &action, &terminal->old_winch) != 0) {
        active_terminal = NULL;
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &terminal->original);
        close(terminal->signal_pipe[0]);
        close(terminal->signal_pipe[1]);
        free(terminal);
        return NULL;
    }
    terminal->active = 1;
    return terminal;
}

void noren_raw_restore(NorenRawTerminal *terminal) {
    if (terminal == NULL) {
        return;
    }
    if (terminal->active) {
        terminal->active = 0;
        active_terminal = NULL;
        sigaction(SIGTERM, &terminal->old_term, NULL);
        sigaction(SIGHUP, &terminal->old_hup, NULL);
        sigaction(SIGWINCH, &terminal->old_winch, NULL);
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &terminal->original);
        close(terminal->signal_pipe[0]);
        close(terminal->signal_pipe[1]);
    }
    free(terminal);
}

int noren_raw_get_size(uint16_t *rows, uint16_t *cols) {
    struct winsize size = {0};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0 ||
        size.ws_row == 0 || size.ws_col == 0) {
        return errno != 0 ? errno : EINVAL;
    }
    *rows = size.ws_row;
    *cols = size.ws_col;
    return 0;
}

int noren_raw_poll(
    NorenRawTerminal *terminal,
    int pty_fd,
    int timeout_ms,
    int *ready_mask
) {
    struct pollfd events[3] = {
        { .fd = STDIN_FILENO, .events = POLLIN, .revents = 0 },
        { .fd = pty_fd, .events = POLLIN | POLLHUP | POLLERR, .revents = 0 },
        {
            .fd = terminal->signal_pipe[0],
            .events = POLLIN,
            .revents = 0,
        },
    };
    const int result = poll(events, 3, timeout_ms);
    if (result < 0) {
        return errno == EINTR ? 0 : errno;
    }
    *ready_mask = 0;
    if (events[0].revents != 0) *ready_mask |= NOREN_POLL_STDIN;
    if (events[1].revents != 0) *ready_mask |= NOREN_POLL_PTY;
    if (events[2].revents != 0) *ready_mask |= NOREN_POLL_SIGNAL;
    return 0;
}

int noren_raw_read(uint8_t *buffer, size_t capacity, size_t *read_count) {
    const ssize_t result = read(STDIN_FILENO, buffer, capacity);
    if (result >= 0) {
        *read_count = (size_t)result;
        return 0;
    }
    *read_count = 0;
    return errno;
}

int noren_raw_write(const uint8_t *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        const ssize_t result = write(STDOUT_FILENO, buffer + offset, length - offset);
        if (result > 0) {
            offset += (size_t)result;
            continue;
        }
        if (result < 0 && errno == EINTR) {
            continue;
        }
        return errno != 0 ? errno : EIO;
    }
    return 0;
}

int noren_raw_take_signal(NorenRawTerminal *terminal) {
    uint8_t signal_number = 0;
    const ssize_t result = read(terminal->signal_pipe[0], &signal_number, 1);
    return result == 1 ? signal_number : 0;
}
