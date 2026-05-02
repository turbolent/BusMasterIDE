#ifndef _BMIDE_ATAPI_EXTERN_H_
#define _BMIDE_ATAPI_EXTERN_H_

#ifdef DRIVER_PRIVATE

#import <mach/boolean.h>

#define ATAPI_DEVICE_DIRECT_ACCESS     0x00
#define ATAPI_DEVICE_TAPE              0x01
#define ATAPI_DEVICE_CD_ROM            0x05
#define ATAPI_DEVICE_OPTICAL           0x07

#define ATAPI_PACKET                   0xa0
#define ATAPI_IDENTIFY_DRIVE           0xa1
#define ATAPI_SOFT_RESET               0x08

typedef int atapi_return_t;

#define ATAPI_R_SUCCESS                0
#define ATAPI_R_TIMEOUT                1
#define ATAPI_R_ERROR                  13

#define ATAPI_IO_DIRECTION             0x02
#define ATAPI_CMD_OR_DATA              0x01

typedef struct _atapiGenConfig {
    unsigned short
        cmdPacketSize:2,
        rsvd1:3,
        cmdDrqType:2,
        removable:1,
        deviceType:5,
        rsvd2:1,
        protocolType:2;
} atapiGenConfig_t;

#endif DRIVER_PRIVATE

#endif
