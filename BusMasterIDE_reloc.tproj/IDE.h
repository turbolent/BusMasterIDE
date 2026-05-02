#ifndef _IDE_H_
#define _IDE_H_

#import <driverkit/return.h>
#import <driverkit/driverTypes.h>
#import <driverkit/IODisk.h>
#import <driverkit/kernelDriver.h>
#import <mach/mach_types.h>

#define BMIDE_MAX_CHANNELS     2
#define BMIDE_MAX_DRIVES       4
#define BMIDE_DRIVES_PER_CHAN  2

#define BMIDE_SECTOR_SIZE      512
#define BMIDE_MAX_SECTORS_IO   256
#define BMIDE_MAX_PHYS_IO      (BMIDE_MAX_SECTORS_IO * BMIDE_SECTOR_SIZE)

#define BMIDE_LIVE_PART        7
#define BMIDE_NUM_PART         8

typedef struct {
    unsigned short data;
    unsigned short error;
    unsigned short sectorCount;
    unsigned short lbaLow;
    unsigned short lbaMid;
    unsigned short lbaHigh;
    unsigned short device;
    unsigned short status;
    unsigned short command;
    unsigned short altStatus;
    unsigned short deviceControl;
} BMIDERegs;

typedef struct {
    unsigned long base;
    unsigned short count;
    unsigned short flags;
} BMIDEPrd;

typedef struct {
    BOOL present;
    BOOL atapiPresent;
    BOOL dmaSupported;
    BOOL lbaSupported;
    unsigned int channel;
    unsigned int drive;
    unsigned int sectors;
    unsigned char atapiCmdLen;
    unsigned char atapiCmdDrqType;
    unsigned char atapiDeviceType;
    char model[42];
} BMIDEDriveInfo;

@protocol IDEControllerPublic
- (BOOL)drivePresentAtIndex:(unsigned int)index;
- (unsigned int)driveSectorCountAtIndex:(unsigned int)index;
- (const char *)driveModelAtIndex:(unsigned int)index;
- (IOReturn)dmaTransferDrive:(unsigned int)index
                         lba:(unsigned int)lba
                 sectorCount:(unsigned int)sectors
                      buffer:(void *)buffer
                      client:(vm_task_t)client
                     isWrite:(BOOL)isWrite
                      actual:(unsigned int *)actual;
@end

#endif
