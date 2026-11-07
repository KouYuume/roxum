#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* A worker crash must never return to Roc; the connection owner controls recovery. */

static const char RESPONSE_200[] =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 3\r\n"
    "Connection: close\r\n"
    "\r\n"
    "ok\n";

static const char RESPONSE_500[] =
    "HTTP/1.1 500 Internal Server Error\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 22\r\n"
    "Connection: close\r\n"
    "\r\n"
    "worker crashed: trace\n";

static volatile sig_atomic_t child_pid = -1;
static volatile sig_atomic_t terminating = 0;
static volatile sig_atomic_t supervisor_listener = -1;

static void die(const char *what) {
    perror(what);
    exit(1);
}

static void write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t written = write(fd, buf, len);
        if (written < 0) {
            if (errno == EINTR) continue;
            return;
        }
        buf += (size_t)written;
        len -= (size_t)written;
    }
}

static int make_listener(unsigned short port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die("socket");

    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0) {
        die("setsockopt(SO_REUSEADDR)");
    }
#ifdef SO_REUSEPORT
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) < 0) {
        die("setsockopt(SO_REUSEPORT)");
    }
#endif

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr = { .s_addr = htonl(INADDR_LOOPBACK) },
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) die("bind");
    if (listen(fd, 16) < 0) die("listen");
    return fd;
}

static bool request_crashes(int fd) {
    char request[2048];
    ssize_t len;
    do {
        len = read(fd, request, sizeof(request) - 1);
    } while (len < 0 && errno == EINTR);
    if (len <= 0) return false;
    request[len] = '\0';
    return strstr(request, "GET /crash ") != NULL;
}

static void crash_with_reset(int client) {

    struct linger rst = { .l_onoff = 1, .l_linger = 0 };
    (void)setsockopt(client, SOL_SOCKET, SO_LINGER, &rst, sizeof(rst));
    dprintf(STDERR_FILENO, "WORKER_CRASH pid=%d\n", getpid());
    _exit(70); /* A worker crash must never return to Roc; the connection owner controls recovery. */
}

static void reset_worker_signals(void) {
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
}

static void direct_worker(unsigned short port) {
    reset_worker_signals();
    int listener = make_listener(port);
    dprintf(STDERR_FILENO, "READY mode=direct port=%u worker=%d\n", port, getpid());

    for (;;) {
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            _exit(2);
        }
        if (request_crashes(client)) crash_with_reset(client);
        write_all(client, RESPONSE_200, sizeof(RESPONSE_200) - 1);
        close(client);
    }
}

static pid_t spawn_direct_worker(unsigned short port) {
    pid_t pid = fork();
    if (pid < 0) die("fork");
    if (pid == 0) direct_worker(port);
    return pid;
}

static void forward_signal(int signo) {
    terminating = 1;
    pid_t pid = (pid_t)child_pid;
    if (pid > 0) kill(pid, signo);
    int listener = (int)supervisor_listener;
    if (listener >= 0) close(listener);
}

static void run_direct(unsigned short port) {
    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);

    for (;;) {
        child_pid = spawn_direct_worker(port);
        int status = 0;
        while (waitpid((pid_t)child_pid, &status, 0) < 0) {
            if (errno == EINTR) continue;
            die("waitpid");
        }
        dprintf(STDERR_FILENO, "RESTART mode=direct status=%d\n", status);
        child_pid = -1;
        if (terminating) return;
    }
}

static int send_fd(int control, int fd) {
    char byte = 'F';
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    char ancillary[CMSG_SPACE(sizeof(int))];
    memset(ancillary, 0, sizeof(ancillary));

    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = ancillary,
        .msg_controllen = sizeof(ancillary),
    };
    struct cmsghdr *header = CMSG_FIRSTHDR(&msg);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &fd, sizeof(fd));
    return (int)sendmsg(control, &msg, 0);
}

static int receive_fd(int control) {
    char byte = 0;
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    char ancillary[CMSG_SPACE(sizeof(int))];
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = ancillary,
        .msg_controllen = sizeof(ancillary),
    };

    ssize_t received;
    do {
        received = recvmsg(control, &msg, 0);
    } while (received < 0 && errno == EINTR);
    if (received <= 0) return -1;

    struct cmsghdr *header = CMSG_FIRSTHDR(&msg);
    if (header == NULL || header->cmsg_level != SOL_SOCKET ||
        header->cmsg_type != SCM_RIGHTS) {
        return -1;
    }
    int fd = -1;
    memcpy(&fd, CMSG_DATA(header), sizeof(fd));
    return fd;
}

static void handoff_worker(int control) {
    reset_worker_signals();
    for (;;) {
        int client = receive_fd(control);
        if (client < 0) _exit(0);
        if (request_crashes(client)) crash_with_reset(client);

        write_all(client, RESPONSE_200, sizeof(RESPONSE_200) - 1);
        close(client);
        write_all(control, "D", 1);
    }
}

static pid_t spawn_handoff_worker(int *control) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) < 0) die("socketpair");

    pid_t pid = fork();
    if (pid < 0) die("fork");
    if (pid == 0) {
        close(pair[0]);
        handoff_worker(pair[1]);
    }
    close(pair[1]);
    *control = pair[0];
    return pid;
}

static void run_supervisor(unsigned short port) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);

    int listener = make_listener(port);
    supervisor_listener = listener;
    int control = -1;
    child_pid = spawn_handoff_worker(&control);
    dprintf(STDERR_FILENO, "READY mode=supervisor port=%u worker=%d\n",
            port, (int)child_pid);

    for (;;) {
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (terminating) break;
            if (errno == EINTR) continue;
            die("accept");
        }

        if (send_fd(control, client) < 0) {
            close(client);
            die("sendmsg(SCM_RIGHTS)");
        }

        char done = 0;
        ssize_t status;
        do {
            status = read(control, &done, 1);
        } while (status < 0 && errno == EINTR);

        if (terminating) {
            close(client);
            break;
        }

        if (status == 1 && done == 'D') {
            close(client);
            continue;
        }


        write_all(client, RESPONSE_500, sizeof(RESPONSE_500) - 1);
        close(client);

        int worker_status = 0;
        (void)waitpid((pid_t)child_pid, &worker_status, 0);
        close(control);
        dprintf(STDERR_FILENO, "RESTART mode=supervisor status=%d\n", worker_status);
        child_pid = spawn_handoff_worker(&control);
    }

    close(control);
    if (child_pid > 0) (void)waitpid((pid_t)child_pid, NULL, 0);
    child_pid = -1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s direct|supervisor PORT\n", argv[0]);
        return 2;
    }

    char *end = NULL;
    long parsed = strtol(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || parsed < 1 || parsed > 65535) {
        fprintf(stderr, "invalid port: %s\n", argv[2]);
        return 2;
    }

    if (strcmp(argv[1], "direct") == 0) {
        run_direct((unsigned short)parsed);
    } else if (strcmp(argv[1], "supervisor") == 0) {
        run_supervisor((unsigned short)parsed);
    } else {
        fprintf(stderr, "invalid mode: %s\n", argv[1]);
        return 2;
    }
    return 0;
}
