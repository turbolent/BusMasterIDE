#import "ATAPIControllerCmds.h"

#import <bsd/dev/scsireg.h>
#import <driverkit/generalFuncs.h>
#import <driverkit/i386/ioPorts.h>
#import <driverkit/kernelDriver.h>
#import <kernserv/prototypes.h>
#import <kernserv/clock_timer.h>
#import <machkit/NXLock.h>
#import <sys/systm.h>
#import "BMIDEDMA.h"

#define ATA_SR_ERR              0x01
#define ATA_SR_DRQ              0x08
#define ATA_SR_BSY              0x80

#define ATA_ER_ABORT            0x04

#define ATA_DEV_LBA_BASE        0xe0
#define ATA_DEV_MASTER          0x00
#define ATA_DEV_SLAVE           0x10
#define ATA_FLOATING_STATUS     0xff

#define ATAPI_MAX_NOT_BUSY_US   5000000
#define ATAPI_RESET_DELAY_US    2500000
#define ATAPI_MAX_DRQ_US        5000000
#define ATAPI_MAX_IO_US         30000000
#define ATAPI_MAX_RETRIES       3
#define ATAPI_IDENTIFY_RETRIES  3
#define ATAPI_PACKET_SETTLE_US  1000

#define ATAPI_TEST_UNIT_READY   0x00
#define ATAPI_WRITE_10          0x2a
#define ATAPI_WRITE_12          0xaa
#define ATAPI_WRITE_VERIFY      0x2e
#define ATAPI_FORMAT_UNIT       0x04
#define ATAPI_READ_10           0x28
#define ATAPI_READ_12           0xa8
#define ATAPI_DMA_FEATURE       0x01
#define ATAPI_PACKET_BYTE_COUNT 2048

#define ATAPI_PAGE_SIZE         4096
#define ATAPI_PAGE_MASK         (ATAPI_PAGE_SIZE - 1)
#define ATAPI_COPY_WIDTH        1
#define ATAPI_DMA_ALIGN         4
#define ATAPI_BYTE_MASK         0xff
#define ATAPI_WORD_MASK         0xffff

#define ID_WORD_CAPS            49
#define ID_CAP_DMA              0x0100

#define BM_CMD_START            0x01
#define BM_CMD_READ             0x08
#define BM_REG_COMMAND          0x00
#define BM_REG_STATUS           0x02
#define BM_REG_PRD              0x04
#define BM_CHANNEL_STRIDE       0x08
#define BM_STATUS_ACTIVE        0x01
#define BM_STATUS_ERROR         0x02
#define BM_STATUS_INTERRUPT     0x04
#define BM_STATUS_CLEAR         (BM_STATUS_ERROR | BM_STATUS_INTERRUPT)
#define WAIT_ATAPI_DMA_US       30000000

static void
bmideAtapiDelay400ns(BMIDERegs *regs)
{
    inb(regs->altStatus);
    inb(regs->altStatus);
    inb(regs->altStatus);
    inb(regs->altStatus);
}

static int
bmideAtapiWaitNotBusy(BMIDERegs *regs,
                    unsigned int timeoutUsec,
                    BOOL alt,
                    unsigned char *lastStatus)
{
    unsigned int waited;
    unsigned char status;
    unsigned short port;

    port = alt ? regs->altStatus : regs->status;
    IODelay(1);
    for (waited = 0; waited < timeoutUsec; waited += 10) {
        status = inb(port);
        if (lastStatus != 0)
            *lastStatus = status;
        if ((status & ATA_SR_BSY) == 0)
            return 1;
        IODelay(10);
    }
    return 0;
}

static void
bmideAtapiPioCopy(caddr_t addr, BOOL read, unsigned int length,
                unsigned int dataPort)
{
    unsigned int words;
    unsigned int i;
    unsigned short *wordp;
    unsigned char *bytep;
    unsigned short value;

    words = length / 2;
    wordp = (unsigned short *)addr;
    if (read) {
        for (i = 0; i < words; i++)
            wordp[i] = inw(dataPort);
        if (length & 1) {
            value = inw(dataPort);
            bytep = (unsigned char *)(wordp + words);
            *bytep = (unsigned char)(value & ATAPI_BYTE_MASK);
        }
    } else {
        for (i = 0; i < words; i++)
            outw(dataPort, wordp[i]);
        if (length & 1) {
            bytep = (unsigned char *)(wordp + words);
            outw(dataPort, *bytep);
        }
    }
}

