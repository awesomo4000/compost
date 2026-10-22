/* POSIX PTY/tty adapter. Window management and rendering remain in Zig. */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

extern int compositor_resize(unsigned short, unsigned short, unsigned short, unsigned short, int);
extern int compositor_output(int, const unsigned char *, size_t);
extern int compositor_input(const unsigned char *, size_t);
extern int compositor_idle(void);
extern int compositor_exit(int);
extern int compositor_draw(void);
extern void compositor_finish(void);
static int masters[2] = {-1, -1};
static struct winsize sizes[2];
static int count = 2;
static volatile sig_atomic_t resized = 0, stopped = 0;
static uint64_t milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void on_signal(int sig) {
    if (sig == SIGWINCH) resized = 1;
    else stopped = sig;
}
static int write_all(int fd, const unsigned char *bytes, size_t len) {
    while (len) {
        ssize_t n = write(fd, bytes, len);
        if (n < 0 && errno == EINTR && !stopped) continue;
        if (n <= 0) return -1;
        bytes += n;
        len -= (size_t)n;
    }
    return 0;
}
int host_write(int slot, const unsigned char *bytes, size_t len) {
    if (slot < 0 || slot >= count || masters[slot] < 0) return -1;
    return write_all(masters[slot], bytes, len);
}
int host_set_size(int slot, unsigned short cols, unsigned short rows, unsigned short cw, unsigned short ch) {
    sizes[slot] = (struct winsize){ .ws_col = cols, .ws_row = rows, .ws_xpixel = cols * cw, .ws_ypixel = rows * ch };
    return masters[slot] < 0 ? 0 : ioctl(masters[slot], TIOCSWINSZ, &sizes[slot]);
}
int host_display(const unsigned char *bytes, size_t len) { return write_all(STDOUT_FILENO, bytes, len); }

static int geometry(struct winsize *ws) {
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, ws) < 0) return -1;
    if (!ws->ws_col || !ws->ws_row) return 0;
    if (compositor_resize(ws->ws_col, ws->ws_row,
        ws->ws_xpixel / ws->ws_col, ws->ws_ypixel / ws->ws_row, count)) return -1;
    return 0;
}

int host_run(void) {
    struct termios original, raw;
    struct winsize ws = {0};
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) ||
        tcgetattr(STDIN_FILENO, &original) < 0) {
        fprintf(stderr, "tmuxpp-shell needs a terminal on stdin and stdout\n");
        return 1;
    }
    count = getenv("TMUXPP_SINGLE") ? 1 : 2;
    if (geometry(&ws) < 0 || !ws.ws_col || !ws.ws_row) return 1;
    const char *shell = getenv("SHELL");
    if (!shell || shell[0] != '/') shell = "/bin/sh";
    pid_t children[2] = {-1, -1};
    int statuses[2] = {0, 0};
    for (int slot = 0; slot < count; slot++) {
        const char *command = getenv(slot == 0 && count == 2 ? "TMUXPP_SIDEBAR_COMMAND" : "TMUXPP_COMMAND");
        pid_t child = forkpty(&masters[slot], NULL, &original, &sizes[slot]);
        if (child < 0) {
            perror("forkpty");
            for (int previous = 0; previous < slot; previous++) {
                close(masters[previous]); kill(-children[previous], SIGKILL);
                waitpid(children[previous], NULL, 0);
            }
            return 1;
        }
        if (child == 0) {
            for (int other = 0; other < slot; other++) close(masters[other]);
            setenv("TERM", "xterm-256color", 1);
            setenv("COLORTERM", "truecolor", 1);
            if (command) execl(shell, shell, "-c", command, (char *)NULL);
            else execl(shell, shell, "-i", (char *)NULL);
            perror("exec shell");
            _exit(127);
        }
        children[slot] = child;
    }
    int result = 0, status = 0;
    struct sigaction action = {0}, saved[5];
    const int signals[] = { SIGWINCH, SIGTERM, SIGHUP, SIGINT, SIGPIPE };
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    for (int i = 0; i < 5; i++) sigaction(signals[i], &action, &saved[i]);
    raw = original;
    cfmakeraw(&raw);
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) < 0) { result = 1; goto cleanup; }
    const char *enter = "\033[?1049h\033[?7l\033[?25l\033[2J";
    if (host_display((const unsigned char *)enter, strlen(enter))) { result = 1; goto cleanup; }
    int dirty = 1, alive = count;
    uint64_t input_time = 0;
    int input_timeout = 0;
    while (!stopped && alive) {
        if (input_timeout && milliseconds() - input_time >= 50) {
            if (compositor_idle()) { result = 1; break; }
            input_timeout = 0;
        }
        if (resized) {
            resized = 0;
            if (geometry(&ws)) { result = 1; break; }
            dirty = 1;
        }
        if (dirty) {
            if (compositor_draw()) { result = 1; break; }
            dirty = 0;
        }
        struct pollfd fds[] = { { STDIN_FILENO, POLLIN, 0 }, { masters[0], POLLIN, 0 }, { masters[1], POLLIN, 0 } };
        int ready = poll(fds, 3, 50);
        if (ready < 0) { if (errno == EINTR) continue; result = 1; break; }
        unsigned char bytes[16384];
        for (int slot = 0; slot < count; slot++) {
            if (masters[slot] < 0 || !(fds[slot + 1].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t n = read(masters[slot], bytes, sizeof(bytes));
            if (n > 0) {
                if (compositor_output(slot, bytes, (size_t)n)) { result = 1; stopped = SIGTERM; break; }
                dirty = 1;
            } else if (n == 0 || (n < 0 && errno == EIO)) {
                close(masters[slot]); masters[slot] = -1; alive--;
                if (compositor_exit(slot)) { result = 1; stopped = SIGTERM; break; }
                dirty = 1;
            } else if (errno != EINTR) { result = 1; stopped = SIGTERM; break; }
        }
        if (fds[0].revents & POLLIN) {
            ssize_t n = read(STDIN_FILENO, bytes, sizeof(bytes));
            if (n <= 0 || compositor_input(bytes, (size_t)n)) break;
            input_time = milliseconds();
            input_timeout = 1;
            dirty = 1;
        }
        if (fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) break;
    }
cleanup:
    /* Only this host's process group. Never touch another shell or tmux server. */
    for (int slot = 0; slot < count; slot++) {
        if (masters[slot] >= 0) close(masters[slot]);
        masters[slot] = -1;
        if (waitpid(children[slot], &statuses[slot], WNOHANG) == 0) {
            kill(-children[slot], SIGHUP);
            int reaped = 0;
            for (int i = 0; i < 20; i++) {
                if (waitpid(children[slot], &statuses[slot], WNOHANG) == children[slot]) { reaped = 1; break; }
                usleep(10000);
            }
            if (!reaped) {
                kill(-children[slot], SIGKILL);
                while (waitpid(children[slot], &statuses[slot], 0) < 0 && errno == EINTR) {}
            }
        }
    }
    status = statuses[count - 1];
    compositor_finish();
    const char *leave = "\033[?2026l\033[0m\033[?1l\033[?2004l\033[?1000l\033[?1002l\033[?1003l\033[?1004l\033[?1006l\033[?7h\033[?25h\033[?1049l";
    host_display((const unsigned char *)leave, strlen(leave));
    tcsetattr(STDIN_FILENO, TCSANOW, &original);
    for (int i = 0; i < 5; i++) sigaction(signals[i], &saved[i], NULL);
    if (stopped) return 128 + stopped;
    if (result) return result;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
