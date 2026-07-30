#if defined(__linux__)
#define _GNU_SOURCE
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#endif

#include "socket_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int set_cloexec(int fd) {
    return fcntl(fd, F_SETFD, FD_CLOEXEC);
}

static int set_nonblocking(int fd) {
    const int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int noren_socket_prepare(const char *path) {
    if (path == NULL || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    char directory[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    memcpy(directory, path, strlen(path) + 1);
    char *slash = strrchr(directory, '/');
    if (slash == NULL || slash == directory) {
        errno = EINVAL;
        return -1;
    }
    *slash = '\0';
    if (mkdir(directory, 0700) < 0 && errno != EEXIST) return -1;
    struct stat info;
    if (lstat(directory, &info) < 0 ||
        !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() ||
        (info.st_mode & 0077) != 0) {
        errno = EACCES;
        return -1;
    }
    return 0;
}

int noren_socket_listen(const char *path) {
    if (path == NULL || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (set_cloexec(fd) < 0 || set_nonblocking(fd) < 0) {
        close(fd);
        return -1;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, strlen(path) + 1);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        chmod(path, 0600) < 0 ||
        listen(fd, 8) < 0) {
        const int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int noren_socket_accept(int listener) {
    const int fd = accept(listener, NULL, NULL);
    if (fd < 0) return -1;
    if (set_cloexec(fd) < 0 || set_nonblocking(fd) < 0) {
        close(fd);
        return -1;
    }
#if defined(__APPLE__) || defined(__FreeBSD__)
    uid_t peer_uid = (uid_t)-1;
    gid_t peer_gid = (gid_t)-1;
    if (getpeereid(fd, &peer_uid, &peer_gid) != 0 || peer_uid != getuid()) {
        close(fd);
        errno = EACCES;
        return -1;
    }
#elif defined(__linux__)
    struct ucred credentials;
    socklen_t credentials_length = sizeof(credentials);
    if (getsockopt(
            fd,
            SOL_SOCKET,
            SO_PEERCRED,
            &credentials,
            &credentials_length
        ) != 0 ||
        credentials.uid != getuid()) {
        close(fd);
        errno = EACCES;
        return -1;
    }
#endif
    return fd;
}

int noren_socket_connect(const char *path) {
    if (path == NULL || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (set_cloexec(fd) < 0) {
        close(fd);
        return -1;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, strlen(path) + 1);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        const int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int noren_socket_read(
    int fd,
    uint8_t *buffer,
    size_t capacity,
    size_t *read_count
) {
    const ssize_t result = read(fd, buffer, capacity);
    if (result > 0) {
        *read_count = (size_t)result;
        return NOREN_SOCKET_OK;
    }
    *read_count = 0;
    if (result == 0) return NOREN_SOCKET_EOF;
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return NOREN_SOCKET_WOULD_BLOCK;
    }
    return -errno;
}

int noren_socket_write_all(int fd, const uint8_t *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        const ssize_t result = write(fd, buffer + offset, length - offset);
        if (result > 0) {
            offset += (size_t)result;
            continue;
        }
        if (result < 0 && errno == EINTR) continue;
        return errno != 0 ? errno : EIO;
    }
    return 0;
}

int noren_socket_write_some(
    int fd,
    const uint8_t *buffer,
    size_t length,
    size_t *write_count
) {
    const ssize_t result = write(fd, buffer, length);
    if (result > 0) {
        *write_count = (size_t)result;
        return NOREN_SOCKET_OK;
    }
    *write_count = 0;
    if (result < 0 &&
        (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        return NOREN_SOCKET_WOULD_BLOCK;
    }
    return errno != 0 ? -errno : -EIO;
}

int noren_socket_poll3(
    int first,
    int second,
    int third,
    int timeout_ms,
    int watch_second_write,
    int *ready_mask
) {
    struct pollfd events[3] = {
        { .fd = first, .events = POLLIN | POLLHUP | POLLERR, .revents = 0 },
        {
            .fd = second,
            .events = POLLIN | POLLHUP | POLLERR |
                (watch_second_write ? POLLOUT : 0),
            .revents = 0,
        },
        { .fd = third, .events = POLLIN | POLLHUP | POLLERR, .revents = 0 },
    };
    const int result = poll(events, 3, timeout_ms);
    if (result < 0) return errno == EINTR ? 0 : -errno;
    *ready_mask = 0;
    if (events[0].fd >= 0 && events[0].revents != 0) *ready_mask |= 1 << 0;
    if (events[1].fd >= 0 &&
        (events[1].revents & (POLLIN | POLLHUP | POLLERR))) {
        *ready_mask |= 1 << 1;
    }
    if (events[2].fd >= 0 && events[2].revents != 0) *ready_mask |= 1 << 2;
    if (events[1].fd >= 0 && (events[1].revents & POLLOUT)) {
        *ready_mask |= 1 << 3;
    }
    return 0;
}

int noren_socket_close(int fd) {
    return fd < 0 || close(fd) == 0 ? 0 : errno;
}

int noren_socket_remove(const char *path) {
    return unlink(path) == 0 || errno == ENOENT ? 0 : errno;
}

unsigned long noren_user_id(void) {
    return (unsigned long)getuid();
}
