/*
 * ferry_mtp.c — implementation of Ferry's C layer over libmtp (LGPL-2.1+, dynamically linked) and libusb.
 * SPDX-License-Identifier: MIT
 */
#include "ferry_mtp.h"

#include <libmtp.h>
#include <libusb-1.0/libusb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct ferry_device {
    LIBMTP_mtpdevice_t *mtp;
    uint32_t bus;
    uint8_t address;
    uint16_t ptp_code;
    char error[1024];
};

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int init_debug = 0;
static libusb_context *scan_ctx = NULL; /* separate from libmtp's context; only used for scanning/probing */

static void do_init(void) {
    LIBMTP_Set_Debug(init_debug ? (LIBMTP_DEBUG_PTP | LIBMTP_DEBUG_USB) : LIBMTP_DEBUG_NONE);
    LIBMTP_Init();
    if (libusb_init(&scan_ctx) != 0) scan_ctx = NULL;
}

void ferry_init(int debug) {
    init_debug = debug;
    pthread_once(&init_once, do_init);
}

const char *ferry_libmtp_version(void) { return LIBMTP_VERSION_STRING; }

void ferry_free(void *ptr) { free(ptr); }

static void copy_string(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = '\0';
}

/* ---- Error handling ----------------------------------------------------------------------- */

/* Converts libmtp's error stack into one status + a diagnostic string, then clears the stack. */
static ferry_status take_errors(ferry_device *dev, ferry_status fallback) {
    ferry_status status = FERRY_OK;
    dev->ptp_code = 0;
    dev->error[0] = '\0';
    size_t used = 0;
    LIBMTP_error_t *e = LIBMTP_Get_Errorstack(dev->mtp);
    for (; e != NULL; e = e->next) {
        if (e->error_text && used < sizeof(dev->error) - 2) {
            int n = snprintf(dev->error + used, sizeof(dev->error) - used, "%s%s", used ? " | " : "", e->error_text);
            if (n > 0) used += (size_t)n;
            if (used >= sizeof(dev->error)) used = sizeof(dev->error) - 1;
        }
        unsigned int code = 0;
        /* Earlier entries can come from harmless property lookups: prefer the last code,
         * but never lose "invalid object handle" (the object is gone). */
        if (e->error_text && sscanf(e->error_text, "PTP Layer error %x", &code) == 1 && dev->ptp_code != 0x2009) {
            dev->ptp_code = (uint16_t)code;
        }
        ferry_status s;
        switch (e->errornumber) {
        case LIBMTP_ERROR_CANCELLED: s = FERRY_ERR_CANCELLED; break;
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED:
        case LIBMTP_ERROR_USB_LAYER: s = FERRY_ERR_DISCONNECTED; break;
        case LIBMTP_ERROR_STORAGE_FULL: s = FERRY_ERR_STORAGE_FULL; break;
        case LIBMTP_ERROR_MEMORY_ALLOCATION: s = FERRY_ERR_NO_MEMORY; break;
        case LIBMTP_ERROR_CONNECTING: s = FERRY_ERR_CONNECTING; break;
        case LIBMTP_ERROR_PTP_LAYER: s = FERRY_ERR_PTP; break;
        default: s = FERRY_ERR_GENERAL; break;
        }
        /* Keep the most specific status seen. */
        if (status == FERRY_OK || status == FERRY_ERR_GENERAL || (status == FERRY_ERR_PTP && s != FERRY_ERR_GENERAL)) status = s;
    }
    LIBMTP_Clear_Errorstack(dev->mtp);
    if (status == FERRY_ERR_PTP) {
        switch (dev->ptp_code) {
        case 0x2009: status = FERRY_ERR_NOT_FOUND; break;      /* InvalidObjectHandle */
        case 0x02FB: status = FERRY_ERR_CANCELLED; break;      /* PTP_ERROR_CANCEL */
        case 0x02FF:                                            /* PTP_ERROR_IO */
        case 0x02FA:                                            /* PTP_ERROR_TIMEOUT: phone stalled; session is out of step */
        case 0x02F9: status = FERRY_ERR_DISCONNECTED; break;   /* PTP_ERROR_NODEVICE */
        default: break;
        }
    }
    if (status == FERRY_OK) status = fallback;
    return status;
}

