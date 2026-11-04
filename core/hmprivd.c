/*
 * hmprivd — HMArkPriv socket daemon
 *
 * 替代文件总线：App 通过 TCP 连接 127.0.0.1:19999 直接下发命令，
 * 本程序执行后把输出写回 socket。
 *
 * 为什么需要它：
 *   真机实测发现 App 与 shell 之间没有可共享的可写目录 ——
 *   App 不能 create（目录 other 无 w，媒体权限对普通文件无效），
 *   shell 不能 create（SELinux 禁 hmdfs create），
 *   文件总线方案在真机上不可行。
 *
 * 协议（极简，便于调试）：
 *   请求：<command>\n            （一行，\n 结尾）
 *   响应：<RC:exit>\n<output>     （第一行是退出码，之后是命令输出）
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define LISTEN_PORT 19999
#define BUF_SIZE 65536

/* 逐个连接处理：读命令 → 执行 → 回写 */
static void handle_client(int cli) {
    char *cmd = (char *)malloc(BUF_SIZE);
    if (!cmd) { close(cli); return; }

    ssize_t n = read(cli, cmd, BUF_SIZE - 1);
    if (n <= 0) { free(cmd); close(cli); return; }
    cmd[n] = '\0';

    /* 去掉尾部的 \r\n */
    while (n > 0 && (cmd[n - 1] == '\n' || cmd[n - 1] == '\r')) {
        cmd[--n] = '\0';
    }
    if (n == 0) { free(cmd); close(cli); return; }

    /* 用 popen 执行，2>&1 合并 stderr */
    char *wrapped = (char *)malloc(n + 32);
    if (!wrapped) { free(cmd); close(cli); return; }
    snprintf(wrapped, n + 32, "%s 2>&1", cmd);

    FILE *fp = popen(wrapped, "r");
    char *out = (char *)malloc(BUF_SIZE);
    if (!out) { if (fp) pclose(fp); free(wrapped); free(cmd); close(cli); return; }
    out[0] = '\0';

    size_t total = 0;
    if (fp) {
        size_t r;
        while ((r = fread(out + total, 1, BUF_SIZE - 1 - total, fp)) > 0) {
            total += r;
            if (total >= BUF_SIZE - 1) break;   /* 截断保护 */
        }
        int st = pclose(fp);
        /* WEXITSTATUS：pclose 返回值的高 8 位是退出码 */
        int code = (st >= 0) ? (st >> 8) : -1;

        char head[64];
        int hl = snprintf(head, sizeof(head), "RC:%d\n", code);
        write(cli, head, (size_t)hl);
    } else {
        const char *err = "RC:-1\nexec failed\n";
        write(cli, err, strlen(err));
    }

    /* 回写输出（分块，避免单次 write 过多） */
    size_t sent = 0;
    while (sent < total) {
        ssize_t w = write(cli, out + sent, total - sent);
        if (w <= 0) break;
        sent += (size_t)w;
    }

    free(out);
    free(wrapped);
    free(cmd);
    close(cli);
}

int main(int argc, char **argv) {
    /* 忽略 SIGPIPE，避免客户端断开导致进程退出 */
    signal(SIGPIPE, SIG_IGN);

    int port = LISTEN_PORT;
    if (argc > 1) {
        port = atoi(argv[1]);
        if (port <= 0 || port > 65535) port = LISTEN_PORT;
    }

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        fprintf(stderr, "socket() failed: %s\n", strerror(errno));
        return 1;
    }

    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");   /* 只监听本地 */
    addr.sin_port = htons((uint16_t)port);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "bind(%d) failed: %s\n", port, strerror(errno));
        close(srv);
        return 1;
    }
    if (listen(srv, 8) < 0) {
        fprintf(stderr, "listen failed: %s\n", strerror(errno));
        close(srv);
        return 1;
    }

    /* 就绪标志：写 pid 文件（文件已存在则覆盖，不 create 新文件由外部保证） */
    fprintf(stdout, "hmprivd listening on 127.0.0.1:%d (uid=%d)\n", port, getuid());
    fflush(stdout);

    for (;;) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) {
            if (errno == EINTR) continue;
            break;
        }
        handle_client(cli);
    }

    close(srv);
    return 0;
}
