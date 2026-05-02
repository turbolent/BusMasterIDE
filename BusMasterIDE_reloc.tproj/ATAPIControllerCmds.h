#ifndef _BMIDE_ATAPI_CONTROLLER_CMDS_H_
#define _BMIDE_ATAPI_CONTROLLER_CMDS_H_

#import "atapi_extern.h"
#import "IDEController.h"
#import <driverkit/scsiTypes.h>
#import <mach/mach_types.h>

#define MAX_ATAPI_CMD_LEN 16

typedef struct {
    unsigned char drive;
    unsigned char lun;
    unsigned char atapiCmd[MAX_ATAPI_CMD_LEN];
    unsigned char scsiCmd;
    unsigned char cmdLen;
    unsigned int maxTransfer;
    BOOL read;
    unsigned int bytesTransferred;
    unsigned char scsiStatus;
} atapiIoReq_t;

@interface IDEController(ATAPI)
- (unsigned char)atapiCommandPacketSize:(unsigned char)unit;
- (atapi_return_t)atapiSoftReset:(unsigned char)unit;
- (atapi_return_t)_atapiIdentifyDevice:(vm_task_t)client
                                  addr:(caddr_t)xferAddr
                                  unit:(unsigned char)unit;
- (atapi_return_t)atapiIdentifyDevice:(vm_task_t)client
                                 addr:(caddr_t)xferAddr
                                 unit:(unsigned char)unit;
- (void)atapiInitParameters:(unsigned short *)identify
                     Device:(unsigned char)unit;
- (atapi_return_t)atapiWaitStatusBitsFor:(unsigned int)timeout
                                      on:(unsigned char)on
                                     off:(unsigned char)off
                                     alt:(BOOL)alt
                                    unit:(unsigned char)unit
                                  status:(unsigned char *)status;
- (BOOL)xferData:(caddr_t)xferAddr
            read:(BOOL)read
          client:(vm_task_t)client
          length:(unsigned int)length
            unit:(unsigned char)unit;
- (atapi_return_t)issuePacketCommandForUnit:(unsigned char)unit;
- (void)sendAtapiCommand:(unsigned char *)atapiCmd
                  cmdLen:(unsigned char)len
                    unit:(unsigned char)unit;
- (sc_status_t)atapiPIODataTransfer:(atapiIoReq_t *)atapiIoReq
                              buffer:(void *)buffer
                              client:(vm_task_t)client;
- (void)dumpStatus:(atapiIoReq_t *)atapiIoReq;
- (sc_status_t)performATAPIDMA:(atapiIoReq_t *)atapiIoReq
                         buffer:(void *)buffer
                         client:(vm_task_t)client;
- (sc_status_t)atapiExecuteCmd:(atapiIoReq_t *)atapiIoReq
                         buffer:(void *)buffer
                         client:(vm_task_t)client;
- (void)atapiControllerLock;
- (void)atapiControllerUnlock;
- (void)getAtapiRegistersForUnit:(unsigned char)unit
                           Print:(char *)printString;
- (void)logAtapiDevice:(unsigned char)unit;
@end

#endif
