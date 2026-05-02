#import "ATAPIController.h"
#import "ATAPIControllerPublic.h"

#import <driverkit/kernelDriver.h>
#import <driverkit/IODevice.h>
#import <driverkit/generalFuncs.h>
#import <driverkit/return.h>
#import <kernserv/prototypes.h>
#import <bsd/dev/scsireg.h>
#import <sys/systm.h>

#define SCSI_OPGROUP(opcode)    ((opcode) & 0xe0)
#define OPGROUP_0               0x00
#define OPGROUP_1               0x20
#define OPGROUP_2               0x40
#define OPGROUP_5               0xa0
#define OPGROUP_6               0xc0
#define OPGROUP_7               0xe0

#define C10OP_MODESELECT        0x55
#define C10OP_MODESENSE         0x5a
#define C10OP_READCAPACITY      0x25
#define SCSI_TEST_UNIT_READY    0x00
#define SCSI_DEVICE_TYPE_MASK   0x1f
#define SCSI_REMOVABLE_MASK     0x80
#define SCSI_INQUIRY_LOG_BYTES  8

#define MPH_SCSI_6_SIZE         sizeof(mode_sel_hdr_t)
#define MPH_SCSI_10_SIZE        8
#define MPH_ATAPI_SIZE          sizeof(atapiMPH_t)
#define MPH_DELTA               (MPH_ATAPI_SIZE - MPH_SCSI_6_SIZE)

#define ATAPI_PAGE_SIZE         4096
#define ATAPI_PAGE_MASK         (ATAPI_PAGE_SIZE - 1)
#define ATAPI_CD_BLOCK_SIZE     2048
#define ATAPI_MODE_PAGE_MASK    0x1f
#define ATAPI_MODE_PAGE_2       0x02
#define ATAPI_BYTE_MASK         0xff

#ifndef IOClassATAPIController
#define IOClassATAPIController  "ATAPIController"
#endif
#ifndef IOTypeATAPI
#define IOTypeATAPI             "ATAPI"
#endif

static const unsigned char mapToAtapi[] = {
    C6OP_MODESELECT,
    C10OP_MODESELECT,
    C6OP_MODESENSE
};

#define ATAPI_MAPPED_CMD_COUNT  (sizeof(mapToAtapi) / sizeof(mapToAtapi[0]))
#define ATAPI_MAX_PROBED_CONTROLLERS   8

static int probedControllerCount = 0;
static id probedControllers[ATAPI_MAX_PROBED_CONTROLLERS];

static BOOL
atapiCommandNeedsMapping(unsigned char command)
{
    int i;

    for (i = 0; i < ATAPI_MAPPED_CMD_COUNT; i++) {
        if (command == mapToAtapi[i])
            return YES;
    }
    return NO;
}

static void
atapiLogFailedRequest(atapiIoReq_t *req, sc_status_t ret)
{
    if (ret == SR_IOST_GOOD && req->scsiStatus == STAT_GOOD)
        return;
    if (req->scsiCmd == SCSI_TEST_UNIT_READY && ret == SR_IOST_CHKSNV &&
        req->scsiStatus == STAT_CHECK)
        return;

    IOLog("ATAPI: SCSI failed op %02x target %d lun %d ret %d scsi %02x "
          "bytes %d max %d read %d\n",
          req->scsiCmd, req->drive, req->lun, ret, req->scsiStatus,
          req->bytesTransferred, req->maxTransfer, req->read);
}

typedef struct {
    caddr_t addr;
    vm_address_t mappedPage;
    BOOL mapped;
} atapiMappedBuffer_t;

static BOOL
atapiMapClientBuffer(vm_task_t client, void *buffer, unsigned int length,
                     atapiMappedBuffer_t *mapped)
{
    vm_address_t virt;
    unsigned int phys;
    unsigned int pageOffset;
    IOReturn rtn;

    mapped->addr = (caddr_t)buffer;
    mapped->mappedPage = 0;
    mapped->mapped = NO;

    if (length == 0)
        return YES;
    if (buffer == 0)
        return NO;
    if (client == 0 || client == IOVmTaskSelf())
        return YES;

    virt = (vm_address_t)buffer;
    pageOffset = virt & ATAPI_PAGE_MASK;
    if (pageOffset + length > ATAPI_PAGE_SIZE) {
        IOLog("ATAPI: small buffer crosses page VA %08x len %u client %08x\n",
              (unsigned int)virt, length, (unsigned int)client);
        return NO;
    }

    rtn = IOPhysicalFromVirtual(client, virt, &phys);
    if (rtn != IO_R_SUCCESS) {
        IOLog("ATAPI: cannot translate small buffer VA %08x client %08x\n",
              (unsigned int)virt, (unsigned int)client);
        return NO;
    }

    rtn = IOMapPhysicalIntoIOTask(phys & ~ATAPI_PAGE_MASK, ATAPI_PAGE_SIZE,
                                  &mapped->mappedPage);
    if (rtn != IO_R_SUCCESS) {
        IOLog("ATAPI: cannot map small buffer phys %08x rtn %d\n",
              phys & ~ATAPI_PAGE_MASK, rtn);
        return NO;
    }

    mapped->addr = (caddr_t)(mapped->mappedPage + (phys & ATAPI_PAGE_MASK));
    mapped->mapped = YES;
    return YES;
}

