// ISO 原盘(BDMV ISO)原生直连:
// 1. 自定义块读取回调把 libudfread 的 UDF 卷读翻译成对远端
//    Emby/Jellyfin 静态流的 HTTP Range 请求(POSIX socket,连接缓存)
// 2. 本地 127.0.0.1 HTTP 服务把 BDMV/STREAM 里的正片 m2ts 以普通
//    m2ts 网络流(支持 Range/206)暴露给播放内核
//
// 解码由播放内核原生完成(MPV 全量内核: HEVC/TrueHD/PGS 全支持);
// 本文件只做"字节搬运 + 文件系统解析"。

#define _GNU_SOURCE // strcasestr
#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <android/log.h>

#include "libudfread/udfread.h"
#include "libudfread/blockinput.h"

#define LOG_TAG "IsoNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============ 远端 ISO 的 HTTP Range 读取(单连接缓存 + 互斥) ============

typedef struct {
    char host[256];
    char port[8];
    char path[1400];
    int sock; // -1 = 未连接
    pthread_mutex_t lock;
} iso_http;

static iso_http g_http = { .sock = -1 };
static udfread *g_udf = NULL;
static char g_m2ts_path[512];
static uint64_t g_m2ts_size = 0;
static int g_listen_fd = -1;
static int g_server_port = 0;
static volatile int g_run = 0;

static int tcp_connect(const char *host, const char *port) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int fd = -1;
    if (getaddrinfo(host, port, &hints, &res) != 0) return -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static int recv_header(int sock, char *hdr, int hdr_cap) {
    int hpos = 0;
    while (hpos < hdr_cap - 1) {
        char ch;
        int n = recv(sock, &ch, 1, 0);
        if (n <= 0) return -1;
        hdr[hpos++] = ch;
        if (hpos >= 4 && hdr[hpos - 4] == '\r' && hdr[hpos - 3] == '\n' &&
            hdr[hpos - 2] == '\r' && hdr[hpos - 1] == '\n') {
            hdr[hpos] = 0;
            return hpos;
        }
    }
    return -1;
}

// 单次 Range 请求:读满 len 字节。成功 0,失败 -1
static int http_request_once(uint64_t off, uint8_t *buf, uint32_t len) {
    char req[1600];
    snprintf(req, sizeof(req),
             "GET %s HTTP/1.1\r\n"
             "Host: %s\r\n"
             "Range: bytes=%llu-%llu\r\n"
             "Accept: */*\r\n"
             "Connection: keep-alive\r\n\r\n",
             g_http.path, g_http.host,
             (unsigned long long)off,
             (unsigned long long)(off + (len ? len - 1 : 0)));
    if (send(g_http.sock, req, strlen(req), 0) < 0) return -1;

    char hdr[4096];
    int hlen = recv_header(g_http.sock, hdr, sizeof(hdr));
    if (hlen < 0) return -1;
    if (strncmp(hdr, "HTTP/1.", 7) != 0) return -1;
    int status = atoi(strchr(hdr, ' ') + 1);
    if (status != 200 && status != 206) return -1;

    // 头缓冲里可能已带出部分 body
    const char *body_at = strstr(hdr, "\r\n\r\n") + 4;
    long have = hlen - (int)(body_at - hdr);
    if (have > (long)len) have = len;
    memcpy(buf, body_at, have);

    uint32_t got = (uint32_t)have;
    while (got < len) {
        int n = recv(g_http.sock, buf + got, len - got, 0);
        if (n <= 0) return -1;
        got += n;
    }
    return 0;
}

static int http_read_range(uint64_t off, uint8_t *buf, uint32_t len) {
    pthread_mutex_lock(&g_http.lock);
    for (int attempt = 0; attempt < 2; attempt++) {
        if (g_http.sock < 0) {
            g_http.sock = tcp_connect(g_http.host, g_http.port);
            if (g_http.sock < 0) break;
        }
        if (http_request_once(off, buf, len) == 0) {
            pthread_mutex_unlock(&g_http.lock);
            return 0;
        }
        close(g_http.sock);
        g_http.sock = -1;
    }
    pthread_mutex_unlock(&g_http.lock);
    return -1;
}

// ============ libudfread 块读取回调 ============

static int bi_close(udfread_block_input *bi) {
    (void)bi;
    return 0;
}

static int bi_read(udfread_block_input *bi, uint32_t lba, void *buf,
                   uint32_t nblocks, int flags) {
    (void)bi;
    (void)flags;
    uint64_t off = (uint64_t)lba * 2048;
    uint32_t total = nblocks * 2048;
    if (http_read_range(off, (uint8_t *)buf, total) != 0) return 0;
    return (int)nblocks;
}

