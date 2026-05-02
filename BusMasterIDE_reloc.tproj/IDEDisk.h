#ifndef _IDE_DISK_H_
#define _IDE_DISK_H_

#import <driverkit/IODisk.h>
#import <driverkit/kernelDiskMethods.h>
#import "IDE.h"

@interface IDEDisk:IODisk<IODiskReadingAndWriting, IOPhysicalDiskMethods>
{
@private
    id _controller;
    unsigned int _driveIndex;
}

+ (BOOL)probe:deviceDescription;
+ (IODeviceStyle)deviceStyle;
+ (Protocol **)requiredProtocols;
+ (BOOL)hd_devsw_init:deviceDescription;

- (BOOL)initDisk:(unsigned int)unit
      driveIndex:(unsigned int)driveIndex
      controller:controllerId;

@end

#endif
