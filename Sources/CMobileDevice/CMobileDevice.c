#include "include/CMobileDevice.h"

#include <dlfcn.h>
#include <pthread.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stddef.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>

static const char *kMobileDevicePath =
    "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice";

static void *gHandle = NULL;
static char gError[512] = {0};

// --- Function pointers ---
static int32_t (*p_AMDeviceNotificationSubscribe)(AMDeviceNotificationCallback, int, int, void *,
                                                  AMDeviceNotificationRef *);
static int32_t (*p_AMDeviceNotificationUnsubscribe)(AMDeviceNotificationRef);
static AMDeviceRef (*p_AMDeviceRetain)(AMDeviceRef);
static void (*p_AMDeviceRelease)(AMDeviceRef);
static int32_t (*p_AMDeviceConnect)(AMDeviceRef);
static int32_t (*p_AMDeviceDisconnect)(AMDeviceRef);
static int32_t (*p_AMDeviceIsPaired)(AMDeviceRef);
static int32_t (*p_AMDeviceValidatePairing)(AMDeviceRef);
static int32_t (*p_AMDeviceStartSession)(AMDeviceRef);
static int32_t (*p_AMDeviceStopSession)(AMDeviceRef);
static CFStringRef (*p_AMDeviceCopyDeviceIdentifier)(AMDeviceRef);
static CFTypeRef (*p_AMDeviceCopyValue)(AMDeviceRef, CFStringRef, CFStringRef);
static int32_t (*p_AMDeviceSecureStartService)(AMDeviceRef, CFStringRef, CFDictionaryRef,
                                               AMDServiceConnectionRef *);
static int (*p_AMDServiceConnectionGetSocket)(AMDServiceConnectionRef);
static void *(*p_AMDServiceConnectionGetSecureIOContext)(AMDServiceConnectionRef);
static int32_t (*p_AMDServiceConnectionInvalidate)(AMDServiceConnectionRef);
static int (*p_AMDServiceConnectionSend)(AMDServiceConnectionRef, const void *, size_t);
static int (*p_AMDServiceConnectionReceive)(AMDServiceConnectionRef, void *, size_t);

/// One dlsym. On failure fills gError and returns 0.
static int resolve(void **slot, const char *name) {
    void *symbol = dlsym(gHandle, name);
    if (symbol == NULL) {
        snprintf(gError, sizeof(gError), "symbol not found: %s", name);
        return 0;
    }
    *slot = symbol;
    return 1;
}

