/*
 * zapdrop_mtp.h — Zapdrop's small C compatibility layer over libmtp and libusb.
 *
 * This is the only interface the Swift code sees. No libmtp or libusb type crosses it.
 * All functions taking a zapdrop_device must be called from one thread at a time (Zapdrop uses one
 * serial queue for every call). Strings returned through out-parameters are owned by the caller
 * and must be released with zapdrop_free().
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef ZAPDROP_MTP_H
#define ZAPDROP_MTP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ZAPDROP_OK = 0,
    ZAPDROP_ERR_GENERAL = 1,
    ZAPDROP_ERR_NO_DEVICE = 2,     /* not found / not attached */
    ZAPDROP_ERR_BUSY = 3,          /* another process holds the USB interface */
    ZAPDROP_ERR_CONNECTING = 4,    /* device present but the MTP session could not be opened */
    ZAPDROP_ERR_DISCONNECTED = 5,  /* USB layer failure during an operation */
    ZAPDROP_ERR_CANCELLED = 6,
    ZAPDROP_ERR_STORAGE_FULL = 7,
    ZAPDROP_ERR_PTP = 8,           /* the phone returned an MTP/PTP error code (see ptp_code) */
    ZAPDROP_ERR_NOT_FOUND = 9,     /* object handle no longer valid */
    ZAPDROP_ERR_NO_MEMORY = 10,
    ZAPDROP_ERR_SINK = 11,         /* the caller's write callback failed */
    ZAPDROP_ERR_UNSUPPORTED = 12   /* e.g. >4 GB file on a phone without 64-bit partial reads */
} zapdrop_status;

typedef struct zapdrop_device zapdrop_device;

/* ---- Library ---------------------------------------------------------------------------- */

void zapdrop_init(int debug);
const char *zapdrop_libmtp_version(void);
void zapdrop_free(void *ptr);

/* ---- USB scan (never opens a device) ---------------------------------------------------- */

typedef struct {
    uint32_t bus;
    uint8_t address;
    uint16_t vendor_id;
    uint16_t product_id;
    int has_mtp_interface;   /* PTP still-image class or Android's vendor-specific MTP interface */
    int has_adb_interface;
    int has_excluded_class;  /* HID, mass storage, hub, printer, video — not a phone */
    int speed;               /* libusb_speed: 0 unknown, 1 low, 2 full, 3 high (USB 2), 4 super (USB 3, 5 Gbps), 5 super+ (10 Gbps) */
} zapdrop_usb_device;

/* Fills up to `max` entries. Returns the number found, or -1 on error. */
int zapdrop_usb_scan(zapdrop_usb_device *out, int max);

/* Briefly claims the device's MTP interface to see whether another process holds it.
 * Returns ZAPDROP_OK, ZAPDROP_ERR_BUSY or ZAPDROP_ERR_NO_DEVICE. Do not call while Zapdrop has a session open. */
zapdrop_status zapdrop_probe_access(uint32_t bus, uint8_t address);

/* ---- MTP devices ------------------------------------------------------------------------ */

typedef struct {
    uint32_t bus;
    uint8_t address;
    uint16_t vendor_id;
    uint16_t product_id;
    char vendor[64];
    char product[128];
} zapdrop_raw_device;

/* Lists MTP-capable devices (may briefly probe unknown USB devices). */
zapdrop_status zapdrop_detect(zapdrop_raw_device *out, int max, int *count);

/* Opens an uncached MTP session (folders are listed lazily). */
zapdrop_status zapdrop_open(uint32_t bus, uint8_t address, zapdrop_device **out);
void zapdrop_close(zapdrop_device *dev);

/* Device strings; each may be NULL. Free with zapdrop_free. */
void zapdrop_device_strings(zapdrop_device *dev, char **manufacturer, char **model, char **friendly_name, char **serial);

/* Battery charge in percent (0–100), or -1 if the phone doesn't report it. One MTP request. */
int zapdrop_battery_percent(zapdrop_device *dev);

typedef struct {
    uint32_t id;
    uint16_t storage_type;      /* 1 fixed ROM, 2 removable ROM, 3 fixed RAM, 4 removable RAM */
    uint16_t access_capability; /* 0 read-write, 1 read-only, 2 read-only with delete */
    uint64_t capacity;
    uint64_t free_bytes;
    char description[256];
    char volume[256];
} zapdrop_storage;

/* Refreshes and returns storages. count == 0 usually means the phone is locked. */
zapdrop_status zapdrop_storages(zapdrop_device *dev, zapdrop_storage *out, int max, int *count);

