#ifndef CODISKSMART_H
#define CODISKSMART_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

/// Reads the NVMe SMART / Health log page (02h, 512 bytes) and the Identify Controller
/// structure (4096 bytes) from a service that has "NVMe SMART Capable" = true.
/// The COM plug-in calls live in C because Swift can't drive IUnknown vtables cleanly.
/// Returns KERN_SUCCESS (0) or the failing IOKit status. `identify` may be NULL.
int odisk_nvme_read(io_service_t service, uint8_t *smartLog512, uint8_t *identify4096);

#endif