static BOOL
bmideAtapiMapUserPage(vm_task_t client,
                    unsigned int virt,
                    vm_address_t *mappedPage,
                    caddr_t *mappedAddr)
{
    unsigned int phys;
    IOReturn rtn;

    rtn = IOPhysicalFromVirtual(client, (vm_address_t)virt, &phys);
    if (rtn != IO_R_SUCCESS) {
        IOLog("ATAPI: cannot translate buffer VA %08x client %08x\n",
              virt, (unsigned int)client);
        return NO;
    }

    rtn = IOMapPhysicalIntoIOTask(phys & ~ATAPI_PAGE_MASK, ATAPI_PAGE_SIZE,
                                  mappedPage);
    if (rtn != IO_R_SUCCESS) {
        IOLog("ATAPI: cannot map physical page %08x rtn %d\n",
              phys & ~ATAPI_PAGE_MASK, rtn);
        return NO;
    }

    *mappedAddr = (caddr_t)(*mappedPage + (phys & ATAPI_PAGE_MASK));
    return YES;
}

static BOOL
bmideAtapiCopyClientBuffer(caddr_t clientAddr,
                         vm_task_t client,
                         caddr_t kernelAddr,
                         BOOL toClient,
                         unsigned int length)
{
    unsigned int remaining;
    unsigned int virt;
    unsigned int offset;
    unsigned int chunk;
    vm_address_t mappedPage;
    caddr_t mappedAddr;

    remaining = length;
    virt = (unsigned int)clientAddr;
    offset = 0;

    while (remaining != 0) {
        chunk = ATAPI_PAGE_SIZE - (virt & ATAPI_PAGE_MASK);
        if (chunk > remaining)
            chunk = remaining;

        if (!bmideAtapiMapUserPage(client, virt, &mappedPage, &mappedAddr))
            return NO;

        if (toClient)
            IOCopyMemory(kernelAddr + offset, mappedAddr, chunk,
                         ATAPI_COPY_WIDTH);
        else
            IOCopyMemory(mappedAddr, kernelAddr + offset, chunk,
                         ATAPI_COPY_WIDTH);

        IOUnmapPhysicalFromIOTask(mappedPage, ATAPI_PAGE_SIZE);
        virt += chunk;
        offset += chunk;
        remaining -= chunk;
    }

    return YES;
}

static BOOL
bmideAtapiXferData(caddr_t addr, BOOL read, vm_task_t client,
                 unsigned int length, BMIDERegs *regs)
{
    caddr_t bounce;

    if (length == 0)
        return YES;

    if (client == 0 || client == IOVmTaskSelf()) {
        bmideAtapiPioCopy(addr, read, length, regs->data);
        return YES;
    }

    bounce = (caddr_t)IOMalloc(length);
    if (bounce == 0) {
        IOLog("ATAPI: bounce buffer allocation failed length %u\n", length);
        return NO;
    }

    if (read == NO) {
        if (!bmideAtapiCopyClientBuffer(addr, client, bounce, NO, length)) {
            IOLog("ATAPI: client page read failed buf %08x len %u\n",
                  (unsigned int)addr, length);
            IOFree(bounce, length);
            return NO;
        }
    } else {
        bzero(bounce, length);
    }

    bmideAtapiPioCopy(bounce, read, length, regs->data);

    if (read) {
        if (!bmideAtapiCopyClientBuffer(addr, client, bounce, YES, length)) {
            IOLog("ATAPI: client page write failed buf %08x len %u\n",
                  (unsigned int)addr, length);
            IOFree(bounce, length);
            return NO;
        }
    }

    IOFree(bounce, length);
    return YES;
}

