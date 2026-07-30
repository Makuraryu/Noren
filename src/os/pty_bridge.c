#if defined(__linux__)
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#endif

#include "pty_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <string.h>

#if defined(__APPLE__)
extern pid_t forkpty(
    int *master,
    char *name,
    struct termios *term,
    struct winsize *size
);
#elif defined(__FreeBSD__)
#include <libutil.h>
#elif defined(__OpenBSD__) || defined(__NetBSD__)
#include <util.h>
#else
#include <pty.h>
#endif

static const char *find_environment_value(
    const char *const envp[],
    const char *key
) {
    if (envp == NULL) {
        return getenv(key);
    }
    const size_t key_length = strlen(key);
    for (size_t index = 0; envp[index] != NULL; index++) {
        if (strncmp(envp[index], key, key_length) == 0 &&
            envp[index][key_length] == '=') {
            return envp[index] + key_length + 1;
        }
    }
    return NULL;
}

static char *resolve_executable(
    const char *file,
    const char *const envp[]
) {
    if (strchr(file, '/') != NULL) {
        return strdup(file);
    }
    const char *path = find_environment_value(envp, "PATH");
    if (path == NULL) {
        path = "/usr/local/bin:/usr/bin:/bin";
    }
    const size_t file_length = strlen(file);
    const char *segment = path;
    while (1) {
        const char *separator = strchr(segment, ':');
        const size_t directory_length = separator == NULL
            ? strlen(segment)
            : (size_t)(separator - segment);
        const size_t effective_length = directory_length == 0
            ? 1
            : directory_length;
        char *candidate = malloc(effective_length + 1 + file_length + 1);
        if (candidate == NULL) {
            return NULL;
        }
        if (directory_length == 0) {
            candidate[0] = '.';
        } else {
            memcpy(candidate, segment, directory_length);
        }
        candidate[effective_length] = '/';
        memcpy(candidate + effective_length + 1, file, file_length + 1);
        if (access(candidate, X_OK) == 0) {
            return candidate;
        }
        free(candidate);
        if (separator == NULL) {
            break;
        }
        segment = separator + 1;
    }
    errno = ENOENT;
    return NULL;
}

int noren_pty_spawn(
    const char *cwd,
    const char *const argv[],
    const char *const envp[],
    uint16_t rows,
    uint16_t cols,
    NorenPtySpawnResult *result
) {
    if (argv == NULL || argv[0] == NULL || result == NULL ||
        rows == 0 || cols == 0) {
        return EINVAL;
    }
    char *executable = resolve_executable(argv[0], envp);
    if (executable == NULL) {
        return errno != 0 ? errno : ENOENT;
    }
    const struct winsize size = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    int master_fd = -1;
    const pid_t child = forkpty(&master_fd, NULL, NULL, &size);
    if (child < 0) {
        free(executable);
        return errno;
    }
    if (child == 0) {
        if (cwd != NULL && chdir(cwd) != 0) {
            _exit(126);
        }
        if (envp != NULL) {
            execve(executable, (char *const *)argv, (char *const *)envp);
        } else {
            execv(executable, (char *const *)argv);
        }
        _exit(errno == ENOENT ? 127 : 126);
    }
    free(executable);

    const int current_flags = fcntl(master_fd, F_GETFL);
    if (current_flags < 0 ||
        fcntl(master_fd, F_SETFL, current_flags | O_NONBLOCK) < 0 ||
        fcntl(master_fd, F_SETFD, FD_CLOEXEC) < 0) {
        const int saved_errno = errno;
        close(master_fd);
        kill(-child, SIGHUP);
        return saved_errno;
    }
    result->master_fd = master_fd;
    result->root_pid = child;
    return 0;
}

int noren_pty_resize(int master_fd, uint16_t rows, uint16_t cols) {
    const struct winsize size = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    return ioctl(master_fd, TIOCSWINSZ, &size) == 0 ? 0 : errno;
}

int noren_pty_read(
    int master_fd,
    uint8_t *buffer,
    size_t capacity,
    size_t *read_count
) {
    const ssize_t result = read(master_fd, buffer, capacity);
    if (result > 0) {
        *read_count = (size_t)result;
        return NOREN_IO_OK;
    }
    *read_count = 0;
    if (result == 0 || errno == EIO) {
        return NOREN_IO_EOF;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return NOREN_IO_WOULD_BLOCK;
    }
    return -errno;
}

int noren_pty_write(
    int master_fd,
    const uint8_t *buffer,
    size_t length,
    size_t *write_count
) {
    const ssize_t result = write(master_fd, buffer, length);
    if (result >= 0) {
        *write_count = (size_t)result;
        return NOREN_IO_OK;
    }
    *write_count = 0;
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return NOREN_IO_WOULD_BLOCK;
    }
    return -errno;
}

int noren_pty_poll_readable(int master_fd, int timeout_ms) {
    struct pollfd event = {
        .fd = master_fd,
        .events = POLLIN | POLLHUP | POLLERR,
        .revents = 0,
    };
    const int result = poll(&event, 1, timeout_ms);
    if (result < 0) {
        return -errno;
    }
    return result;
}

int noren_pty_signal_group(int root_pid, int signal_number) {
    if (root_pid <= 0) {
        return EINVAL;
    }
    if (kill(-root_pid, signal_number) == 0 || errno == ESRCH) {
        return 0;
    }
    return errno;
}

int noren_pty_wait(int root_pid, int *status, int no_hang) {
    const pid_t result = waitpid(root_pid, status, no_hang ? WNOHANG : 0);
    if (result == root_pid) {
        return 1;
    }
    if (result == 0) {
        return 0;
    }
    if (errno == ECHILD) {
        return 1;
    }
    return -errno;
}

int noren_pty_close(int master_fd) {
    if (master_fd < 0 || close(master_fd) == 0) {
        return 0;
    }
    return errno;
}