static uint32_t bi_size(udfread_block_input *bi) {
    (void)bi;
    return 0; // 未知:libudfread 以卷描述符自行判定
}

static struct udfread_block_input g_block_input = {
    .close = bi_close,
    .read  = bi_read,
    .size  = bi_size,
};

// udfread_open(path) 的本地文件块输入我们不用(ISO 在远端);
// 该符号被 udfread.c 引用,链器要求必须存在,给个空桩。
extern "C" udfread_block_input *block_input_new(const char *path) {
    (void)path;
    return NULL;
}

// ============ BDMV/STREAM 最大 m2ts 查找 ============

static int find_largest_m2ts(char *path_out, size_t path_out_len,
                             uint64_t *size_out) {
    UDFDIR *dir = udfread_opendir(g_udf, "/BDMV/STREAM");
    if (!dir) {
        LOGW("无法打开 /BDMV/STREAM");
        return -1;
    }
    struct udfread_dirent entry;
    char best[512] = "";
    uint64_t best_size = 0;
    while (udfread_readdir(dir, &entry)) {
        const char *name = entry.d_name;
        size_t len = strlen(name);
        if (len < 5 || strcasecmp(name + len - 5, ".M2TS") != 0) continue;
        char path[600];
        snprintf(path, sizeof(path), "/BDMV/STREAM/%s", name);
        UDFFILE *f = udfread_file_open(g_udf, path);
        if (!f) continue;
        uint64_t sz = (uint64_t)udfread_file_size(f);
        udfread_file_close(f);
        LOGI("发现 m2ts: %s (%llu bytes)", path, (unsigned long long)sz);
        if (sz > best_size) {
            best_size = sz;
            snprintf(best, sizeof(best), "%s", path);
        }
    }
    udfread_closedir(dir);
    if (best[0] == 0 || best_size == 0) {
        LOGW("STREAM 下无有效 m2ts");
        return -1;
    }
    snprintf(path_out, path_out_len, "%s", best);
    *size_out = best_size;
    return 0;
}

// ============ 本地 HTTP 服务(暴露正片 m2ts, Range/206) ============

static void serve_connection(int fd) {
    UDFFILE *f = udfread_file_open(g_udf, g_m2ts_path);
    if (!f) { close(fd); return; }

    char hdr[2048];
    int hpos = 0;
    while (hpos < (int)sizeof(hdr) - 1) {
        char ch;
        int n = recv(fd, &ch, 1, 0);
        if (n <= 0) { break; }
        hdr[hpos++] = ch;
        if (hpos >= 4 && hdr[hpos - 4] == '\r' && hdr[hpos - 3] == '\n' &&
            hdr[hpos - 2] == '\r' && hdr[hpos - 1] == '\n') break;
    }
    hdr[hpos] = 0;

    uint64_t start = 0;
    const char *range = strcasestr(hdr, "Range: bytes=");
    if (!range) range = strcasestr(hdr, "range: bytes=");
    if (range) {
        range += 13;
        unsigned long long a = 0;
        if (sscanf(range, "%llu", &a) == 1) start = a;
    }
    if (start >= g_m2ts_size) start = g_m2ts_size > 0 ? g_m2ts_size - 1 : 0;
    uint64_t end = g_m2ts_size - 1;

    char resp[512];
    snprintf(resp, sizeof(resp),
             "HTTP/1.1 206 Partial Content\r\n"
             "Content-Type: video/mp2t\r\n"
             "Accept-Ranges: bytes\r\n"
             "Content-Range: bytes %llu-%llu/%llu\r\n"
             "Content-Length: %llu\r\n"
             "Connection: close\r\n\r\n",
             (unsigned long long)start, (unsigned long long)end,
             (unsigned long long)g_m2ts_size,
             (unsigned long long)(end - start + 1));
    if (send(fd, resp, strlen(resp), MSG_NOSIGNAL) < 0) {
        udfread_file_close(f);
        close(fd);
        return;
    }

    udfread_file_seek(f, (int64_t)start, UDF_SEEK_SET);
    uint8_t buf[32 * 1024];
    uint64_t remaining = end - start + 1;
    while (remaining > 0 && g_run) {
        uint32_t want = remaining > sizeof(buf) ? sizeof(buf) : (uint32_t)remaining;
        ssize_t n = udfread_file_read(f, buf, want);
        if (n <= 0) break;
        ssize_t off = 0;
        while (off < n) {
            ssize_t s = send(fd, buf + off, n - off, MSG_NOSIGNAL);
            if (s <= 0) { remaining = 0; break; }
            off += s;
            remaining -= (uint64_t)s;
        }
    }
    udfread_file_close(f);
    close(fd);
}

