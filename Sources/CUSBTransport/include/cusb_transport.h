#ifndef CUSB_TRANSPORT_H
#define CUSB_TRANSPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A USB device that exposes a UVC Video Control interface.
typedef struct {
    uint64_t registry_id;          // IORegistry entry ID; stable while the device stays attached
    uint32_t location_id;
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t bcd_device;
    uint8_t vc_interface_number;   // bInterfaceNumber of the Video Control interface
    char name[128];
    char serial[64];
} cusb_camera;

/// Which transport carried a control request.
typedef enum {
    CUSB_PATH_NONE = 0,
    CUSB_PATH_INTERFACE = 1,       // IOUSBInterfaceInterface::ControlRequest on the VC interface
    CUSB_PATH_DEVICE = 2,          // IOUSBDeviceInterface::DeviceRequest on the default pipe
} cusb_path;

/// Lists attached UVC cameras. Writes at most `capacity` entries and returns the total number found.
int cusb_list_cameras(cusb_camera *out, int capacity);

/// Copies the active configuration descriptor. Returns an IOReturn (0 on success).
int32_t cusb_copy_config_descriptor(uint64_t registry_id, uint8_t *buffer, uint32_t capacity, uint32_t *length);

/// Issues one control request. Returns an IOReturn (0 on success); `path` reports the transport used.
int32_t cusb_control(uint64_t registry_id, uint8_t vc_interface_number,
                     uint8_t request_type, uint8_t request, uint16_t value, uint16_t index,
                     void *data, uint16_t length, uint32_t *transferred, cusb_path *path);

#ifdef __cplusplus
}
#endif

#endif