static void
atapiUnmapClientBuffer(atapiMappedBuffer_t *mapped)
{
    if (mapped->mapped)
        IOUnmapPhysicalFromIOTask(mapped->mappedPage, ATAPI_PAGE_SIZE);
}

static unsigned int
atapiReadU32BE(unsigned char *buf)
{
    return ((unsigned int)buf[0] << 24) |
        ((unsigned int)buf[1] << 16) |
        ((unsigned int)buf[2] << 8) |
        (unsigned int)buf[3];
}

static void
atapiWriteU32BE(unsigned char *buf, unsigned int value)
{
    buf[0] = (value >> 24) & ATAPI_BYTE_MASK;
    buf[1] = (value >> 16) & ATAPI_BYTE_MASK;
    buf[2] = (value >> 8) & ATAPI_BYTE_MASK;
    buf[3] = value & ATAPI_BYTE_MASK;
}

static void
atapiLogInterestingSuccess(atapiIoReq_t *req, void *buffer, vm_task_t client)
{
    unsigned char *buf;
    unsigned int length;
    atapiMappedBuffer_t mapped;

    switch (req->scsiCmd) {
      case C6OP_INQUIRY:
        length = req->bytesTransferred;
        if (length < SCSI_INQUIRY_LOG_BYTES)
            length = SCSI_INQUIRY_LOG_BYTES;
        if (atapiMapClientBuffer(client, buffer, length, &mapped) == NO)
            return;
        buf = (unsigned char *)mapped.addr;
        IOLog("ATAPI: INQUIRY unit %d type %02x rmb %02x "
              "version %02x fmt %02x bytes %d\n",
              req->drive, buf[0] & SCSI_DEVICE_TYPE_MASK,
              buf[1] & SCSI_REMOVABLE_MASK, buf[2],
              buf[3], req->bytesTransferred);
        atapiUnmapClientBuffer(&mapped);
        break;

      case C10OP_READCAPACITY:
        if (atapiMapClientBuffer(client, buffer, 8, &mapped) == NO)
            return;
        buf = (unsigned char *)mapped.addr;
        IOLog("ATAPI: READ CAPACITY unit %d lastLBA %u blockSize %u "
              "raw %02x %02x %02x %02x %02x %02x %02x %02x\n",
              req->drive, atapiReadU32BE(buf), atapiReadU32BE(buf + 4),
              buf[0], buf[1], buf[2], buf[3],
              buf[4], buf[5], buf[6], buf[7]);
        atapiUnmapClientBuffer(&mapped);
        break;

      case C6OP_STARTSTOP:
        IOLog("ATAPI: START STOP unit %d loej %d start %d raw %02x\n",
              req->drive, (req->atapiCmd[4] >> 1) & 1,
              req->atapiCmd[4] & 1, req->atapiCmd[4]);
        break;
    }
}

@implementation ATAPIController

+ (BOOL)probe:deviceDescription
{
    int unit;
    int i;
    id direct;
    id atapiController;

    direct = [deviceDescription directDevice];
    if (direct == nil)
        return NO;

    for (i = 0; i < probedControllerCount; i++) {
        if (probedControllers[i] == direct)
            return YES;
    }
    if (probedControllerCount < ATAPI_MAX_PROBED_CONTROLLERS)
        probedControllers[probedControllerCount++] = direct;

    for (unit = 0; unit < [direct numDevices]; unit++) {
        if ([direct isAtapiDevice:unit]) {
            atapiController = [[self alloc]
                initFromDeviceDescription:deviceDescription];
            if (atapiController == nil) {
                IOLog("ATAPI: failed to probe device %d\n", unit);
                continue;
            }
            if ([atapiController initResources:direct] == nil) {
                IOLog("ATAPI: failed to initialize device %d\n", unit);
                [atapiController free];
                continue;
            }
            if ([atapiController registerDevice] == nil) {
                IOLog("ATAPI: failed to register device %d\n", unit);
                [atapiController free];
                continue;
            }
            IOLog("ATAPI: registered SCSI controller for IDE ATAPI devices\n");
            return YES;
        }
    }
    return NO;
}