const char *ferry_last_error(ferry_device *dev) { return dev ? dev->error : ""; }
uint16_t ferry_last_ptp_code(ferry_device *dev) { return dev ? dev->ptp_code : 0; }

/* ---- USB scan ----------------------------------------------------------------------------- */

static void inspect_interfaces(libusb_device *d, ferry_usb_device *out) {
    struct libusb_config_descriptor *cfg = NULL;
    if (libusb_get_active_config_descriptor(d, &cfg) != 0 || cfg == NULL) {
        if (libusb_get_config_descriptor(d, 0, &cfg) != 0 || cfg == NULL) return;
    }
    for (int i = 0; i < cfg->bNumInterfaces; i++) {
        const struct libusb_interface *itf = &cfg->interface[i];
        for (int a = 0; a < itf->num_altsetting; a++) {
            const struct libusb_interface_descriptor *alt = &itf->altsetting[a];
            uint8_t c = alt->bInterfaceClass, sc = alt->bInterfaceSubClass, p = alt->bInterfaceProtocol;
            if (c == LIBUSB_CLASS_PTP) out->has_mtp_interface = 1;                              /* PTP / MTP */
            else if (c == 0xFF && sc == 0xFF && p == 0x00 && alt->bNumEndpoints == 3) out->has_mtp_interface = 1; /* Android MTP */
            else if (c == 0xFF && sc == 0x42 && p == 0x01) out->has_adb_interface = 1;          /* adb */
            else if (c == LIBUSB_CLASS_HID || c == LIBUSB_CLASS_MASS_STORAGE || c == LIBUSB_CLASS_HUB ||
                     c == LIBUSB_CLASS_PRINTER || c == LIBUSB_CLASS_VIDEO) out->has_excluded_class = 1;
        }
    }
    libusb_free_config_descriptor(cfg);
}

int ferry_usb_scan(ferry_usb_device *out, int max) {
    ferry_init(init_debug);
    if (!scan_ctx || !out || max <= 0) return -1;
    libusb_device **list = NULL;
    ssize_t n = libusb_get_device_list(scan_ctx, &list);
    if (n < 0) return -1;
    int found = 0;
    for (ssize_t i = 0; i < n && found < max; i++) {
        struct libusb_device_descriptor desc;
        if (libusb_get_device_descriptor(list[i], &desc) != 0) continue;
        if (desc.bDeviceClass == LIBUSB_CLASS_HUB) continue;
        ferry_usb_device *u = &out[found++];
        memset(u, 0, sizeof(*u));
        u->bus = libusb_get_bus_number(list[i]);
        u->address = libusb_get_device_address(list[i]);
        u->vendor_id = desc.idVendor;
        u->product_id = desc.idProduct;
        inspect_interfaces(list[i], u);
    }
    libusb_free_device_list(list, 1);
    return found;
}

static int mtp_interface_number(libusb_device *d) {
    struct libusb_config_descriptor *cfg = NULL;
    int result = -1;
    if (libusb_get_active_config_descriptor(d, &cfg) != 0 || !cfg) return -1;
    for (int i = 0; i < cfg->bNumInterfaces && result < 0; i++) {
        const struct libusb_interface_descriptor *alt = &cfg->interface[i].altsetting[0];
        if (alt->bInterfaceClass == LIBUSB_CLASS_PTP ||
            (alt->bInterfaceClass == 0xFF && alt->bInterfaceSubClass == 0xFF && alt->bInterfaceProtocol == 0 && alt->bNumEndpoints == 3)) {
            result = alt->bInterfaceNumber;
        }
    }
    libusb_free_config_descriptor(cfg);
    return result;
}