static void
bmideAtapiProgramPrd(unsigned short bmBase, unsigned int prdPhys)
{
    outw(bmBase + BM_REG_PRD, (unsigned short)(prdPhys & ATAPI_WORD_MASK));
    outw(bmBase + BM_REG_PRD + 2, (unsigned short)(prdPhys >> 16));
}

static unsigned char
bmideAtapiDeviceSelectByte(unsigned char drive)
{
    return ATA_DEV_LBA_BASE | (drive ? ATA_DEV_SLAVE : ATA_DEV_MASTER);
}

static unsigned int
bmideAtapiReadByteCount(BMIDERegs *regs)
{
    return (inb(regs->lbaHigh) << 8) | inb(regs->lbaMid);
}

static void
bmideAtapiWriteByteCount(BMIDERegs *regs, unsigned int byteCount)
{
    outb(regs->lbaMid, byteCount & ATAPI_BYTE_MASK);
    outb(regs->lbaHigh, (byteCount >> 8) & ATAPI_BYTE_MASK);
}

static unsigned short
bmideAtapiBmBaseForChannel(unsigned short bmiba, unsigned char channel)
{
    return bmiba + (channel ? BM_CHANNEL_STRIDE : 0x00);
}

static BOOL
bmideAtapiReadDataCommand(unsigned char cmd)
{
    return (cmd == ATAPI_READ_10 || cmd == ATAPI_READ_12);
}

static BOOL
bmideAtapiRejectedWriteCommand(unsigned char cmd)
{
    return (cmd == ATAPI_WRITE_10 || cmd == ATAPI_WRITE_12 ||
            cmd == ATAPI_WRITE_VERIFY || cmd == ATAPI_FORMAT_UNIT);
}

static BOOL
bmideAtapiAlignedForDMA(void *buffer)
{
    return ((((unsigned int)buffer) & (ATAPI_DMA_ALIGN - 1)) == 0);
}

static const char *
bmideAtapiDeviceTypeString(unsigned char deviceType)
{
    switch (deviceType) {
      case ATAPI_DEVICE_DIRECT_ACCESS:
        return "direct-access";
      case ATAPI_DEVICE_TAPE:
        return "tape";
      case ATAPI_DEVICE_CD_ROM:
        return "CD-ROM";
      case ATAPI_DEVICE_OPTICAL:
        return "optical";
      default:
        return "unknown";
    }
}

@implementation IDEController(ATAPI)

- (void)atapiControllerLock
{
    [_cmdLock lock];
}

- (void)atapiControllerUnlock
{
    [_cmdLock unlock];
}

- (BMIDERegs *)atapiRegsForUnit:(unsigned char)unit
{
    if (unit >= BMIDE_MAX_DRIVES)
        return 0;
    return &_regs[_drives[unit].channel];
}

- (atapi_return_t)atapiWaitStatusBitsFor:(unsigned int)timeout
                                      on:(unsigned char)on
                                     off:(unsigned char)off
                                     alt:(BOOL)alt
                                    unit:(unsigned char)unit
                                  status:(unsigned char *)status
{
    BMIDERegs *regs;
    unsigned char localStatus;

    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return ATAPI_R_ERROR;
    if (status == 0)
        status = &localStatus;
    if (!bmideAtapiWaitNotBusy(regs, timeout, alt, status))
        return ATAPI_R_TIMEOUT;
    IODelay(1);
    if (((*status & on) == on) && ((~(*status) & off) == off))
        return ATAPI_R_SUCCESS;
    return ATAPI_R_TIMEOUT;
}

- (BOOL)xferData:(caddr_t)xferAddr
            read:(BOOL)read
          client:(vm_task_t)client
          length:(unsigned int)length
            unit:(unsigned char)unit
{
    BMIDERegs *regs;

    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return NO;
    return bmideAtapiXferData(xferAddr, read, client, length, regs);
}

- (BOOL)atapiSelectUnit:(unsigned char)unit
{
    BMIDERegs *regs;
    unsigned char status;

    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return NO;
    if ([self atapiWaitStatusBitsFor:ATAPI_MAX_NOT_BUSY_US
                                  on:0
                                 off:0
                                 alt:NO
                                unit:unit
                              status:&status] != ATAPI_R_SUCCESS)
        return NO;
    outb(regs->device, bmideAtapiDeviceSelectByte(_drives[unit].drive));
    bmideAtapiDelay400ns(regs);
    status = inb(regs->status);
    if (status == ATA_FLOATING_STATUS)
        return NO;
    return YES;
}

