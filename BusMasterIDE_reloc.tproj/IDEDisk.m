#import "IDEDisk.h"
#import "IDEKernel.h"

#import <driverkit/devsw.h>
#import <driverkit/generalFuncs.h>
#import <driverkit/kernelDiskMethods.h>
#import <driverkit/IODevice.h>
#import <sys/errno.h>
#import <sys/systm.h>

static int bmideDiskUnit = 0;
static BOOL bmideSwitchTableInited = NO;
static int bmideProbedControllerCount = 0;
static id bmideProbedControllers[8];
static int bmideSyncIoLogsLeft = 0;

#define IDE_BLOCK_MAJOR 3
#define IDE_RAW_MAJOR   15

static int
ideDevswNoop()
{
    return 0;
}

static int
ideDevswUnsupported()
{
    return ENODEV;
}

static int
ideDevswMmapUnsupported()
{
    return -1;
}

static int
ideDevswSelectTrue()
{
    return 1;
}

@implementation IDEDisk

static Protocol *bmideProtocols[] = {
    @protocol(IDEControllerPublic),
    nil
};

+ (Protocol **)requiredProtocols
{
    return bmideProtocols;
}

+ (IODeviceStyle)deviceStyle
{
    return IO_IndirectDevice;
}

+ (BOOL)probe:deviceDescription
{
    id controllerId;
    id diskId;
    IODevAndIdInfo *idMap;
    int i;
    unsigned int driveIndex;

    controllerId = [deviceDescription directDevice];
    if (controllerId == nil)
        return NO;

    IOLog("IDE: disk probe for controller %08x\n",
          (unsigned int)controllerId);

    for (i = 0; i < bmideProbedControllerCount; i++) {
        if (bmideProbedControllers[i] == controllerId)
            return YES;
    }
    if (bmideProbedControllerCount < 8)
        bmideProbedControllers[bmideProbedControllerCount++] = controllerId;

    if ([self hd_devsw_init:deviceDescription] == NO) {
        IOLog("IDE: failed to add devsw entries\n");
        return NO;
    }

    idMap = bmide_idmap();
    for (driveIndex = 0; driveIndex < BMIDE_MAX_DRIVES; driveIndex++) {
        if ([controllerId drivePresentAtIndex:driveIndex] == NO)
            continue;
        if (bmideDiskUnit >= BMIDE_MAX_DRIVES) {
            IOLog("IDE: too many disks; drive %d skipped\n",
                  driveIndex);
            continue;
        }

        diskId = [[IDEDisk alloc]
            initFromDeviceDescription:deviceDescription];
        if (diskId == nil)
            continue;

        [diskId setDevAndIdInfo:&idMap[bmideDiskUnit]];
        if ([diskId initDisk:bmideDiskUnit
                  driveIndex:driveIndex
                  controller:controllerId] == NO) {
            [diskId free];
            continue;
        }

        [diskId setDeviceKind:"IDEDisk"];
        [diskId setIsPhysical:YES];
        [diskId registerDevice];
        bmideDiskUnit++;
    }

    return YES;
}

+ (BOOL)hd_devsw_init:deviceDescription
{
    int rawMajor;
    int blockMajor;

    if (bmideSwitchTableInited == YES)
        return YES;

    [self setBlockMajor:IDE_BLOCK_MAJOR];
    [self setCharacterMajor:IDE_RAW_MAJOR];

    rawMajor = IOAddToCdevswAt([self characterMajor],
                               (IOSwitchFunc)bmideopen,
                               (IOSwitchFunc)bmideclose,
                               (IOSwitchFunc)bmideread,
                               (IOSwitchFunc)bmidewrite,
                               (IOSwitchFunc)bmideioctl,
                               (IOSwitchFunc)ideDevswNoop,
                               (IOSwitchFunc)ideDevswNoop,
                               (IOSwitchFunc)ideDevswSelectTrue,
                               (IOSwitchFunc)ideDevswMmapUnsupported,
                               (IOSwitchFunc)ideDevswUnsupported,
                               (IOSwitchFunc)ideDevswUnsupported);
    if (rawMajor < 0)
        return NO;

    blockMajor = IOAddToBdevswAt([self blockMajor],
                                 (IOSwitchFunc)bmideopen,
                                 (IOSwitchFunc)bmideclose,
                                 (IOSwitchFunc)bmidestrategy,
                                 (IOSwitchFunc)ideDevswUnsupported,
                                 (IOSwitchFunc)bmidesize,
                                 FALSE);
    if (blockMajor < 0)
        return NO;

    bmide_init_idmap(self);
    bmideSwitchTableInited = YES;
    IOLog("IDE: devsw block major %d char major %d\n",
          [self blockMajor], [self characterMajor]);
    return YES;
}