ferry_status ferry_probe_access(uint32_t bus, uint8_t address) {
    ferry_init(init_debug);
    if (!scan_ctx) return FERRY_ERR_GENERAL;
    libusb_device **list = NULL;
    ssize_t n = libusb_get_device_list(scan_ctx, &list);
    if (n < 0) return FERRY_ERR_GENERAL;
    ferry_status status = FERRY_ERR_NO_DEVICE;
    for (ssize_t i = 0; i < n; i++) {
        if (libusb_get_bus_number(list[i]) != bus || libusb_get_device_address(list[i]) != address) continue;
        int itf = mtp_interface_number(list[i]);
        libusb_device_handle *h = NULL;
        int rc = libusb_open(list[i], &h);
        if (rc == LIBUSB_ERROR_ACCESS || rc == LIBUSB_ERROR_BUSY) { status = FERRY_ERR_BUSY; break; }
        if (rc == LIBUSB_ERROR_NO_DEVICE) { status = FERRY_ERR_NO_DEVICE; break; }
        if (rc != 0 || !h) { status = FERRY_ERR_GENERAL; break; }
        status = FERRY_OK;
        if (itf >= 0) {
            rc = libusb_claim_interface(h, itf);
            if (rc == LIBUSB_ERROR_ACCESS || rc == LIBUSB_ERROR_BUSY) status = FERRY_ERR_BUSY;
            else if (rc == 0) libusb_release_interface(h, itf);
        }
        libusb_close(h);
        break;
    }
    libusb_free_device_list(list, 1);
    return status;
}

/* ---- MTP devices ------------------------------------------------------------------------- */

ferry_status ferry_detect(ferry_raw_device *out, int max, int *count) {
    ferry_init(init_debug);
    *count = 0;
    LIBMTP_raw_device_t *raw = NULL;
    int n = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&raw, &n);
    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED) { free(raw); return FERRY_OK; }
    if (err == LIBMTP_ERROR_CONNECTING) { free(raw); return FERRY_ERR_CONNECTING; }
    if (err == LIBMTP_ERROR_MEMORY_ALLOCATION) { free(raw); return FERRY_ERR_NO_MEMORY; }
    if (err != LIBMTP_ERROR_NONE) { free(raw); return FERRY_ERR_GENERAL; }
    for (int i = 0; i < n && *count < max; i++) {
        ferry_raw_device *r = &out[(*count)++];
        memset(r, 0, sizeof(*r));
        r->bus = raw[i].bus_location;
        r->address = raw[i].devnum;
        r->vendor_id = raw[i].device_entry.vendor_id;
        r->product_id = raw[i].device_entry.product_id;
        copy_string(r->vendor, sizeof(r->vendor), raw[i].device_entry.vendor);
        copy_string(r->product, sizeof(r->product), raw[i].device_entry.product);
    }
    free(raw);
    return FERRY_OK;
}