- (unsigned char)atapiCommandPacketSize:(unsigned char)unit
{
    if (unit >= BMIDE_MAX_DRIVES)
        return 0;
    return _drives[unit].atapiCmdLen;
}

- (atapi_return_t)atapiSoftReset:(unsigned char)unit
{
    BMIDERegs *regs;
    unsigned char status;
    unsigned char device;

    if (unit >= BMIDE_MAX_DRIVES)
        return ATAPI_R_ERROR;
    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return ATAPI_R_ERROR;

    device = bmideAtapiDeviceSelectByte(_drives[unit].drive);
    outb(regs->device, device);
    bmideAtapiDelay400ns(regs);
    outb(regs->command, ATAPI_SOFT_RESET);
    IOSleep(50);
    if ([self atapiWaitStatusBitsFor:ATAPI_RESET_DELAY_US
                                  on:0
                                 off:0
                                 alt:NO
                                unit:unit
                              status:&status] == ATAPI_R_SUCCESS)
        return ATAPI_R_SUCCESS;
    IOLog("ATAPI: soft reset failed unit %d status %02x\n", unit, status);
    return ATAPI_R_ERROR;
}

- (atapi_return_t)_atapiIdentifyDevice:(vm_task_t)client
                                  addr:(caddr_t)xferAddr
                                  unit:(unsigned char)unit
{
    BMIDERegs *regs;
    unsigned char status;
    unsigned int i;

    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return ATAPI_R_ERROR;
    if ([self atapiSelectUnit:unit] == NO)
        return ATAPI_R_ERROR;

    bzero(xferAddr, BMIDE_SECTOR_SIZE);

    outb(regs->sectorCount, 0);
    outb(regs->lbaLow, 0);
    outb(regs->lbaMid, 0);
    outb(regs->lbaHigh, 0);
    outb(regs->command, ATAPI_IDENTIFY_DRIVE);
    bmideAtapiDelay400ns(regs);

    if ([self atapiWaitStatusBitsFor:ATAPI_MAX_NOT_BUSY_US
                                  on:0
                                 off:0
                                 alt:YES
                                unit:unit
                              status:&status] != ATAPI_R_SUCCESS) {
        IOLog("ATAPI: IDENTIFY BSY timeout unit %d status %02x\n",
              unit, status);
        return ATAPI_R_TIMEOUT;
    }

    if ((status & ATA_SR_ERR) && (inb(regs->error) & ATA_ER_ABORT))
        return ATAPI_R_ERROR;

    for (i = 0; i < ATAPI_MAX_DRQ_US; i += 10) {
        status = inb(regs->status);
        if ((status & ATA_SR_BSY) == 0) {
            if ((status & ATA_SR_ERR) != 0)
                return ATAPI_R_ERROR;
            if ((status & ATA_SR_DRQ) != 0)
                break;
        }
        IODelay(10);
    }
    if (i >= ATAPI_MAX_DRQ_US) {
        IOLog("ATAPI: IDENTIFY timeout unit %d status %02x\n", unit, status);
        return ATAPI_R_TIMEOUT;
    }

    if ([self xferData:xferAddr
                  read:YES
                client:client
                length:BMIDE_SECTOR_SIZE
                  unit:unit] == NO)
        return ATAPI_R_ERROR;
    return ATAPI_R_SUCCESS;
}

- (atapi_return_t)atapiIdentifyDevice:(vm_task_t)client
                                 addr:(caddr_t)xferAddr
                                 unit:(unsigned char)unit
{
    int i;
    atapi_return_t ret;

    ret = ATAPI_R_ERROR;
    for (i = 0; i < ATAPI_IDENTIFY_RETRIES; i++) {
        ret = [self _atapiIdentifyDevice:client addr:xferAddr unit:unit];
        if (ret == ATAPI_R_SUCCESS)
            break;
        [self atapiSoftReset:unit];
        IOSleep(500);
        IOLog("ATAPI: unit %d IDENTIFY PACKET failed rtn %d, retrying\n",
              unit, ret);
    }
    return ret;
}