+ (IODeviceStyle)deviceStyle
{
    return IO_IndirectDevice;
}

static Protocol *protocols[] = {
    @protocol(ATAPIControllerPublic),
    nil
};

+ (Protocol **)requiredProtocols
{
    return protocols;
}

- initResources:controller
{
    _ataController = controller;
    return self;
}

- (int)numberOfTargets
{
    return [_ataController numDevices];
}

- (unsigned short)scsiCmdLen:(IOSCSIRequest *)scsiReq
{
    unsigned char cmdlen;
    union cdb *cdbp = &scsiReq->cdb;

    switch (SCSI_OPGROUP(cdbp->cdb_opcode)) {
      case OPGROUP_0:
        cmdlen = sizeof(struct cdb_6);
        break;
      case OPGROUP_1:
      case OPGROUP_2:
        cmdlen = sizeof(struct cdb_10);
        break;
      case OPGROUP_5:
        cmdlen = sizeof(struct cdb_12);
        break;
      case OPGROUP_6:
        cmdlen = scsiReq->cdbLength ? scsiReq->cdbLength :
            sizeof(struct cdb_6);
        break;
      case OPGROUP_7:
        cmdlen = scsiReq->cdbLength ? scsiReq->cdbLength :
            sizeof(struct cdb_10);
        break;
      default:
        scsiReq->driverStatus = SR_IOST_CMDREJ;
        return 0;
    }
    return cmdlen;
}

- (sc_status_t)executeRequest:(IOSCSIRequest *)scsiReq
                       buffer:(void *)buffer
                       client:(vm_task_t)client
{
    int i;
    atapiIoReq_t atapiIoReq;
    unsigned char *scsiCmd;
    cdb_t my_cdb;
    sc_status_t ret;
    sc_status_t driverStatus;
    BOOL cmdMapped;
    unsigned short cmdLen;

    if (scsiReq == 0)
        return SR_IOST_CMDREJ;

    [_ataController atapiControllerLock];

    my_cdb = scsiReq->cdb;
    bzero(&atapiIoReq, sizeof(atapiIoReq_t));

    atapiIoReq.cmdLen = [_ataController
        atapiCommandPacketSize:scsiReq->target];
    atapiIoReq.read = scsiReq->read;
    atapiIoReq.maxTransfer = scsiReq->maxTransfer;
    atapiIoReq.drive = scsiReq->target;
    atapiIoReq.lun = scsiReq->lun;

    scsiCmd = (unsigned char *)&(my_cdb.cdb_opcode);
    atapiIoReq.scsiCmd = *scsiCmd;

    cmdLen = [self scsiCmdLen:scsiReq];
    for (i = 0; i < cmdLen; i++)
        atapiIoReq.atapiCmd[i] = scsiCmd[i];

    cmdMapped = NO;
    if (atapiCommandNeedsMapping(atapiIoReq.atapiCmd[0])) {
        bzero(&modeData, sizeof(modeData));
        if ([self maptoAtapiCmd:&atapiIoReq buffer:buffer
                         client:client
                      newBuffer:&modeData] == NO) {
            scsiReq->driverStatus = SR_IOST_CMDREJ;
            scsiReq->scsiStatus = STAT_CHECK;
            atapiIoReq.scsiStatus = STAT_CHECK;
            atapiLogFailedRequest(&atapiIoReq, SR_IOST_CMDREJ);
            [_ataController atapiControllerUnlock];
            return SR_IOST_CMDREJ;
        }
        cmdMapped = YES;
    }

    if ([self emulateSCSICmd:&atapiIoReq buffer:buffer client:client] == YES) {
        scsiReq->bytesTransferred = atapiIoReq.bytesTransferred;
        scsiReq->scsiStatus = atapiIoReq.scsiStatus;
        scsiReq->driverStatus = SR_IOST_GOOD;
        atapiLogInterestingSuccess(&atapiIoReq, buffer, client);
        [_ataController atapiControllerUnlock];
        return SR_IOST_GOOD;
    }

    if (cmdMapped)
        ret = [_ataController atapiExecuteCmd:&atapiIoReq
                                       buffer:&modeData
                                       client:IOVmTaskSelf()];
    else
        ret = [_ataController atapiExecuteCmd:&atapiIoReq
                                       buffer:buffer
                                       client:client];
    driverStatus = ret;

    if (driverStatus == SR_IOST_GOOD) {
        if (atapiCommandNeedsMapping(atapiIoReq.scsiCmd)) {
            if ([self maptoSCSICmd:&atapiIoReq buffer:buffer
                            client:client
                         newBuffer:&modeData] == NO) {
                driverStatus = SR_IOST_CMDREJ;
                scsiReq->driverStatus = driverStatus;
                scsiReq->scsiStatus = STAT_CHECK;
                atapiIoReq.scsiStatus = STAT_CHECK;
                atapiLogFailedRequest(&atapiIoReq, driverStatus);
                [_ataController atapiControllerUnlock];
                return driverStatus;
            }
        }
    }

    if ((driverStatus == SR_IOST_GOOD) &&
        (atapiIoReq.scsiStatus == STAT_GOOD) &&
        (atapiIoReq.atapiCmd[0] == C10OP_READCAPACITY) &&
        (atapiIoReq.lun == 0) && buffer != 0) {
        unsigned int blockSize;
        unsigned int value;
        unsigned char *buf;
        atapiMappedBuffer_t mapped;

        if (atapiMapClientBuffer(client, buffer, 8, &mapped) == NO) {
            driverStatus = SR_IOST_HW;
            scsiReq->driverStatus = driverStatus;
            scsiReq->scsiStatus = STAT_CHECK;
            atapiIoReq.scsiStatus = STAT_CHECK;
            atapiLogFailedRequest(&atapiIoReq, driverStatus);
            [_ataController atapiControllerUnlock];
            return driverStatus;
        }

        buf = (unsigned char *)mapped.addr;
        blockSize = atapiReadU32BE(buf + 4);
        if (blockSize == 0)
            blockSize = ATAPI_CD_BLOCK_SIZE;
        for (value = 16; value < blockSize; value *= 2)
            ;
        if (value > blockSize) {
            blockSize = value / 2;
            atapiWriteU32BE(buf + 4, blockSize);
        }
        atapiUnmapClientBuffer(&mapped);
    }

    scsiReq->bytesTransferred = atapiIoReq.bytesTransferred;
    scsiReq->scsiStatus = atapiIoReq.scsiStatus;
    scsiReq->driverStatus = driverStatus;
    if (ret == SR_IOST_GOOD && atapiIoReq.scsiStatus == STAT_GOOD)
        atapiLogInterestingSuccess(&atapiIoReq, buffer, client);
    atapiLogFailedRequest(&atapiIoReq, ret);

    [_ataController atapiControllerUnlock];
    return ret;
}