- (BOOL)initDisk:(unsigned int)unit
      driveIndex:(unsigned int)driveIndex
      controller:controllerId
{
    char name[64];
    const char *model;
    unsigned int sectors;

    _controller = controllerId;
    _driveIndex = driveIndex;
    sectors = [_controller driveSectorCountAtIndex:_driveIndex];
    if (sectors == 0)
        return NO;

    model = [_controller driveModelAtIndex:_driveIndex];
    if (model == 0 || model[0] == '\0')
        sprintf(name, "BusMasterIDE DMA disk %d", unit);
    else
        sprintf(name, "BusMasterIDE DMA %s", model);

    [self setRemovable:NO];
    [self setBlockSize:BMIDE_SECTOR_SIZE];
    [self setDiskSize:sectors];
    [self setFormattedInternal:YES];
    [self setLastReadyState:IO_Ready];
    [self setDriveName:name];
    [super init];

    IOLog("IDE: registered disk unit %d drive %d, %u sectors\n",
          unit, driveIndex, sectors);
    return YES;
}

- (IOReturn)rwCommon:(BOOL)isWrite
              offset:(unsigned int)offset
              length:(unsigned int)length
              buffer:(unsigned char *)buffer
              client:(vm_task_t)client
              pending:(void *)pending
              actual:(unsigned int *)actualLength
{
    IOReturn rtn;
    unsigned int blockSize;
    unsigned int diskSize;
    unsigned int sectors;
    unsigned int actual;

    sectors = 0;
    actual = 0;
    if (actualLength != 0)
        *actualLength = 0;

    rtn = [self isDiskReady:NO];
    switch (rtn) {
      case IO_R_SUCCESS:
        break;
      case IO_R_NO_DISK:
        goto done;
      default:
        IOLog("IDE: disk ready check failed drive %d rtn %d\n",
              _driveIndex, rtn);
        goto done;
    }

    blockSize = [self blockSize];
    diskSize = [self diskSize];
    if (pending == 0 && bmideSyncIoLogsLeft > 0) {
        IOLog("IDE: sync %s drive %d block %u length %u buf %08x client %08x blockSize %u diskSize %u\n",
              isWrite ? "write" : "read", _driveIndex, offset, length,
              (unsigned int)buffer, (unsigned int)client, blockSize,
              diskSize);
        bmideSyncIoLogsLeft--;
    }
    if (blockSize == 0)
        rtn = IO_R_INVALID_ARG;
    else if ((length % blockSize) != 0)
        rtn = IO_R_INVALID;
    else {
        sectors = length / blockSize;
        if ((offset + sectors) > diskSize) {
            if (offset >= diskSize)
                rtn = IO_R_INVALID_ARG;
            else
                sectors = diskSize - offset;
        }
        if (rtn == IO_R_SUCCESS) {
            if (sectors == 0)
                actual = 0;
            else if (sectors > BMIDE_MAX_SECTORS_IO)
                rtn = IO_R_INVALID_ARG;
            else
                rtn = [_controller dmaTransferDrive:_driveIndex
                                                lba:offset
                                        sectorCount:sectors
                                             buffer:buffer
                                             client:client
                                            isWrite:isWrite
                                             actual:&actual];
        }
    }

    if (rtn != IO_R_SUCCESS)
        IOLog("IDE: disk I/O failed drive %d %s block %u length %u rtn %d\n",
              _driveIndex, isWrite ? "write" : "read", offset, length, rtn);

    if (rtn == IO_R_SUCCESS) {
        if (isWrite)
            [self addToBytesWritten:actual totalTime:0 latentTime:0];
        else
            [self addToBytesRead:actual totalTime:0 latentTime:0];
    } else {
        if (isWrite)
            [self incrementWriteErrors];
        else
            [self incrementReadErrors];
    }

done:
    if (rtn == IO_R_SUCCESS && actualLength != 0)
        *actualLength = actual;
    if (pending != 0) {
        [self completeTransfer:pending withStatus:rtn
                   actualLength:(rtn == IO_R_SUCCESS) ? actual : 0];
        return IO_R_SUCCESS;
    }

    return rtn;
}

