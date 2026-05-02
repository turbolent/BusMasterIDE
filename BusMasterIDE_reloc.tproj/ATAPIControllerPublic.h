#ifdef DRIVER_PRIVATE

#ifndef _BMIDE_ATAPI_CONTROLLER_PUBLIC_H_
#define _BMIDE_ATAPI_CONTROLLER_PUBLIC_H_

#import <driverkit/return.h>
#import <driverkit/driverTypes.h>
#import <driverkit/IODevice.h>
#import <driverkit/kernelDriver.h>
#import <mach/mach_types.h>

@protocol ATAPIControllerPublic
- (unsigned int)numDevices;
- (BOOL)isAtapiDevice:(unsigned char)unit;
@end

#endif

#endif DRIVER_PRIVATE