ferry_status ferry_open(uint32_t bus, uint8_t address, ferry_device **out) {
    ferry_init(init_debug);
    *out = NULL;
    /* libmtp 1.1.23 does not close its USB handle on several open-failure paths. Checking for a
     * competing owner first means the common "busy" case never reaches those paths. */
    ferry_status pre = ferry_probe_access(bus, address);
    if (pre == FERRY_ERR_BUSY || pre == FERRY_ERR_NO_DEVICE) return pre;
    LIBMTP_raw_device_t *raw = NULL;
    int n = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&raw, &n);
    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED || (err == LIBMTP_ERROR_NONE && n == 0)) { free(raw); return FERRY_ERR_NO_DEVICE; }
    if (err != LIBMTP_ERROR_NONE) { free(raw); return FERRY_ERR_CONNECTING; }
    LIBMTP_mtpdevice_t *mtp = NULL;
    int matched = 0;
    for (int i = 0; i < n; i++) {
        if (raw[i].bus_location == bus && raw[i].devnum == address) {
            matched = 1;
            mtp = LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
            break;
        }
    }
    free(raw);
    /* Present on USB but not (yet) recognised as MTP: usually still switching mode. */
    if (!matched) return FERRY_ERR_CONNECTING;
    if (!mtp) {
        /* Tell "someone else has it" apart from "phone not ready yet". */
        ferry_status probe = ferry_probe_access(bus, address);
        if (probe == FERRY_ERR_BUSY) return FERRY_ERR_BUSY;
        if (probe == FERRY_ERR_NO_DEVICE) return FERRY_ERR_NO_DEVICE;
        return FERRY_ERR_CONNECTING;
    }
    ferry_device *dev = calloc(1, sizeof(ferry_device));
    if (!dev) { LIBMTP_Release_Device(mtp); return FERRY_ERR_NO_MEMORY; }
    dev->mtp = mtp;
    dev->bus = bus;
    dev->address = address;
    LIBMTP_Clear_Errorstack(mtp);
    *out = dev;
    return FERRY_OK;
}

void ferry_close(ferry_device *dev) {
    if (!dev) return;
    if (dev->mtp) LIBMTP_Release_Device(dev->mtp);
    free(dev);
}

void ferry_device_strings(ferry_device *dev, char **manufacturer, char **model, char **friendly_name, char **serial) {
    if (manufacturer) *manufacturer = LIBMTP_Get_Manufacturername(dev->mtp);
    if (model) *model = LIBMTP_Get_Modelname(dev->mtp);
    if (friendly_name) *friendly_name = LIBMTP_Get_Friendlyname(dev->mtp);
    if (serial) *serial = LIBMTP_Get_Serialnumber(dev->mtp);
    LIBMTP_Clear_Errorstack(dev->mtp); /* missing optional strings are not errors */
}

ferry_status ferry_storages(ferry_device *dev, ferry_storage *out, int max, int *count) {
    *count = 0;
    LIBMTP_Clear_Errorstack(dev->mtp);
    int rc = LIBMTP_Get_Storage(dev->mtp, LIBMTP_STORAGE_SORTBY_NOTSORTED);
    if (rc < 0) {
        /* Locked phones often fail here with no storage at all; report "no storages" unless USB died. */
        ferry_status s = take_errors(dev, FERRY_ERR_GENERAL);
        return (s == FERRY_ERR_DISCONNECTED || s == FERRY_ERR_CANCELLED) ? s : FERRY_OK;
    }
    for (LIBMTP_devicestorage_t *st = dev->mtp->storage; st && *count < max; st = st->next) {
        ferry_storage *o = &out[(*count)++];
        memset(o, 0, sizeof(*o));
        o->id = st->id;
        o->storage_type = st->StorageType;
        o->access_capability = st->AccessCapability;
        o->capacity = st->MaxCapacity;
        o->free_bytes = st->FreeSpaceInBytes;
        copy_string(o->description, sizeof(o->description), st->StorageDescription);
        copy_string(o->volume, sizeof(o->volume), st->VolumeIdentifier);
    }
    LIBMTP_Clear_Errorstack(dev->mtp);
    return FERRY_OK;
}

static void fill_object(ferry_object *o, const LIBMTP_file_t *f) {
    o->id = f->item_id;
    o->parent_id = f->parent_id;
    o->storage_id = f->storage_id;
    o->size = f->filesize;
    o->mtime = (int64_t)f->modificationdate;
    o->is_folder = f->filetype == LIBMTP_FILETYPE_FOLDER;
    o->name = f->filename ? strdup(f->filename) : NULL;
}