- (void)atapiInitParameters:(unsigned short *)identify
                     Device:(unsigned char)unit
{
    atapiGenConfig_t *cfg;

    cfg = (atapiGenConfig_t *)&identify[0];
    if (cfg->cmdPacketSize == 0x01)
        _drives[unit].atapiCmdLen = 16;
    else
        _drives[unit].atapiCmdLen = 12;

    if (_drives[unit].atapiCmdLen != 12) {
        IOLog("ATAPI: unit %d command len changed to 12 from %d\n",
              unit, _drives[unit].atapiCmdLen);
        _drives[unit].atapiCmdLen = 12;
    }
    _drives[unit].atapiCmdDrqType = cfg->cmdDrqType;
    _drives[unit].atapiDeviceType = cfg->deviceType;
    _drives[unit].dmaSupported = ((identify[ID_WORD_CAPS] & ID_CAP_DMA) != 0);
}

- (atapi_return_t)issuePacketCommandForUnit:(unsigned char)unit
{
    BMIDERegs *regs;
    unsigned char status;
    unsigned char reason;
    unsigned int waited;

    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return ATAPI_R_ERROR;

    outb(regs->command, ATAPI_PACKET);
    bmideAtapiDelay400ns(regs);

    for (waited = 0; waited < ATAPI_MAX_DRQ_US; waited += 10) {
        status = inb(regs->status);
        reason = inb(regs->sectorCount);
        if ((status & ATA_SR_BSY) == 0 &&
            (reason & ATAPI_CMD_OR_DATA) &&
            !(reason & ATAPI_IO_DIRECTION))
            break;
        IODelay(10);
    }

    if (waited >= ATAPI_MAX_DRQ_US) {
        IOLog("ATAPI: unit %d invalid packet phase status %02x reason %02x\n",
              unit, status, reason);
        return ATAPI_R_TIMEOUT;
    }

    status = inb(regs->status);
    if (status & ATA_SR_DRQ)
        return ATAPI_R_SUCCESS;

    IOLog("ATAPI: unit %d DRQ not set after packet command status %02x\n",
          unit, status);
    return ATAPI_R_ERROR;
}

- (void)sendAtapiCommand:(unsigned char *)atapiCmd
                  cmdLen:(unsigned char)len
                    unit:(unsigned char)unit
{
    BMIDERegs *regs;
    int i;

    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return;
    for (i = 0; i < len / 2; i++)
        outw(regs->data, atapiCmd[2 * i + 1] << 8 | atapiCmd[2 * i]);
}

