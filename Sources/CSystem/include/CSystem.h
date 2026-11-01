// iRessources — SPDX-License-Identifier: GPL-3.0-or-later
//
// Declarations for the few Darwin interfaces that are exported by the system
// but not described by a public header (IOReport, HID event services, process
// responsibility). They are the same entry points used by Activity Monitor,
// powermetrics and similar tools.

#ifndef CSYSTEM_H
#define CSYSTEM_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <sys/types.h>

// MARK: - IOReport (libIOReport.dylib)

typedef struct __IOReportSubscriptionCF *IOReportSubscriptionRef;

CFDictionaryRef _Nullable IOReportCopyChannelsInGroup(CFStringRef _Nullable group, CFStringRef _Nullable subgroup,
                                                      uint64_t a, uint64_t b, uint64_t c) CF_RETURNS_RETAINED;
void IOReportMergeChannels(CFDictionaryRef _Nonnull a, CFDictionaryRef _Nonnull b, CFTypeRef _Nullable unused);
IOReportSubscriptionRef _Nullable IOReportCreateSubscription(void *_Nullable a, CFMutableDictionaryRef _Nonnull channels,
                                                             CFMutableDictionaryRef _Nullable *_Nonnull subscribed,
                                                             uint64_t channelID, CFTypeRef _Nullable b) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamples(IOReportSubscriptionRef _Nonnull sub, CFMutableDictionaryRef _Nonnull subscribed,
                                                CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamplesDelta(CFDictionaryRef _Nonnull previous, CFDictionaryRef _Nonnull current,
                                                     CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFStringRef _Nullable IOReportChannelGetGroup(CFDictionaryRef _Nonnull item) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetSubGroup(CFDictionaryRef _Nonnull item) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetChannelName(CFDictionaryRef _Nonnull item) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetUnitLabel(CFDictionaryRef _Nonnull item) CF_RETURNS_NOT_RETAINED;
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef _Nonnull item, int32_t index);
int32_t IOReportStateGetCount(CFDictionaryRef _Nonnull item);
CFStringRef _Nullable IOReportStateGetNameForIndex(CFDictionaryRef _Nonnull item, int32_t index) CF_RETURNS_NOT_RETAINED;
int64_t IOReportStateGetResidency(CFDictionaryRef _Nonnull item, int32_t index);

// MARK: - Process responsibility (libquarantine)

/// Returns the pid of the process "responsible" for `pid` (e.g. Safari for its
/// WebContent helpers). This is what Activity Monitor uses to group processes.
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

// MARK: - Temperature sensors (IOHIDEventSystem)

typedef struct {
    char name[96];
    double celsius;
} csys_temperature;

/// Fills `out` with up to `capacity` temperature sensors. Returns the number
/// of sensors written. Safe to call from any thread.
int csys_read_temperatures(csys_temperature *_Nonnull out, int capacity);

#endif