ferry_status ferry_list(ferry_device *dev, uint32_t storage_id, uint32_t parent_id, ferry_object **out, int *count) {
    *out = NULL;
    *count = 0;
    LIBMTP_Clear_Errorstack(dev->mtp);
    /* LIBMTP_Get_Files_And_Folders silently drops objects whose metadata fails and reports a failed
     * listing as "empty". List handles explicitly so failures are visible. */
    uint32_t *ids = NULL;
    int n = LIBMTP_Get_Children(dev->mtp, storage_id, parent_id, &ids);
    if (n < 0) { free(ids); return take_errors(dev, FERRY_ERR_GENERAL); }
    if (n == 0) { free(ids); LIBMTP_Clear_Errorstack(dev->mtp); return FERRY_OK; }
    ferry_object *arr = calloc((size_t)n, sizeof(ferry_object));
    if (!arr) { free(ids); return FERRY_ERR_NO_MEMORY; }
    int filled = 0, skipped = 0;
    for (int i = 0; i < n; i++) {
        LIBMTP_Clear_Errorstack(dev->mtp);
        LIBMTP_file_t *f = LIBMTP_Get_Filemetadata(dev->mtp, ids[i]);
        if (!f) { skipped++; continue; }
        fill_object(&arr[filled], f);
        /* A failed 64-bit size lookup leaves an error and filesize 0: report the size as unknown instead. */
        if (!arr[filled].is_folder && LIBMTP_Get_Errorstack(dev->mtp) != NULL) arr[filled].size = FERRY_SIZE_UNKNOWN;
        filled++;
        LIBMTP_destroy_file_t(f);
    }
    free(ids);
    LIBMTP_Clear_Errorstack(dev->mtp);
    if (skipped > 0) {
        /* Either some objects are malformed, or the phone stopped answering. Ask again to tell which. */
        uint32_t *again = NULL;
        int m = LIBMTP_Get_Children(dev->mtp, storage_id, parent_id, &again);
        free(again);
        if (m < 0) {
            ferry_free_objects(arr, filled);
            return take_errors(dev, FERRY_ERR_DISCONNECTED);
        }
        snprintf(dev->error, sizeof(dev->error), "skipped %d unreadable objects", skipped);
    }
    *out = arr;
    *count = filled;
    return FERRY_OK;
}

void ferry_free_objects(ferry_object *objects, int count) {
    if (!objects) return;
    for (int i = 0; i < count; i++) free(objects[i].name);
    free(objects);
}

ferry_status ferry_object_info(ferry_device *dev, uint32_t object_id, ferry_object *out) {
    memset(out, 0, sizeof(*out));
    LIBMTP_Clear_Errorstack(dev->mtp);
    LIBMTP_file_t *f = LIBMTP_Get_Filemetadata(dev->mtp, object_id);
    if (!f) return take_errors(dev, FERRY_ERR_NOT_FOUND);
    fill_object(out, f);
    LIBMTP_destroy_file_t(f);
    return FERRY_OK;
}

/* ---- Downloads ---------------------------------------------------------------------------- */

typedef struct {
    ferry_write_fn write;
    ferry_progress_fn progress;
    void *ctx;
    int sink_failed;
    int cancelled;
    uint64_t bytes;
} download_ctx;

static uint16_t put_handler(void *params, void *priv, uint32_t sendlen, unsigned char *data, uint32_t *putlen) {
    (void)params;
    download_ctx *c = (download_ctx *)priv;
    int rc = c->write(c->ctx, data, sendlen);
    if (rc == 0) { *putlen = sendlen; c->bytes += sendlen; return LIBMTP_HANDLER_RETURN_OK; }
    *putlen = 0;
    if (rc == 2) { c->cancelled = 1; return LIBMTP_HANDLER_RETURN_CANCEL; }
    c->sink_failed = 1;
    return LIBMTP_HANDLER_RETURN_ERROR;
}

static int progress_handler(uint64_t const sent, uint64_t const total, void const *const data) {
    download_ctx *c = (download_ctx *)data;
    if (c->progress && c->progress(c->ctx, sent, total) != 0) { c->cancelled = 1; return 1; }
    return 0;
}