- (BOOL)maptoAtapiCmd:(atapiIoReq_t *)atapiIoReq
                buffer:(void *)buffer
                client:(vm_task_t)client
             newBuffer:(atapiMPL_t *)mode
{
    int i;
    int pageLength;
    int bd_len;
    int page_start;
    int hdr_size;
    int maxTransfer;
    unsigned char *data;
    atapiMappedBuffer_t mapped;

    if (atapiIoReq->scsiCmd == C6OP_MODESENSE) {
        if ((atapiIoReq->atapiCmd[4] + MPH_DELTA) > sizeof(atapiMPL_t))
            return NO;
        atapiIoReq->atapiCmd[0] = C10OP_MODESENSE;
        atapiIoReq->atapiCmd[8] = atapiIoReq->atapiCmd[4] + MPH_DELTA;
        atapiIoReq->atapiCmd[4] = 0;
        atapiIoReq->atapiCmd[5] = 0;
        atapiIoReq->maxTransfer += MPH_DELTA;
        return YES;
    }

    if ((atapiIoReq->scsiCmd == C6OP_MODESELECT) ||
        (atapiIoReq->scsiCmd == C10OP_MODESELECT)) {
        if (atapiIoReq->maxTransfer == 0)
            return NO;
        if (atapiMapClientBuffer(client, buffer, atapiIoReq->maxTransfer,
                                 &mapped) == NO)
            return NO;
        data = (unsigned char *)mapped.addr;
        if (atapiIoReq->scsiCmd == C6OP_MODESELECT) {
            atapiIoReq->atapiCmd[0] = C10OP_MODESELECT;
            atapiIoReq->atapiCmd[4] = 0;
            atapiIoReq->atapiCmd[5] = 0;
            bd_len = data[3];
            hdr_size = MPH_SCSI_6_SIZE;
        } else {
            atapiIoReq->atapiCmd[9] = 0;
            bd_len = (data[6] << 8) | data[7];
            hdr_size = MPH_SCSI_10_SIZE;
        }

        page_start = hdr_size + bd_len;
        if ((page_start + 2) > atapiIoReq->maxTransfer) {
            atapiUnmapClientBuffer(&mapped);
            return NO;
        }
        pageLength = data[page_start + 1] + 2;
        if (pageLength > MODSEL_DATA_LEN ||
            (page_start + pageLength) > atapiIoReq->maxTransfer) {
            atapiUnmapClientBuffer(&mapped);
            return NO;
        }
        for (i = 0; i < pageLength; i++)
            mode->pageData[i] = data[page_start + i];
        atapiUnmapClientBuffer(&mapped);

        maxTransfer = pageLength + MPH_ATAPI_SIZE;
        atapiIoReq->atapiCmd[8] = maxTransfer & ATAPI_BYTE_MASK;
        atapiIoReq->atapiCmd[7] = (maxTransfer >> 8) & ATAPI_BYTE_MASK;
        atapiIoReq->maxTransfer = maxTransfer;
    }

    return YES;
}