- (sc_status_t)atapiPIODataTransfer:(atapiIoReq_t *)atapiIoReq
                              buffer:(void *)buffer
                              client:(vm_task_t)client
{
    BMIDERegs *regs;
    unsigned char status;
    unsigned int waited;
    unsigned int bytes;
    unsigned int offset;

    regs = [self atapiRegsForUnit:atapiIoReq->drive];
    if (regs == 0)
        return SR_IOST_SELTO;

    atapiIoReq->bytesTransferred = 0;
    offset = 0;

    /*
     * We poll, so give the device a chance to post BSY/DRQ/ERR before
     * treating a no-DRQ status as successful completion.
     */
    IODelay(ATAPI_PACKET_SETTLE_US);

    for (;;) {
        for (waited = 0; waited < ATAPI_MAX_IO_US; waited += 10) {
            status = inb(regs->status);
            if ((status & ATA_SR_BSY) == 0) {
                if (status & ATA_SR_DRQ)
                    break;
                if (status & ATA_SR_ERR)
                    break;
                /*
                 * We poll, an ATAPI data command can still show idle
                 * status before the first DRQ phase is posted.  
                 * Do not treat that as command completion until at least
                 * one data phase has happened, or the command did not 
                 * request data.
                 */
                if (atapiIoReq->maxTransfer != 0 &&
                    atapiIoReq->bytesTransferred == 0) {
                    IODelay(10);
                    continue;
                }
                atapiIoReq->scsiStatus = STAT_GOOD;
                return SR_IOST_GOOD;
            }
            IODelay(10);
        }

        if (waited >= ATAPI_MAX_IO_US) {
            IOLog("ATAPI: command %02x timeout unit %d\n",
                  atapiIoReq->atapiCmd[0], atapiIoReq->drive);
            [self dumpStatus:atapiIoReq];
            [self atapiSoftReset:atapiIoReq->drive];
            atapiIoReq->scsiStatus = STAT_CHECK;
            return SR_IOST_CHKSNV;
        }

        if (!(status & ATA_SR_DRQ)) {
            if (status & ATA_SR_ERR) {
#ifdef DEBUG
                if (atapiIoReq->atapiCmd[0] != ATAPI_TEST_UNIT_READY)
                    [self dumpStatus:atapiIoReq];
#endif
                atapiIoReq->scsiStatus = STAT_CHECK;
                return SR_IOST_CHKSNV;
            }
            atapiIoReq->scsiStatus = STAT_GOOD;
            return SR_IOST_GOOD;
        }

        bytes = bmideAtapiReadByteCount(regs);

        if (atapiIoReq->bytesTransferred + bytes > atapiIoReq->maxTransfer) {
            unsigned int diff;

            IOLog("ATAPI: unit %d transfer limit %u exceeded by request %u\n",
                  atapiIoReq->drive, atapiIoReq->maxTransfer, bytes);
            [self dumpStatus:atapiIoReq];
            diff = atapiIoReq->maxTransfer - atapiIoReq->bytesTransferred;
            if (diff != 0 && buffer != 0) {
                if ([self xferData:(caddr_t)buffer + offset
                               read:atapiIoReq->read
                             client:client
                             length:diff
                               unit:atapiIoReq->drive] == NO) {
                    [self atapiSoftReset:atapiIoReq->drive];
                    atapiIoReq->scsiStatus = STAT_CHECK;
                    return SR_IOST_HW;
                }
            }
            [self atapiSoftReset:atapiIoReq->drive];
            atapiIoReq->bytesTransferred += diff;
            atapiIoReq->scsiStatus = STAT_GOOD;
            return SR_IOST_GOOD;
        }

        if (buffer == 0) {
            [self atapiSoftReset:atapiIoReq->drive];
            atapiIoReq->scsiStatus = STAT_CHECK;
            return SR_IOST_CMDREJ;
        }

        if ([self xferData:(caddr_t)buffer + offset
                      read:atapiIoReq->read
                    client:client
                    length:bytes
                      unit:atapiIoReq->drive] == NO) {
            [self atapiSoftReset:atapiIoReq->drive];
            atapiIoReq->scsiStatus = STAT_CHECK;
            return SR_IOST_HW;
        }
        atapiIoReq->bytesTransferred += bytes;
        offset += bytes;
    }
}

- (void)dumpStatus:(atapiIoReq_t *)atapiIoReq
{
    int i;

    IOLog("ATAPI: failed command unit %d lun %d len %d read %d\n",
          atapiIoReq->drive, atapiIoReq->lun, atapiIoReq->cmdLen,
          atapiIoReq->read);
    IOLog("ATAPI: command:");
    for (i = 0; i < atapiIoReq->cmdLen; i++)
        IOLog(" %02x", atapiIoReq->atapiCmd[i]);
    IOLog("\n");
    [self getAtapiRegistersForUnit:atapiIoReq->drive Print:"dumpStatus"];
}