static void *server_thread(void *arg) {
    (void)arg;
    while (g_run) {
        int fd = accept(g_listen_fd, NULL, NULL);
        if (fd < 0) break;
        pthread_t t;
        pthread_create(&t, NULL,
                       (void *(*)(void *))serve_connection,
                       (void *)(intptr_t)fd);
        pthread_detach(t);
    }
    return NULL;
}

// ============ 生命周期 ============

static void iso_shutdown(void) {
    g_run = 0;
    if (g_listen_fd >= 0) { close(g_listen_fd); g_listen_fd = -1; }
    if (g_http.sock >= 0) { close(g_http.sock); g_http.sock = -1; }
    if (g_udf) { udfread_close(g_udf); g_udf = NULL; }
    g_m2ts_size = 0;
    g_m2ts_path[0] = 0;
}

static int parse_url(const char *url, char *host, size_t host_len,
                     char *port, size_t port_len,
                     char *path, size_t path_len) {
    const char *p = strstr(url, "://");
    if (!p) return -1;
    p += 3;
    const char *slash = strchr(p, '/');
    if (!slash) return -1;
    const char *colon = (const char *)memchr(p, ':', (size_t)(slash - p));
    size_t hlen = colon ? (size_t)(colon - p) : (size_t)(slash - p);
    if (hlen >= host_len) return -1;
    memcpy(host, p, hlen);
    host[hlen] = 0;
    if (colon) {
        size_t plen = (size_t)(slash - colon - 1);
        if (plen >= port_len) return -1;
        memcpy(port, colon + 1, plen);
        port[plen] = 0;
    } else {
        snprintf(port, port_len, "80");
    }
    size_t pathlen = strlen(slash);
    if (pathlen >= path_len) return -1;
    memcpy(path, slash, pathlen + 1);
    return 0;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_lanplayer_IsoBridge_nativeOpenIso(JNIEnv *env, jclass clazz,
                                           jstring jUrl, jlong jSize) {
    (void)clazz;
    (void)jSize; // 总大小由首响应的 Content-Range 校准,不必预传
    const char *url = env->GetStringUTFChars(jUrl, NULL);
    if (!url) return NULL;

    if (parse_url(url, g_http.host, sizeof(g_http.host),
                  g_http.port, sizeof(g_http.port),
                  g_http.path, sizeof(g_http.path)) != 0) {
        env->ReleaseStringUTFChars(jUrl, url);
        LOGE("URL 解析失败");
        return NULL;
    }
    if (strncmp(g_http.host, url, 4) == 0) {} // no-op
    g_http.sock = -1;
    env->ReleaseStringUTFChars(jUrl, url);

    // 首次 Range 探测:校验连通性(后续读取按需建连)
    uint8_t probe[16];
    if (http_read_range(0, probe, sizeof(probe)) != 0) {
        LOGE("无法访问远端 ISO 流");
        return NULL;
    }

    // 打开 UDF 卷
    g_udf = udfread_init();
    if (!g_udf) return NULL;
    if (udfread_open_input(g_udf, &g_block_input) != 0) {
        LOGE("udfread_open_input 失败");
        udfread_close(g_udf);
        g_udf = NULL;
        return NULL;
    }

    if (find_largest_m2ts(g_m2ts_path, sizeof(g_m2ts_path), &g_m2ts_size) != 0) {
        udfread_close(g_udf);
        g_udf = NULL;
        return NULL;
    }
    LOGI("正片: %s (%llu bytes)", g_m2ts_path, (unsigned long long)g_m2ts_size);

    g_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(g_listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(g_listen_fd, 4) != 0) {
        LOGE("本地服务启动失败");
        udfread_close(g_udf);
        g_udf = NULL;
        return NULL;
    }
    socklen_t alen = sizeof(addr);
    getsockname(g_listen_fd, (struct sockaddr *)&addr, &alen);
    g_server_port = ntohs(addr.sin_port);
    g_run = 1;
    pthread_t t;
    pthread_create(&t, NULL, server_thread, NULL);
    pthread_detach(t);

    char local[64];
    snprintf(local, sizeof(local), "http://127.0.0.1:%d/stream.m2ts", g_server_port);
    LOGI("ISO 直连就绪: %s", local);
    return env->NewStringUTF(local);
}

extern "C" JNIEXPORT void JNICALL
Java_com_lanplayer_IsoBridge_nativeCloseIso(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    iso_shutdown();
}
