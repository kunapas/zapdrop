/*
 * ferry_mtp.h — Ferry's small C compatibility layer over libmtp and libusb.
 *
 * This is the only interface the Swift code sees. No libmtp or libusb type crosses it.
 * All functions taking a ferry_device must be called from one thread at a time (Ferry uses one
 * serial queue for every call). Strings returned through out-parameters are owned by the caller
 * and must be released with ferry_free().
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef FERRY_MTP_H
#define FERRY_MTP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    FERRY_OK = 0,
    FERRY_ERR_GENERAL = 1,
    FERRY_ERR_NO_DEVICE = 2,     /* not found / not attached */
    FERRY_ERR_BUSY = 3,          /* another process holds the USB interface */
    FERRY_ERR_CONNECTING = 4,    /* device present but the MTP session could not be opened */
    FERRY_ERR_DISCONNECTED = 5,  /* USB layer failure during an operation */
    FERRY_ERR_CANCELLED = 6,
    FERRY_ERR_STORAGE_FULL = 7,
    FERRY_ERR_PTP = 8,           /* the phone returned an MTP/PTP error code (see ptp_code) */
    FERRY_ERR_NOT_FOUND = 9,     /* object handle no longer valid */
    FERRY_ERR_NO_MEMORY = 10,
    FERRY_ERR_SINK = 11,         /* the caller's write callback failed */
    FERRY_ERR_UNSUPPORTED = 12   /* e.g. >4 GB file on a phone without 64-bit partial reads */
} ferry_status;

typedef struct ferry_device ferry_device;

/* ---- Library ---------------------------------------------------------------------------- */

void ferry_init(int debug);
const char *ferry_libmtp_version(void);
void ferry_free(void *ptr);

/* ---- USB scan (never opens a device) ---------------------------------------------------- */

typedef struct {
    uint32_t bus;
    uint8_t address;
    uint16_t vendor_id;
    uint16_t product_id;
    int has_mtp_interface;   /* PTP still-image class or Android's vendor-specific MTP interface */
    int has_adb_interface;
    int has_excluded_class;  /* HID, mass storage, hub, printer, video — not a phone */
} ferry_usb_device;

/* Fills up to `max` entries. Returns the number found, or -1 on error. */
int ferry_usb_scan(ferry_usb_device *out, int max);

/* Briefly claims the device's MTP interface to see whether another process holds it.
 * Returns FERRY_OK, FERRY_ERR_BUSY or FERRY_ERR_NO_DEVICE. Do not call while Ferry has a session open. */
ferry_status ferry_probe_access(uint32_t bus, uint8_t address);

/* ---- MTP devices ------------------------------------------------------------------------ */

typedef struct {
    uint32_t bus;
    uint8_t address;
    uint16_t vendor_id;
    uint16_t product_id;
    char vendor[64];
    char product[128];
} ferry_raw_device;

/* Lists MTP-capable devices (may briefly probe unknown USB devices). */
ferry_status ferry_detect(ferry_raw_device *out, int max, int *count);

/* Opens an uncached MTP session (folders are listed lazily). */
ferry_status ferry_open(uint32_t bus, uint8_t address, ferry_device **out);
void ferry_close(ferry_device *dev);

/* Device strings; each may be NULL. Free with ferry_free. */
void ferry_device_strings(ferry_device *dev, char **manufacturer, char **model, char **friendly_name, char **serial);

typedef struct {
    uint32_t id;
    uint16_t storage_type;      /* 1 fixed ROM, 2 removable ROM, 3 fixed RAM, 4 removable RAM */
    uint16_t access_capability; /* 0 read-write, 1 read-only, 2 read-only with delete */
    uint64_t capacity;
    uint64_t free_bytes;
    char description[256];
    char volume[256];
} ferry_storage;

/* Refreshes and returns storages. count == 0 usually means the phone is locked. */
ferry_status ferry_storages(ferry_device *dev, ferry_storage *out, int max, int *count);

typedef struct {
    uint32_t id;
    uint32_t parent_id;
    uint32_t storage_id;
    uint64_t size;      /* 0xFFFFFFFF means "large, exact size unknown" */
    int64_t mtime;      /* seconds since 1970, 0 if unknown */
    int is_folder;
    char *name;         /* UTF-8, owned by the array; may be NULL */
} ferry_object;

/* Lists direct children. Free the result with ferry_free_objects. */
ferry_status ferry_list(ferry_device *dev, uint32_t storage_id, uint32_t parent_id, ferry_object **out, int *count);
void ferry_free_objects(ferry_object *objects, int count);

/* Fresh metadata for one object. out->name must be freed with ferry_free. */
ferry_status ferry_object_info(ferry_device *dev, uint32_t object_id, ferry_object *out);

/* Return 0 to continue, 1 on error, 2 to cancel. */
typedef int (*ferry_write_fn)(void *ctx, const unsigned char *data, uint32_t length);
/* Return non-zero to cancel. */
typedef int (*ferry_progress_fn)(void *ctx, uint64_t done, uint64_t total);

/* Streams one file to `write`. `expected_size` selects the strategy: files below 4 GiB use a single
 * GetObject; larger files use 64-bit partial reads in windows of `window_bytes`. */
ferry_status ferry_download(ferry_device *dev, uint32_t object_id, uint64_t expected_size, uint32_t window_bytes,
                            ferry_write_fn write, ferry_progress_fn progress, void *ctx);

/* Device-generated thumbnail (usually JPEG). *data must be freed with ferry_free. */
ferry_status ferry_thumbnail(ferry_device *dev, uint32_t object_id, unsigned char **data, uint32_t *size);

/* Diagnostics for the last failed call (for logs only, never shown raw to users). */
const char *ferry_last_error(ferry_device *dev);
/* PTP response code behind the last FERRY_ERR_PTP, or 0. */
uint16_t ferry_last_ptp_code(ferry_device *dev);

#ifdef __cplusplus
}
#endif

#endif /* FERRY_MTP_H */
