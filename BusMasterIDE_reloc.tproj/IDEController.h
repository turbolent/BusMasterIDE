#ifndef _IDE_CONTROLLER_H_
#define _IDE_CONTROLLER_H_

#import <driverkit/IODirectDevice.h>
#import "IDE.h"
#import "ATAPIControllerPublic.h"

@interface IDEController:IODirectDevice
    <IDEControllerPublic, ATAPIControllerPublic>
{
@private
    BMIDERegs _regs[BMIDE_MAX_CHANNELS];
    BMIDEDriveInfo _drives[BMIDE_MAX_DRIVES];
    unsigned short _bmiba;
    void *_prdAlloc;
    unsigned int _prdAllocSize;
    BMIDEPrd *_prd;
    unsigned int _prdPhys;
    unsigned int _driveCount;
    unsigned int _atapiCount;
    unsigned int _diagDmaLogsLeft;
    id _cmdLock;
    unsigned int _dmaRetries;
    unsigned int _dmaTimeouts;
    unsigned int _dmaBmErrors;
    unsigned int _dmaAtaErrors;
    unsigned int _dmaResets;
}

+ (BOOL)probe:deviceDescription;
- (BOOL)scanController;
- (BOOL)buildPrdForBuffer:(void *)buffer
                   length:(unsigned int)length
                   client:(vm_task_t)client;

@end

#endif
