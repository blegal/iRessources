// iRessources — SPDX-License-Identifier: GPL-3.0-or-later
//
// Temperature sensors through the IOHIDEventSystem client interface. On Apple
// silicon these are the only temperatures readable without root privileges.

#include "CSystem.h"
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kHIDPage_AppleVendor 0xff00
#define kHIDUsage_AppleVendor_TemperatureSensor 0x0005
#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)

static IOHIDEventSystemClientRef shared_client(void) {
    static IOHIDEventSystemClientRef client = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) return;
        int page = kHIDPage_AppleVendor, usage = kHIDUsage_AppleVendor_TemperatureSensor;
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
        const void *values[] = {p, u};
        CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(client, match);
        CFRelease(match);
        CFRelease(p);
        CFRelease(u);
    });
    return client;
}

int csys_read_temperatures(csys_temperature *out, int capacity) {
    IOHIDEventSystemClientRef client = shared_client();
    if (!client) return 0;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;

    int written = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && written < capacity; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(event);
        if (value <= 0 || value > 150) continue;

        CFStringRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        csys_temperature *t = &out[written];
        memset(t->name, 0, sizeof(t->name));
        if (name) {
            CFStringGetCString(name, t->name, sizeof(t->name), kCFStringEncodingUTF8);
            CFRelease(name);
        } else {
            strlcpy(t->name, "Sensor", sizeof(t->name));
        }
        t->celsius = value;
        written++;
    }
    CFRelease(services);
    return written;
}