int cmd_load_mobile_device(void) {
    if (gHandle != NULL) {
        return 0;
    }

    gHandle = dlopen(kMobileDevicePath, RTLD_LAZY | RTLD_LOCAL);
    if (gHandle == NULL) {
        snprintf(gError, sizeof(gError), "dlopen failed: %s", dlerror());
        return -1;
    }

#define RESOLVE(sym)                                            \
    if (!resolve((void **)&p_##sym, #sym)) {                    \
        dlclose(gHandle);                                       \
        gHandle = NULL;                                         \
        return -1;                                              \
    }

    RESOLVE(AMDeviceNotificationSubscribe)
    RESOLVE(AMDeviceNotificationUnsubscribe)
    RESOLVE(AMDeviceRetain)
    RESOLVE(AMDeviceRelease)
    RESOLVE(AMDeviceConnect)
    RESOLVE(AMDeviceDisconnect)
    RESOLVE(AMDeviceIsPaired)
    RESOLVE(AMDeviceValidatePairing)
    RESOLVE(AMDeviceStartSession)
    RESOLVE(AMDeviceStopSession)
    RESOLVE(AMDeviceCopyDeviceIdentifier)
    RESOLVE(AMDeviceCopyValue)
    RESOLVE(AMDeviceSecureStartService)
    RESOLVE(AMDServiceConnectionGetSocket)
    RESOLVE(AMDServiceConnectionGetSecureIOContext)
    RESOLVE(AMDServiceConnectionInvalidate)
    RESOLVE(AMDServiceConnectionSend)
    RESOLVE(AMDServiceConnectionReceive)

#undef RESOLVE

    return 0;
}

const char *cmd_load_error(void) { return gError; }

int32_t cmd_notification_subscribe(AMDeviceNotificationCallback callback, void *context,
                                   AMDeviceNotificationRef *outNotification) {
    return p_AMDeviceNotificationSubscribe(callback, 0, 0, context, outNotification);
}

int32_t cmd_notification_unsubscribe(AMDeviceNotificationRef notification) {
    return p_AMDeviceNotificationUnsubscribe(notification);
}

AMDeviceRef cmd_device_retain(AMDeviceRef device) { return p_AMDeviceRetain(device); }
void cmd_device_release(AMDeviceRef device) { p_AMDeviceRelease(device); }
int32_t cmd_device_connect(AMDeviceRef device) { return p_AMDeviceConnect(device); }
int32_t cmd_device_disconnect(AMDeviceRef device) { return p_AMDeviceDisconnect(device); }
int32_t cmd_device_is_paired(AMDeviceRef device) { return p_AMDeviceIsPaired(device); }
int32_t cmd_device_validate_pairing(AMDeviceRef device) { return p_AMDeviceValidatePairing(device); }
int32_t cmd_device_start_session(AMDeviceRef device) { return p_AMDeviceStartSession(device); }
int32_t cmd_device_stop_session(AMDeviceRef device) { return p_AMDeviceStopSession(device); }

CFStringRef cmd_device_copy_identifier(AMDeviceRef device) {
    return p_AMDeviceCopyDeviceIdentifier(device);
}

CFTypeRef cmd_device_copy_value(AMDeviceRef device, CFStringRef domain, CFStringRef key) {
    return p_AMDeviceCopyValue(device, domain, key);
}

int32_t cmd_device_secure_start_service(AMDeviceRef device, CFStringRef serviceName,
                                        CFDictionaryRef options,
                                        AMDServiceConnectionRef *outConnection) {
    return p_AMDeviceSecureStartService(device, serviceName, options, outConnection);
}

int cmd_service_connection_get_socket(AMDServiceConnectionRef connection) {
    return p_AMDServiceConnectionGetSocket(connection);
}

void *cmd_service_connection_get_secure_io_context(AMDServiceConnectionRef connection) {
    return p_AMDServiceConnectionGetSecureIOContext(connection);
}

int32_t cmd_service_connection_invalidate(AMDServiceConnectionRef connection) {
    return p_AMDServiceConnectionInvalidate(connection);
}


// --- Service connection socket ---
//
// The connection from `AMDeviceSecureStartService` carries an SSL* at offset 0x18, so
// `AMDServiceConnectionSend/Receive` go through SSL_write/SSL_read. But the actual wire of
// the axAuditDaemon service is **plaintext** (peeking the socket with MSG_PEEK shows the
// DTX fragment magic 0x1f3d5b79 in the clear). That SSL context is a leftover inherited from
// the lockdown session, and reading through it breaks with SSL_ERROR_SSL (errno 43).
//
// So there's no TLS pump; the raw socket goes straight to DTXSocketTransport.
// It's handed out as a dup so ownership doesn't get split.

int cmd_service_connection_duplicate_socket(AMDServiceConnectionRef connection) {
    int raw = p_AMDServiceConnectionGetSocket(connection);
    if (raw < 0) {
        return -1;
    }
    return dup(raw);
}


// --- Debug tee ---
//
// Relays plaintext between the raw socket and a socketpair while printing byte counts.
// Used to check whether messages the device pushes actually reach the process.

typedef struct {
    int raw;
    int plain;
} TeeContext;

static void *tee_main(void *opaque) {
    TeeContext *ctx = (TeeContext *)opaque;
    char buffer[16384];

    for (;;) {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(ctx->raw, &readable);
        FD_SET(ctx->plain, &readable);
        int highest = ctx->raw > ctx->plain ? ctx->raw : ctx->plain;

        if (select(highest + 1, &readable, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            break;
        }

        int from = FD_ISSET(ctx->raw, &readable) ? ctx->raw : ctx->plain;
        int to = from == ctx->raw ? ctx->plain : ctx->raw;
        const char *label = from == ctx->raw ? "device->us" : "us->device";

        ssize_t n = read(from, buffer, sizeof(buffer));
        fprintf(stderr, "[tee] %s %zd bytes\n", label, n);
        if (n <= 0) break;

        ssize_t written = 0;
        while (written < n) {
            ssize_t wrote = write(to, buffer + written, (size_t)(n - written));
            if (wrote <= 0) goto done;
            written += wrote;
        }
    }
done:
    shutdown(ctx->plain, SHUT_RDWR);
    close(ctx->plain);
    free(ctx);
    return NULL;
}

int cmd_service_connection_tee_socket(AMDServiceConnectionRef connection) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        return -1;
    }

    TeeContext *ctx = malloc(sizeof(TeeContext));
    if (ctx == NULL) {
        close(pair[0]);
        close(pair[1]);
        return -1;
    }
    ctx->raw = p_AMDServiceConnectionGetSocket(connection);
    ctx->plain = pair[1];

    pthread_t thread;
    if (pthread_create(&thread, NULL, tee_main, ctx) != 0) {
        close(pair[0]);
        close(pair[1]);
        free(ctx);
        return -1;
    }
    pthread_detach(thread);
    return pair[0];
}