- (sc_status_t)performATAPIDMA:(atapiIoReq_t *)atapiIoReq
                         buffer:(void *)buffer
                         client:(vm_task_t)client
{
    BMIDERegs *regs;
    unsigned short bmBase;
    unsigned int waited;
    unsigned char bmStatus;
    unsigned char status;
    unsigned char ataError;
    void *dmaBuffer;
    void *bounceAlloc;
    vm_task_t dmaClient;
    unsigned int length;
    sc_status_t rtn;
    BMIDEDMACompletion completion;
    BMIDEDMAResult dmaResult;

    regs = [self atapiRegsForUnit:atapiIoReq->drive];
    if (regs == 0)
        return SR_IOST_SELTO;

    length = atapiIoReq->maxTransfer;
    atapiIoReq->bytesTransferred = 0;
    atapiIoReq->scsiStatus = STAT_CHECK;
    bounceAlloc = 0;
    dmaBuffer = buffer;
    dmaClient = client;
    bmBase = bmideAtapiBmBaseForChannel(_bmiba,
        _drives[atapiIoReq->drive].channel);
    if (bmBase == 0)
        return SR_IOST_CMDREJ;

    if (!bmideAtapiAlignedForDMA(buffer)) {
        unsigned int aligned;

        bounceAlloc = IOMalloc(length + ATAPI_DMA_ALIGN);
        if (bounceAlloc == 0) {
            IOLog("ATAPI: DMA bounce allocation failed unit %d len %u\n",
                  atapiIoReq->drive, length);
            return SR_IOST_CMDREJ;
        }
        aligned = (((unsigned int)bounceAlloc) + (ATAPI_DMA_ALIGN - 1)) &
            ~(ATAPI_DMA_ALIGN - 1);
        dmaBuffer = (void *)aligned;
        dmaClient = IOVmTaskSelf();
        bzero(dmaBuffer, length);
    }

    if ([self buildPrdForBuffer:dmaBuffer length:length client:dmaClient]
        == NO) {
        IOLog("ATAPI: DMA PRD setup failed unit %d buf %08x len %u\n",
              atapiIoReq->drive, (unsigned int)dmaBuffer, length);
        rtn = SR_IOST_CMDREJ;
        goto done;
    }

    bmideStopBmDma(bmBase);
    bmideAtapiProgramPrd(bmBase, _prdPhys);
    outb(bmBase + BM_REG_COMMAND, BM_CMD_READ);

    outb(bmBase + BM_REG_COMMAND, BM_CMD_READ | BM_CMD_START);

    dmaResult = bmidePollDma(bmBase, regs, WAIT_ATAPI_DMA_US, &completion);
    bmStatus = completion.bmStatus;
    status = completion.ataStatus;
    waited = completion.waited;
    ataError = (dmaResult == BMIDE_DMA_COMPLETE) ? 0 : inb(regs->error);
    bmideFinishBmDma(bmBase, BM_CMD_READ, bmStatus);

    if (dmaResult != BMIDE_DMA_COMPLETE) {
        IOLog("ATAPI: DMA failed unit %d result %d waited %u BM %02x ATA %02x ERR %02x len %u\n",
              atapiIoReq->drive, dmaResult, waited, bmStatus, status,
              ataError, length);
        if (dmaResult == BMIDE_DMA_DEVICE_ERROR) {
            /* Preserve device sense data for the next REQUEST SENSE. */
            rtn = SR_IOST_CHKSNV;
        } else {
            [self atapiSoftReset:atapiIoReq->drive];
            rtn = SR_IOST_HW;
        }
        goto done;
    }

    if (bounceAlloc != 0) {
        if (client == 0 || client == IOVmTaskSelf()) {
            IOCopyMemory((caddr_t)dmaBuffer, (caddr_t)buffer, length,
                         ATAPI_COPY_WIDTH);
        } else if (!bmideAtapiCopyClientBuffer((caddr_t)buffer, client,
                                             (caddr_t)dmaBuffer, YES,
                                             length)) {
            IOLog("ATAPI: DMA bounce client copy failed unit %d buf %08x len %u\n",
                  atapiIoReq->drive, (unsigned int)buffer, length);
            rtn = SR_IOST_HW;
            goto done;
        }
    }

    atapiIoReq->bytesTransferred = length;
    atapiIoReq->scsiStatus = STAT_GOOD;
    rtn = SR_IOST_GOOD;

done:
    bmideStopBmDma(bmBase);
    if (bounceAlloc != 0)
        IOFree(bounceAlloc, length + ATAPI_DMA_ALIGN);
    return rtn;
}