- (IOReturn)readAt:(unsigned int)offset
            length:(unsigned int)length
            buffer:(unsigned char *)buffer
      actualLength:(unsigned int *)actualLength
            client:(vm_task_t)client
{
    return [self rwCommon:NO offset:offset length:length buffer:buffer
                  client:client pending:0 actual:actualLength];
}

- (IOReturn)readAsyncAt:(unsigned int)offset
                 length:(unsigned int)length
                 buffer:(unsigned char *)buffer
                pending:(void *)pending
                 client:(vm_task_t)client
{
    return [self rwCommon:NO offset:offset length:length buffer:buffer
                  client:client pending:pending actual:0];
}

- (IOReturn)writeAt:(unsigned int)offset
             length:(unsigned int)length
             buffer:(unsigned char *)buffer
       actualLength:(unsigned int *)actualLength
             client:(vm_task_t)client
{
    return [self rwCommon:YES offset:offset length:length buffer:buffer
                  client:client pending:0 actual:actualLength];
}

- (IOReturn)writeAsyncAt:(unsigned int)offset
                  length:(unsigned int)length
                  buffer:(unsigned char *)buffer
                 pending:(void *)pending
                  client:(vm_task_t)client
{
    return [self rwCommon:YES offset:offset length:length buffer:buffer
                  client:client pending:pending actual:0];
}

- (IOReturn)updatePhysicalParameters
{
    return IO_R_SUCCESS;
}

- (void)abortRequest
{
}

- (void)diskBecameReady
{
}

- (IOReturn)isDiskReady:(BOOL)prompt
{
    return IO_R_SUCCESS;
}

- (IOReturn)ejectPhysical
{
    return IO_R_UNSUPPORTED;
}

- (IODiskReadyState)updateReadyState
{
    return [self lastReadyState];
}

- (int)deviceOpen:(u_int)intentions
{
    return 0;
}

- (void)deviceClose
{
    return;
}

- (IOReturn)getIntValues:(unsigned int *)values
            forParameter:(IOParameterName)parameter
                   count:(unsigned int *)count
{
    int maxCount;
    int blockMajor;
    int characterMajor;

    maxCount = *count;
    if (maxCount == 0)
        maxCount = IO_MAX_PARAMETER_ARRAY_LENGTH;

    if (strcmp(parameter, "BlockMajor") == 0) {
        bmide_block_char_majors(&blockMajor, &characterMajor);
        values[0] = blockMajor;
        *count = 1;
        return IO_R_SUCCESS;
    }
    if (strcmp(parameter, "CharacterMajor") == 0) {
        bmide_block_char_majors(&blockMajor, &characterMajor);
        values[0] = characterMajor;
        *count = 1;
        return IO_R_SUCCESS;
    }

    return [super getIntValues:values forParameter:parameter
                         count:&maxCount];
}

- property_IOUnit:(char *)result length:(unsigned int *)maxLen
{
    sprintf(result, "%d", _driveIndex);
    return self;
}

@end
