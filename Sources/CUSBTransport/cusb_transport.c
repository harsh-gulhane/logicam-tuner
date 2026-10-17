#include "cusb_transport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <string.h>

#define UVC_CLASS_VIDEO 0x0E
#define UVC_SUBCLASS_CONTROL 0x01

static int read_int_property(io_registry_entry_t entry, CFStringRef key, int64_t *out) {
    CFTypeRef ref = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!ref) return 0;
    int ok = CFGetTypeID(ref) == CFNumberGetTypeID() && CFNumberGetValue(ref, kCFNumberSInt64Type, out);
    CFRelease(ref);
    return ok;
}

static void read_string_property(io_registry_entry_t entry, CFStringRef key, char *out, size_t capacity) {
    out[0] = '\0';
    CFTypeRef ref = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!ref) return;
    if (CFGetTypeID(ref) == CFStringGetTypeID()) {
        CFStringGetCString(ref, out, (CFIndex)capacity, kCFStringEncodingUTF8);
    }
    CFRelease(ref);
}

/// Finds the child interface service with the given class/subclass (or number when number >= 0).
static io_service_t find_interface(io_service_t device, int number, int *found_number) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(device, kIOServicePlane, &it) != KERN_SUCCESS) return IO_OBJECT_NULL;
    io_service_t child, match = IO_OBJECT_NULL;
    while (!match && (child = IOIteratorNext(it))) {
        int64_t cls = -1, sub = -1, num = -1;
        read_int_property(child, CFSTR("bInterfaceClass"), &cls);
        read_int_property(child, CFSTR("bInterfaceSubClass"), &sub);
        read_int_property(child, CFSTR("bInterfaceNumber"), &num);
        int is_vc = cls == UVC_CLASS_VIDEO && sub == UVC_SUBCLASS_CONTROL;
        if (is_vc && (number < 0 || num == number)) {
            match = child;
            if (found_number) *found_number = (int)num;
        } else {
            IOObjectRelease(child);
        }
    }
    IOObjectRelease(it);
    return match;
}

int cusb_list_cameras(cusb_camera *out, int capacity) {
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS) {
        return 0;
    }
    int count = 0;
    io_service_t device;
    while ((device = IOIteratorNext(it))) {
        int vc_number = -1;
        io_service_t vc = find_interface(device, -1, &vc_number);
        if (vc) {
            if (count < capacity) {
                cusb_camera *cam = &out[count];
                memset(cam, 0, sizeof(*cam));
                int64_t v = 0;
                IORegistryEntryGetRegistryEntryID(device, &cam->registry_id);
                if (read_int_property(device, CFSTR("locationID"), &v)) cam->location_id = (uint32_t)v;
                if (read_int_property(device, CFSTR("idVendor"), &v)) cam->vendor_id = (uint16_t)v;
                if (read_int_property(device, CFSTR("idProduct"), &v)) cam->product_id = (uint16_t)v;
                if (read_int_property(device, CFSTR("bcdDevice"), &v)) cam->bcd_device = (uint16_t)v;
                cam->vc_interface_number = (uint8_t)vc_number;
                read_string_property(device, CFSTR("USB Product Name"), cam->name, sizeof(cam->name));
                read_string_property(device, CFSTR("USB Serial Number"), cam->serial, sizeof(cam->serial));
            }
            count++;
            IOObjectRelease(vc);
        }
        IOObjectRelease(device);
    }
    IOObjectRelease(it);
    return count;
}

static io_service_t device_for_id(uint64_t registry_id) {
    return IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registry_id));
}

static IOReturn create_plugin(io_service_t service, CFUUIDRef client_type, CFUUIDRef interface_id, void ***out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, client_type, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != kIOReturnSuccess || !plugin) return kr ? kr : kIOReturnNoDevice;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(interface_id), (LPVOID *)out);
    IODestroyPlugInInterface(plugin);
    return (hr == S_OK && *out) ? kIOReturnSuccess : kIOReturnUnsupported;
}

int32_t cusb_copy_config_descriptor(uint64_t registry_id, uint8_t *buffer, uint32_t capacity, uint32_t *length) {
    *length = 0;
    io_service_t device = device_for_id(registry_id);
    if (!device) return kIOReturnNoDevice;
    IOUSBDeviceInterface **dev = NULL;
    IOReturn kr = create_plugin(device, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID, (void ***)&dev);
    IOObjectRelease(device);
    if (kr != kIOReturnSuccess) return kr;
    IOUSBConfigurationDescriptorPtr config = NULL;
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &config);
    if (kr == kIOReturnSuccess && config) {
        uint32_t total = USBToHostWord(config->wTotalLength);
        if (total > capacity) {
            *length = total;
            kr = kIOReturnOverrun;
        } else {
            memcpy(buffer, config, total);
            *length = total;
        }
    }
    (*dev)->Release(dev);
    return kr;
}

int32_t cusb_control(uint64_t registry_id, uint8_t vc_interface_number,
                     uint8_t request_type, uint8_t request, uint16_t value, uint16_t index,
                     void *data, uint16_t length, uint32_t *transferred, cusb_path *path) {
    *transferred = 0;
    *path = CUSB_PATH_NONE;
    io_service_t device = device_for_id(registry_id);
    if (!device) return kIOReturnNoDevice;

    IOUSBDevRequest req = {
        .bmRequestType = request_type,
        .bRequest = request,
        .wValue = value,
        .wIndex = index,
        .wLength = length,
        .pData = data,
    };

    // The interface path works while other clients (UVCAssistant, vendor agents) hold the camera.
    IOReturn kr = kIOReturnNotFound;
    io_service_t vc = find_interface(device, vc_interface_number, NULL);
    if (vc) {
        IOUSBInterfaceInterface **intf = NULL;
        kr = create_plugin(vc, kIOUSBInterfaceUserClientTypeID, kIOUSBInterfaceInterfaceID, (void ***)&intf);
        IOObjectRelease(vc);
        if (kr == kIOReturnSuccess) {
            kr = (*intf)->ControlRequest(intf, 0, &req);
            (*intf)->Release(intf);
            if (kr == kIOReturnSuccess) {
                *transferred = req.wLenDone;
                *path = CUSB_PATH_INTERFACE;
                IOObjectRelease(device);
                return kr;
            }
        }
    }

    IOReturn interface_kr = kr;
    IOUSBDeviceInterface **dev = NULL;
    kr = create_plugin(device, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID, (void ***)&dev);
    IOObjectRelease(device);
    if (kr != kIOReturnSuccess) return interface_kr;
    req.wLenDone = 0;
    kr = (*dev)->DeviceRequest(dev, &req);
    (*dev)->Release(dev);
    if (kr == kIOReturnSuccess) {
        *transferred = req.wLenDone;
        *path = CUSB_PATH_DEVICE;
        return kr;
    }
    // A stall on the device path usually means the camera rejected the request itself,
    // which is more informative than an interface-path open failure.
    return kr;
}
