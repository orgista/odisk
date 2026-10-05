#include "CODiskSMART.h"
#include <string.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

// Public UUIDs from NVMeSMARTLibExternal.h (IOKit storage family).
#define ODISK_NVME_SMART_UC_TYPE CFUUIDGetConstantUUIDWithBytes(NULL, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
#define ODISK_NVME_SMART_IFACE   CFUUIDGetConstantUUIDWithBytes(NULL, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

typedef struct {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*SMARTReadData)(void *self, void *data);
    IOReturn (*GetIdentifyData)(void *self, void *data, unsigned int nsid);
    IOReturn (*GetFieldCounters)(void *self, char *buffer);
    IOReturn (*ScheduleBGRefresh)(void *self);
    IOReturn (*GetLogPage)(void *self, void *data, unsigned int logPageId, unsigned int numDWords);
} ODiskNVMeSMARTInterface;

int odisk_nvme_read(io_service_t service, uint8_t *smartLog512, uint8_t *identify4096) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, ODISK_NVME_SMART_UC_TYPE,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        return kr != KERN_SUCCESS ? kr : kIOReturnError;
    }
    ODiskNVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(ODISK_NVME_SMART_IFACE), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return kIOReturnUnsupported;
    }
    memset(smartLog512, 0, 512);
    IOReturn result = (*smart)->SMARTReadData(smart, smartLog512);
    if (result == kIOReturnSuccess && identify4096 != NULL) {
        memset(identify4096, 0, 4096);
        if ((*smart)->GetIdentifyData(smart, identify4096, 0) != kIOReturnSuccess) {
            memset(identify4096, 0, 4096);
        }
    }
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    return result;
}
