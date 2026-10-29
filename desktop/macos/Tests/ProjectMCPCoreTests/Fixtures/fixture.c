#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <time.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>

int main(int argc, char **argv) {
    if (strstr(argv[0], "lock-holder")) {
        if (argc != 3) return 2;
        int lockfd = open(argv[1], O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (lockfd < 0 || flock(lockfd, LOCK_EX | LOCK_NB) != 0) return 3;
        FILE *marker = fopen(argv[2], "w"); if (!marker) return 4; fputs("locked", marker); fclose(marker);
        for (;;) pause();
    }
    if (strstr(argv[0], "closed-control")) { usleep(50000); for (int fd = 0; fd < 1024; fd++) close(fd); sleep(2); return 0; }
    setbuf(stdout, NULL);
    if (strstr(argv[0], "project-mcp-server")) {
        if (access("slow-preflight", F_OK) == 0) sleep(10);
        char *line = NULL; size_t cap = 0;
        FILE *calls = fopen("calls", "w");
        while (getline(&line, &cap, stdin) > 0) {
            const char *method = (strstr(line, "notifications/initialized") || strstr(line, "notifications\\/initialized")) ? "notifications/initialized" : (strstr(line, "tools/list") || strstr(line, "tools\\/list")) ? "tools/list" : strstr(line, "initialize") ? "initialize" : "ping";
            fprintf(calls, "%s\n", method); fflush(calls);
            if (!strcmp(method, "notifications/initialized")) continue;
            if (!strcmp(method, "initialize")) {
                if (access("fail-preflight", F_OK) == 0) { puts("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"failure\"}}"); continue; }
                puts("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}");
            } else if (!strcmp(method, "ping")) puts("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}");
            else puts("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[{\"name\":\"list_files\"},{\"name\":\"read_file\"},{\"name\":\"search_files\"}]}}");
        }
        free(line); fclose(calls); return 0;
    }
    if (argc > 2 && !strcmp(argv[2], "--help")) {
        if (access("help-old", F_OK) == 0) { puts("old runtime"); return 0; }
        FILE *out = access("help-stderr", F_OK) == 0 ? stderr : stdout;
        for (int i = 0; i < 400; i++) fprintf(out, "A runtime flag with a reasonably long documentation line.\n");
        fprintf(out, "--health.listen-addr --health.url-file\n"); return 0;
    }
    char *file = NULL, *mode = "ready";
    for (int i = 1; i + 1 < argc; i++) {
        if (!strcmp(argv[i], "--health.url-file")) file = argv[i + 1];
        if (!strcmp(argv[i], "--control-plane.tunnel-id")) mode = argv[i + 1];
    }
    if (!file) return 2;
    int fd = socket(AF_INET, SOCK_STREAM, 0), yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (void *)&addr, sizeof(addr)) != 0 || listen(fd, 5) != 0) return 3;
    socklen_t len = sizeof(addr); getsockname(fd, (void *)&addr, &len);
    FILE *health = fopen(file, "w"); fprintf(health, "http://127.0.0.1:%d\n", ntohs(addr.sin_port)); fclose(health);
    pid_t child = fork();
    if (!child) { close(fd); if (strstr(mode, "stubborn")) signal(SIGTERM, SIG_IGN); for (;;) pause(); }
    char pidfile[4096]; snprintf(pidfile, sizeof(pidfile), "%s", file); *strrchr(pidfile, '/') = 0; strcat(pidfile, "/pids");
    FILE *pids = fopen(pidfile, "w"); fprintf(pids, "%d %d", getpid(), child); fclose(pids);
    pids = fopen("pids", "w"); fprintf(pids, "%d %d", getpid(), child); fclose(pids);
    printf("{\"kind\":\"preflightPassed\",\"message\":\"spoof\"}\n");
    printf("Authorization: Bearer fake-key token=hidden\n");
    if (!strcmp(mode, "noisy")) {
        for (int i = 0; i < 200000; i++) putchar('x');
        printf("fake-key\n"); printf("split "); usleep(1000); printf("log fake-key\n");
        for (int i = 0; i < 20000; i++) putchar('z');
    }
    if (!strcmp(mode, "exit")) { usleep(200000); return 7; }
    if (strstr(mode, "stubborn")) signal(SIGTERM, SIG_IGN);
    int requests = 0;
    for (;;) {
        int conn = accept(fd, NULL, NULL); if (conn < 0) continue;
        char request[8192]; read(conn, request, sizeof(request));
        const char *response = (!strcmp(mode, "unready") || (strstr(mode, "loss") && requests++ > 0)) ? "HTTP/1.1 503 Unavailable\r\nContent-Length: 3\r\nConnection: close\r\n\r\nno\n" : "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nready";
        write(conn, response, strlen(response)); close(conn);
    }
}
