#ifndef _BMIDE_ATAPI_CONTROLLER_H_
#define _BMIDE_ATAPI_CONTROLLER_H_

#import <driverkit/scsiTypes.h>
#import <driverkit/IOSCSIController.h>
#import "ATAPIControllerCmds.h"

#ifndef MODSEL_DATA_LEN
#define MODSEL_DATA_LEN 512
#endif

typedef struct {
    unsigned char mdl1;
    unsigned char mdl0;
    unsigned char mt;
    unsigned char rsvd0;
    unsigned char rsvd1;
    unsigned char rsvd2;
    unsigned char rsvd3;
    unsigned char rsvd4;
} atapiMPH_t;

typedef struct {
    atapiMPH_t mph;
    unsigned char pageData[MODSEL_DATA_LEN * 2];
} atapiMPL_t;

@interface ATAPIController:IOSCSIController
{
@private
    id _ataController;
    atapiMPL_t modeData;
}

+ (BOOL)probe:deviceDescription;
+ (IODeviceStyle)deviceStyle;
+ (Protocol **)requiredProtocols;

- initResources:controller;
- (sc_status_t)executeRequest:(IOSCSIRequest *)scsiReq
                       buffer:(void *)buffer
                       client:(vm_task_t)client;
- (BOOL)maptoAtapiCmd:(atapiIoReq_t *)atapiIoReq
                buffer:(void *)buffer
                client:(vm_task_t)client
             newBuffer:(atapiMPL_t *)mode;
- (BOOL)maptoSCSICmd:(atapiIoReq_t *)atapiIoReq
               buffer:(void *)buffer
               client:(vm_task_t)client
            newBuffer:(atapiMPL_t *)mode;
- (BOOL)emulateSCSICmd:(atapiIoReq_t *)atapiIoReq
                buffer:(void *)buffer
                client:(vm_task_t)client;
- (sc_status_t)resetSCSIBus;

@end

#endif