- (BOOL)maptoSCSICmd:(atapiIoReq_t *)atapiIoReq
               buffer:(void *)buffer
               client:(vm_task_t)client
            newBuffer:(atapiMPL_t *)mode
{
    int i;
    int pageLength;
    unsigned int outLength;
    unsigned char *data;
    atapiMappedBuffer_t mapped;

    if ((atapiIoReq->scsiCmd == C6OP_MODESENSE) &&
        (atapiIoReq->bytesTransferred >= 10)) {
        pageLength = mode->pageData[1] + 2;
        outLength = atapiIoReq->atapiCmd[8] - MPH_DELTA;
        if ((pageLength + MPH_SCSI_6_SIZE) > outLength)
            return NO;
        if (atapiMapClientBuffer(client, buffer, outLength, &mapped) == NO)
            return NO;
        data = (unsigned char *)mapped.addr;
        data[0] = mode->mph.mdl0;
        data[1] = mode->mph.mt;
        data[2] = 0;
        data[3] = 0;
        for (i = 0; i < pageLength; i++)
            data[4 + i] = mode->pageData[i];
        atapiUnmapClientBuffer(&mapped);
        atapiIoReq->bytesTransferred -= MPH_DELTA;
    }
    return YES;
}

- (BOOL)emulateSCSICmd:(atapiIoReq_t *)atapiIoReq
                buffer:(void *)buffer
                client:(vm_task_t)client
{
    unsigned char *data;
    unsigned int len;
    unsigned int mapLen;
    atapiMappedBuffer_t mapped;

    if (buffer == 0)
        return NO;

    if (atapiIoReq->atapiCmd[0] == C10OP_MODESENSE) {
        if ((atapiIoReq->atapiCmd[2] & ATAPI_MODE_PAGE_MASK) == ATAPI_MODE_PAGE_2) {

            len = atapiIoReq->atapiCmd[4];
            mapLen = len;
            if (mapLen < 3)
                mapLen = 3;
            if (mapLen > atapiIoReq->maxTransfer)
                mapLen = atapiIoReq->maxTransfer;
            if (atapiMapClientBuffer(client, buffer, mapLen, &mapped) == NO)
                return NO;
            data = (unsigned char *)mapped.addr;
            if (len != 0)
                bzero(data, len);
            if (mapLen > 0)
                data[0] = ATAPI_MODE_PAGE_2;
            if (mapLen > 1)
                data[1] = len;
            if (mapLen > 2)
                data[2] = 1;
            atapiUnmapClientBuffer(&mapped);
            atapiIoReq->bytesTransferred = len;
            atapiIoReq->scsiStatus = STAT_GOOD;
            IOLog("ATAPI: MODE SENSE page 2 emulated unit %d len %u\n",
                  atapiIoReq->drive, len);
            return YES;
        }
    }
    return NO;
}

- (sc_status_t)resetSCSIBus
{
    int unit;
    sc_status_t status = SR_IOST_GOOD;

    for (unit = 0; unit < [_ataController numDevices]; unit++) {
        if ([_ataController isAtapiDevice:unit]) {
            [_ataController atapiControllerLock];
            if ([_ataController atapiSoftReset:unit] != ATAPI_R_SUCCESS) {
                IOLog("ATAPI: reset failed unit %d\n", unit);
                status = SR_IOST_HW;
            }
            [_ataController atapiControllerUnlock];
        }
    }
    return status;
}

- property_IODeviceClass:(char *)classes length:(unsigned int *)maxLen
{
    strcpy(classes, IOClassATAPIController);
    return self;
}

- property_IODeviceType:(char *)types length:(unsigned int *)maxLen
{
    strcat(types, " "IOTypeATAPI);
    return self;
}

@end