static ferry_status download_failed(ferry_device *dev, download_ctx *c) {
    if (c->cancelled) { LIBMTP_Clear_Errorstack(dev->mtp); return FERRY_ERR_CANCELLED; }
    if (c->sink_failed) { LIBMTP_Clear_Errorstack(dev->mtp); return FERRY_ERR_SINK; }
    return take_errors(dev, FERRY_ERR_GENERAL);
}

ferry_status ferry_download(ferry_device *dev, uint32_t object_id, uint64_t expected_size, uint32_t window_bytes,
                            ferry_write_fn write, ferry_progress_fn progress, void *ctx) {
    download_ctx c = { write, progress, ctx, 0, 0, 0 };
    LIBMTP_Clear_Errorstack(dev->mtp);

    /* The USB container length is 32 bits and includes a 12-byte header, so one GetObject can carry at
     * most 0xFFFFFFFF - 12 bytes of data. */
    const uint64_t single_limit = 0xFFFFFFFFull - 12;

    if (expected_size == FERRY_SIZE_UNKNOWN || expected_size < single_limit) {
        /* Normal case: one streaming GetObject; libmtp hands us USB-sized chunks. */
        int rc = LIBMTP_Get_File_To_Handler(dev->mtp, object_id, put_handler, &c, progress_handler, &c);
        if (rc != 0 || c.cancelled || c.sink_failed) return download_failed(dev, &c);
        /* Unknown size and the transfer filled the 32-bit container: the file may be larger than what
         * arrived, and there is no way to tell. Refuse rather than save a possibly truncated copy. */
        if (expected_size == FERRY_SIZE_UNKNOWN && c.bytes >= single_limit) return FERRY_ERR_UNSUPPORTED;
        return FERRY_OK;
    }

    /* >= 4 GiB: libmtp's single-transfer path carries a 32-bit length, so read in 64-bit windows
     * (Android's GetPartialObject64). Phones without it can't send such files over MTP. */
    if (window_bytes == 0) window_bytes = 8u * 1024u * 1024u;
    uint64_t offset = 0;
    while (offset < expected_size) {
        if (progress && progress(ctx, offset, expected_size) != 0) return FERRY_ERR_CANCELLED;
        uint64_t left = expected_size - offset;
        uint32_t want = left < window_bytes ? (uint32_t)left : window_bytes;
        unsigned char *buf = NULL;
        unsigned int got = 0;
        int rc = LIBMTP_GetPartialObject(dev->mtp, object_id, offset, want, &buf, &got);
        if (rc != 0) {
            free(buf);
            ferry_status s = take_errors(dev, FERRY_ERR_GENERAL);
            if (strstr(dev->error, "not supported") || strstr(dev->error, "32bit offsets")) return FERRY_ERR_UNSUPPORTED;
            return s;
        }
        if (got == 0) {
            /* libmtp clamps reads to its own idea of the size; ending early means that lookup failed. */
            free(buf);
            return take_errors(dev, FERRY_ERR_GENERAL);
        }
        int w = write(ctx, buf, got);
        free(buf);
        if (w == 2) return FERRY_ERR_CANCELLED;
        if (w != 0) return FERRY_ERR_SINK;
        offset += got;
    }
    if (progress) progress(ctx, offset, expected_size);
    return FERRY_OK;
}

ferry_status ferry_thumbnail(ferry_device *dev, uint32_t object_id, unsigned char **data, uint32_t *size) {
    *data = NULL;
    *size = 0;
    unsigned int len = 0;
    LIBMTP_Clear_Errorstack(dev->mtp);
    if (LIBMTP_Get_Thumbnail(dev->mtp, object_id, data, &len) != 0) {
        free(*data);
        *data = NULL;
        ferry_status s = take_errors(dev, FERRY_ERR_UNSUPPORTED);
        return s == FERRY_ERR_DISCONNECTED ? s : FERRY_ERR_UNSUPPORTED;
    }
    *size = len;
    return FERRY_OK;
}