- (sc_status_t)atapiExecuteCmd:(atapiIoReq_t *)atapiIoReq
                         buffer:(void *)buffer
                         client:(vm_task_t)client
{
    BMIDERegs *regs;
    unsigned char cmd;
    unsigned char status;
    sc_status_t sc_ret;
    int i;
    BOOL useDMA;

    if (atapiIoReq->drive >= BMIDE_MAX_DRIVES ||
        atapiIoReq->lun != 0 ||
        [self isAtapiDevice:atapiIoReq->drive] == NO)
        return SR_IOST_SELTO;

    cmd = atapiIoReq->atapiCmd[0];
    if (bmideAtapiRejectedWriteCommand(cmd)) {
        IOLog("ATAPI: rejected write command %02x unit %d\n",
              cmd, atapiIoReq->drive);
        atapiIoReq->scsiStatus = STAT_CHECK;
        return SR_IOST_CMDREJ;
    }

    regs = [self atapiRegsForUnit:atapiIoReq->drive];
    if (regs == 0)
        return SR_IOST_SELTO;
    useDMA = (atapiIoReq->read == YES &&
              buffer != 0 &&
              atapiIoReq->maxTransfer != 0 &&
              bmideAtapiReadDataCommand(cmd) &&
              _drives[atapiIoReq->drive].dmaSupported == YES);

    for (i = 0; i < ATAPI_MAX_RETRIES; i++) {
        if ([self atapiSelectUnit:atapiIoReq->drive] == NO) {
            [self atapiSoftReset:atapiIoReq->drive];
            continue;
        }

        if ([self atapiWaitStatusBitsFor:ATAPI_MAX_NOT_BUSY_US
                                      on:0
                                     off:ATA_SR_DRQ
                                     alt:NO
                                    unit:atapiIoReq->drive
                                  status:&status] != ATAPI_R_SUCCESS) {
            IOLog("ATAPI: unit %d not ready for packet status %02x\n",
                  atapiIoReq->drive, status);
            [self atapiSoftReset:atapiIoReq->drive];
            continue;
        }

        bmideAtapiWriteByteCount(regs, ATAPI_PACKET_BYTE_COUNT);
        outb(regs->error, useDMA ? ATAPI_DMA_FEATURE : 0);

        if ([self issuePacketCommandForUnit:atapiIoReq->drive]
            == ATAPI_R_SUCCESS)
            break;

        IOLog("ATAPI: unit %d packet command failed, retrying\n",
              atapiIoReq->drive);
        [self atapiSoftReset:atapiIoReq->drive];
    }

    if (i == ATAPI_MAX_RETRIES) {
        IOLog("ATAPI: unit %d fatal packet command failure\n",
              atapiIoReq->drive);
        atapiIoReq->scsiStatus = STAT_CHECK;
        return SR_IOST_CMDREJ;
    }

    [self sendAtapiCommand:atapiIoReq->atapiCmd
                    cmdLen:atapiIoReq->cmdLen
                      unit:atapiIoReq->drive];

    if (useDMA)
        sc_ret = [self performATAPIDMA:atapiIoReq
                                buffer:buffer
                                client:client];
    else
        sc_ret = [self atapiPIODataTransfer:atapiIoReq
                                     buffer:buffer
                                     client:client];
    return sc_ret;
}

- (void)getAtapiRegistersForUnit:(unsigned char)unit
                           Print:(char *)printString
{
    BMIDERegs *regs;

    regs = [self atapiRegsForUnit:unit];
    if (regs == 0)
        return;
    IOLog("ATAPI: %s unit %d status %02x error %02x scnt %02x mid %02x high %02x\n",
          printString ? printString : "regs", unit, inb(regs->status),
          inb(regs->error), inb(regs->sectorCount), inb(regs->lbaMid),
          inb(regs->lbaHigh));
}

- (void)logAtapiDevice:(unsigned char)unit
{
    IOLog("ATAPI: unit %d ch %d dev %d %s %s packet %d DRQ %d\n",
          unit, _drives[unit].channel, _drives[unit].drive,
          _drives[unit].model,
          bmideAtapiDeviceTypeString(_drives[unit].atapiDeviceType),
          _drives[unit].atapiCmdLen,
          _drives[unit].atapiCmdDrqType);
}

@end
