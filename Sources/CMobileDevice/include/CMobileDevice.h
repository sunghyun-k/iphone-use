//  C API bindings for MobileDevice.framework (private).
//
//  The headers aren't public, so only the needed symbols are declared here, and the
//  framework is opened at runtime with dlopen instead of linked. That way the binary
//  itself doesn't break when the Xcode version changes or the framework is missing.

#ifndef CMOBILEDEVICE_H
#define CMOBILEDEVICE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct AMDevice *AMDeviceRef;
typedef struct AMDServiceConnection *AMDServiceConnectionRef;
typedef struct AMDeviceNotification *AMDeviceNotificationRef;

/// Device attach/detach notification. msg: 1 = attached, 2 = detached.
typedef struct {
    AMDeviceRef device;
    uint32_t msg;
    AMDeviceNotificationRef subscription;
} AMDeviceNotificationInfo;

typedef void (*AMDeviceNotificationCallback)(AMDeviceNotificationInfo *info, void *context);

/// dlopens MobileDevice.framework and resolves the symbols.
/// Does nothing if already loaded. 0 on success.
int cmd_load_mobile_device(void);

/// Why dlopen/dlsym failed. Only valid when cmd_load_mobile_device returned nonzero.
const char *cmd_load_error(void);

// --- Device discovery ---
int32_t cmd_notification_subscribe(AMDeviceNotificationCallback callback,
                                   void *context,
                                   AMDeviceNotificationRef *outNotification);
int32_t cmd_notification_unsubscribe(AMDeviceNotificationRef notification);

// --- Device lifecycle ---
AMDeviceRef cmd_device_retain(AMDeviceRef device);
void cmd_device_release(AMDeviceRef device);
int32_t cmd_device_connect(AMDeviceRef device);
int32_t cmd_device_disconnect(AMDeviceRef device);
int32_t cmd_device_is_paired(AMDeviceRef device);
int32_t cmd_device_validate_pairing(AMDeviceRef device);
int32_t cmd_device_start_session(AMDeviceRef device);
int32_t cmd_device_stop_session(AMDeviceRef device);

// --- Device info ---
CFStringRef cmd_device_copy_identifier(AMDeviceRef device);
CFTypeRef cmd_device_copy_value(AMDeviceRef device, CFStringRef domain, CFStringRef key);

// --- Services ---
/// Starts a lockdown service. MobileDevice handles the TLS negotiation too.
int32_t cmd_device_secure_start_service(AMDeviceRef device,
                                        CFStringRef serviceName,
                                        CFDictionaryRef options,
                                        AMDServiceConnectionRef *outConnection);
int cmd_service_connection_get_socket(AMDServiceConnectionRef connection);

/// Starts a pump joining a TLS-wrapped service connection to one end of a socketpair.
///
/// Lockdown services use TLS, so the raw socket can't be handed straight to DTXSocketTransport.
/// Instead a socketpair is made: one end goes to the caller (= the plaintext socket DTX uses), and
/// two threads relay between the other end and the service connection. MobileDevice does the crypto.
///
/// Returns the socket descriptor to give DTX on success, -1 on failure.
void *cmd_service_connection_get_secure_io_context(AMDServiceConnectionRef connection);
int32_t cmd_service_connection_invalidate(AMDServiceConnectionRef connection);

/// Returns a duplicate of the service connection's raw socket. The caller must close it.
///
/// This service's wire is plaintext, so `AMDServiceConnectionSend/Receive` (SSL) must not be used.
int cmd_service_connection_duplicate_socket(AMDServiceConnectionRef connection);

/// Debugging: returns a socket that relays the raw socket and prints byte counts per direction to stderr.
int cmd_service_connection_tee_socket(AMDServiceConnectionRef connection);

#endif /* CMOBILEDEVICE_H */