/* Size value meaning "the phone did not report an exact size". */
#define ZAPDROP_SIZE_UNKNOWN 0xFFFFFFFFull

typedef struct {
    uint32_t id;
    uint32_t parent_id;
    uint32_t storage_id;
    uint64_t size;      /* 0xFFFFFFFF means "large, exact size unknown" */
    int64_t mtime;      /* seconds since 1970, 0 if unknown */
    int is_folder;
    char *name;         /* UTF-8, owned by the array; may be NULL */
} zapdrop_object;

/* Lists direct children. Free the result with zapdrop_free_objects. */
zapdrop_status zapdrop_list(zapdrop_device *dev, uint32_t storage_id, uint32_t parent_id, zapdrop_object **out, int *count);

/* The same listing in two steps, so a large folder can be shown in pieces and abandoned between them.
 * Most phones answer one metadata request per object (Android ~10–50 ms each), which dominates big folders.
 * zapdrop_list_handles: one request for the children's handles; free *ids with zapdrop_free.
 * zapdrop_list_objects: metadata for `n` of those handles; storage_id/parent_id are only used to tell a phone
 * that stopped answering from malformed objects. Free the result with zapdrop_free_objects. */
zapdrop_status zapdrop_list_handles(zapdrop_device *dev, uint32_t storage_id, uint32_t parent_id, uint32_t **ids, int *count);
zapdrop_status zapdrop_list_objects(zapdrop_device *dev, uint32_t storage_id, uint32_t parent_id,
                                const uint32_t *ids, int n, zapdrop_object **out, int *count);
void zapdrop_free_objects(zapdrop_object *objects, int count);

/* Fresh metadata for one object. out->name must be freed with zapdrop_free. */
zapdrop_status zapdrop_object_info(zapdrop_device *dev, uint32_t object_id, zapdrop_object *out);

/* Return 0 to continue, 1 on error, 2 to cancel. */
typedef int (*zapdrop_write_fn)(void *ctx, const unsigned char *data, uint32_t length);
/* Return non-zero to cancel. */
typedef int (*zapdrop_progress_fn)(void *ctx, uint64_t done, uint64_t total);

/* Streams one file to `write`. `expected_size` selects the strategy: files below 4 GiB (and files of
 * unknown size) use a single GetObject; larger files use 64-bit partial reads in windows of `window_bytes`.
 * An unknown-size file that fills a whole 32-bit transfer fails with ZAPDROP_ERR_UNSUPPORTED rather than
 * risk saving a truncated copy. */
zapdrop_status zapdrop_download(zapdrop_device *dev, uint32_t object_id, uint64_t expected_size, uint32_t window_bytes,
                            zapdrop_write_fn write, zapdrop_progress_fn progress, void *ctx);

/* ---- Sending to the phone ------------------------------------------------------------------
 * The only calls that change anything on the phone. Both only add: nothing is overwritten or deleted. */

/* Fills `data` with up to `wanted` bytes and sets *got (0 only at the end). Return 0 to continue, 1 on error,
 * 2 to cancel. */
typedef int (*zapdrop_read_fn)(void *ctx, unsigned char *data, uint32_t wanted, uint32_t *got);

/* Sends one new file of exactly `size` bytes (below 4 GiB) into a folder; parent_id 0xFFFFFFFF is the storage
 * root. *new_id receives the new object's handle. */
zapdrop_status zapdrop_upload(zapdrop_device *dev, uint32_t storage_id, uint32_t parent_id, const char *name, uint64_t size,
                          zapdrop_read_fn read, zapdrop_progress_fn progress, void *ctx, uint32_t *new_id);

/* Creates a folder; parent_id 0xFFFFFFFF is the storage root. */
zapdrop_status zapdrop_create_folder(zapdrop_device *dev, uint32_t storage_id, uint32_t parent_id, const char *name,
                                 uint32_t *new_id);

/* Device-generated thumbnail (usually JPEG). *data must be freed with zapdrop_free. */
zapdrop_status zapdrop_thumbnail(zapdrop_device *dev, uint32_t object_id, unsigned char **data, uint32_t *size);

/* Diagnostics for the last failed call (for logs only, never shown raw to users). */
const char *zapdrop_last_error(zapdrop_device *dev);
/* PTP response code behind the last ZAPDROP_ERR_PTP, or 0. */
uint16_t zapdrop_last_ptp_code(zapdrop_device *dev);

#ifdef __cplusplus
}
#endif

#endif /* ZAPDROP_MTP_H */
