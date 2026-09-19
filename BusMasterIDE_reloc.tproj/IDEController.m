#import "IDEController.h"
#import "ATAPIControllerCmds.h"

#import <driverkit/i386/IOPCIDirectDevice.h>
#import <driverkit/i386/ioPorts.h>
#import <driverkit/kernelDriver.h>
#import <driverkit/generalFuncs.h>
#import <driverkit/return.h>
#import <kernserv/clock_timer.h>
#import <kernserv/prototypes.h>
#import <machkit/NXLock.h>
#import <sys/systm.h>
#import "BMIDEDMA.h"

#define PCI_COMMAND_REG         0x04
#define PCI_CLASS_REG           0x08
#define PCI_BAR4_REG            0x20

#define PCI_COMMAND_IO          0x0001
#define PCI_COMMAND_BM          0x0004
#define PCI_STATUS_MASTER_PARITY    0x0100
#define PCI_STATUS_SIG_TARGET_ABORT 0x0800
#define PCI_STATUS_REC_TARGET_ABORT 0x1000
#define PCI_STATUS_REC_MASTER_ABORT 0x2000
#define PCI_STATUS_SIG_SYSTEM_ERROR 0x4000
#define PCI_STATUS_DET_PARITY_ERROR 0x8000

#define PCI_PROGIF_BM_CAPABLE   0x80
#define PCI_PROGIF_NATIVE       0x05

#define ATA_SR_ERR              0x01
#define ATA_SR_DRQ              0x08
#define ATA_SR_DF               0x20
#define ATA_SR_DRDY             0x40
#define ATA_SR_BSY              0x80

#define ATA_ER_AMNF             0x01
#define ATA_ER_TK0NF            0x02
#define ATA_ER_ABRT             0x04
#define ATA_ER_MCR              0x08
#define ATA_ER_IDNF             0x10
#define ATA_ER_MC               0x20
#define ATA_ER_UNC              0x40
#define ATA_ER_ICRC             0x80

#define ATA_DEV_LBA             0x40
#define ATA_DEV_MASTER          0x00
#define ATA_DEV_SLAVE           0x10

#define ATA_CTRL_NIEN           0x02
#define ATA_CTRL_SRST           0x04

#define ATA_CMD_IDENTIFY        0xec
#define ATA_CMD_READ_DMA        0xc8
#define ATA_CMD_WRITE_DMA       0xca

#define ATA_SIG_ATAPI_LBAMID    0x14
#define ATA_SIG_ATAPI_LBAHIGH   0xeb
#define ATA_SIG_SATAPI_LBAMID   0x69
#define ATA_SIG_SATAPI_LBAHIGH  0x96

#define ID_WORD_CAPS            49
#define ID_WORD_MWDMA           63
#define ID_WORD_UDMA            88
#define ID_WORD_LBA_LOW         60
#define ID_WORD_LBA_HIGH        61
#define ID_CAP_DMA              0x0100
#define ID_CAP_LBA              0x0200

#define BM_CMD_START            0x01
#define BM_CMD_READ             0x08
#define BM_REG_COMMAND          0x00
#define BM_REG_STATUS           0x02
#define BM_REG_PRD              0x04
#define BM_STATUS_ACTIVE        0x01
#define BM_STATUS_ERROR         0x02
#define BM_STATUS_INTERRUPT     0x04
#define BM_STATUS_CLEAR         (BM_STATUS_ERROR | BM_STATUS_INTERRUPT)

#define PRD_EOT                 0x8000
#define PRD_TABLE_BYTES         4096
#define PRD_ALLOC_BYTES         8192
#define PRD_MAX_ENTRIES         (PRD_TABLE_BYTES / sizeof(BMIDEPrd))
#define PRD_BOUNDARY_BYTES      0x10000
#define PRD_BOUNDARY_MASK       0xffff0000
#define PRD_PAGE_BYTES          0x1000

#define WAIT_NOT_BUSY_US        1000000
#define WAIT_DRQ_US             1000000
#define WAIT_DMA_US             5000000
#define DIAG_DMA_LOG_LIMIT      0
#define DMA_MAX_ATTEMPTS        2
#define BMIDE_DRIVER_VERSION   "0.21"

static void
bmideDelay400ns(BMIDERegs *regs)
{
    inb(regs->altStatus);
    inb(regs->altStatus);
    inb(regs->altStatus);
    inb(regs->altStatus);
}

static int
bmideWaitMask(BMIDERegs *regs,
               unsigned char clearMask,
               unsigned char setMask,
               unsigned int timeoutUsec,
               unsigned char *lastStatus)
{
    unsigned int waited;
    unsigned char status;

    for (waited = 0; waited < timeoutUsec; waited += 10) {
        status = inb(regs->status);
        if (lastStatus != 0)
            *lastStatus = status;
        if (((status & clearMask) == 0) && ((status & setMask) == setMask))
            return 1;
        IODelay(10);
    }
    return 0;
}

static int
bmideWaitNotBusy(BMIDERegs *regs, unsigned char *lastStatus)
{
    return bmideWaitMask(regs, ATA_SR_BSY, 0, WAIT_NOT_BUSY_US,
                          lastStatus);
}

static void
bmideLogDecodedStatus(const char *phase,
                       unsigned char bmStatus,
                       unsigned char ataStatus,
                       unsigned char ataError,
                       unsigned short pciStatus, BOOL pciStatusValid)
{
    IOLog("IDE: %s bits BM active %u err %u intr %u ATA bsy %u drdy %u df %u err %u ATAERR amnf %u tk0nf %u abrt %u mcr %u idnf %u mc %u unc %u icrc %u\n",
          phase,
          (bmStatus & BM_STATUS_ACTIVE) != 0,
          (bmStatus & BM_STATUS_ERROR) != 0,
          (bmStatus & BM_STATUS_INTERRUPT) != 0,
          (ataStatus & ATA_SR_BSY) != 0,
          (ataStatus & ATA_SR_DRDY) != 0,
          (ataStatus & ATA_SR_DF) != 0,
          (ataStatus & ATA_SR_ERR) != 0,
          (ataError & ATA_ER_AMNF) != 0,
          (ataError & ATA_ER_TK0NF) != 0,
          (ataError & ATA_ER_ABRT) != 0,
          (ataError & ATA_ER_MCR) != 0,
          (ataError & ATA_ER_IDNF) != 0,
          (ataError & ATA_ER_MC) != 0,
          (ataError & ATA_ER_UNC) != 0,
          (ataError & ATA_ER_ICRC) != 0);
    if (!pciStatusValid) {
        IOLog("IDE: PCI status unavailable\n");
        return;
    }
    IOLog("IDE: PCI mdp %u sta %u rta %u rma %u sse %u dpe %u\n",
          (pciStatus & PCI_STATUS_MASTER_PARITY) != 0,
          (pciStatus & PCI_STATUS_SIG_TARGET_ABORT) != 0,
          (pciStatus & PCI_STATUS_REC_TARGET_ABORT) != 0,
          (pciStatus & PCI_STATUS_REC_MASTER_ABORT) != 0,
          (pciStatus & PCI_STATUS_SIG_SYSTEM_ERROR) != 0,
          (pciStatus & PCI_STATUS_DET_PARITY_ERROR) != 0);
}

static int
bmideIsAtapiSignature(unsigned char lbaMid, unsigned char lbaHigh)
{
    return ((lbaMid == ATA_SIG_ATAPI_LBAMID &&
             lbaHigh == ATA_SIG_ATAPI_LBAHIGH) ||
            (lbaMid == ATA_SIG_SATAPI_LBAMID &&
             lbaHigh == ATA_SIG_SATAPI_LBAHIGH));
}

static int
bmideWaitDrq(BMIDERegs *regs, unsigned char *lastStatus)
{
    unsigned int waited;
    unsigned char status;

    for (waited = 0; waited < WAIT_DRQ_US; waited += 10) {
        status = inb(regs->status);
        if (lastStatus != 0)
            *lastStatus = status;
        if ((status & ATA_SR_BSY) == 0) {
            if (status & (ATA_SR_ERR | ATA_SR_DF))
                return 0;
            if (status & ATA_SR_DRQ)
                return 1;
        }
        IODelay(10);
    }
    return 0;
}

static void
bmideReadWords(BMIDERegs *regs, unsigned short *buffer, unsigned int words)
{
    unsigned int i;

    for (i = 0; i < words; i++)
        buffer[i] = inw(regs->data);
}

static void
bmideBuildModel(unsigned short *identify, char *model, unsigned int size)
{
    unsigned int i;
    unsigned int o;

    if (size == 0)
        return;

    o = 0;
    for (i = 27; i <= 46 && (o + 2) < size; i++) {
        model[o++] = (char)(identify[i] >> 8);
        model[o++] = (char)(identify[i] & 0xff);
    }
    model[o] = '\0';
    while (o > 0 && model[o - 1] == ' ')
        model[--o] = '\0';
}

static unsigned int
bmideMin3(unsigned int a, unsigned int b, unsigned int c)
{
    unsigned int m;

    m = (a < b) ? a : b;
    return (m < c) ? m : c;
}

static int
bmideHighestMode(unsigned int bits, unsigned int maxMode)
{
    int mode;

    for (mode = (int)maxMode; mode >= 0; mode--) {
        if (bits & (1 << mode))
            return mode;
    }
    return -1;
}

static void
bmideLogDmaModes(unsigned int channel, unsigned int drive,
                  unsigned short *identify)
{
    unsigned int mwdma;
    unsigned int udma;
    unsigned int mwdmaSupported;
    unsigned int mwdmaActive;
    unsigned int udmaSupported;
    unsigned int udmaActive;
    int activeMwdma;
    int activeUdma;

    mwdma = identify[ID_WORD_MWDMA];
    udma = identify[ID_WORD_UDMA];
    mwdmaSupported = mwdma & 0x00ff;
    mwdmaActive = (mwdma >> 8) & 0x00ff;
    udmaSupported = udma & 0x00ff;
    udmaActive = (udma >> 8) & 0x00ff;
    activeMwdma = bmideHighestMode(mwdmaActive, 2);
    activeUdma = bmideHighestMode(udmaActive, 6);

    if (activeUdma >= 0) {
        IOLog("IDE: drive %d:%d DMA modes MWDMA sup %02x active %02x UDMA sup %02x active %02x current UDMA%d\n",
              channel, drive, mwdmaSupported, mwdmaActive,
              udmaSupported, udmaActive, activeUdma);
    } else if (activeMwdma >= 0) {
        IOLog("IDE: drive %d:%d DMA modes MWDMA sup %02x active %02x UDMA sup %02x active %02x current MWDMA%d\n",
              channel, drive, mwdmaSupported, mwdmaActive,
              udmaSupported, udmaActive, activeMwdma);
    } else {
        IOLog("IDE: drive %d:%d DMA modes MWDMA sup %02x active %02x UDMA sup %02x active %02x current unknown\n",
              channel, drive, mwdmaSupported, mwdmaActive,
              udmaSupported, udmaActive);
    }
}

static void
bmideSetLegacyRegs(BMIDERegs *regs, unsigned short cmdBase,
                    unsigned short ctlBase)
{
    regs->data = cmdBase + 0;
    regs->error = cmdBase + 1;
    regs->sectorCount = cmdBase + 2;
    regs->lbaLow = cmdBase + 3;
    regs->lbaMid = cmdBase + 4;
    regs->lbaHigh = cmdBase + 5;
    regs->device = cmdBase + 6;
    regs->status = cmdBase + 7;
    regs->command = cmdBase + 7;
    regs->altStatus = ctlBase;
    regs->deviceControl = ctlBase;
}

static unsigned short
bmideBmBaseForChannel(unsigned short bmiba, unsigned int channel)
{
    return bmiba + (channel ? 0x08 : 0x00);
}

static unsigned char
bmideAtaSectorCount(unsigned int sectors)
{
    return (sectors == BMIDE_MAX_SECTORS_IO) ? 0 : (unsigned char)sectors;
}

static const char *
bmideDirectionString(BOOL isWrite)
{
    return isWrite ? "write" : "read";
}

static void
bmideSetPrdLength(BMIDEPrd *prd, unsigned int length)
{
    prd->count = (length == PRD_BOUNDARY_BYTES) ? 0 :
        (unsigned short)length;
}

static int
bmideSamePrdWindow(unsigned int base, unsigned int phys)
{
    return (((base ^ phys) & PRD_BOUNDARY_MASK) == 0);
}

static void
bmideProgramPrd(unsigned short bmBase, unsigned int prdPhys)
{
    outw(bmBase + BM_REG_PRD, (unsigned short)(prdPhys & 0xffff));
    outw(bmBase + BM_REG_PRD + 2, (unsigned short)(prdPhys >> 16));
}

static void
bmideProgramLba28(BMIDERegs *regs, unsigned int drive,
                   unsigned int lba, unsigned char sectors)
{
    outb(regs->sectorCount, sectors);
    outb(regs->lbaLow, (unsigned char)(lba & 0xff));
    outb(regs->lbaMid, (unsigned char)((lba >> 8) & 0xff));
    outb(regs->lbaHigh, (unsigned char)((lba >> 16) & 0xff));
    outb(regs->device, 0xe0 | (drive ? ATA_DEV_SLAVE : 0) |
         ((lba >> 24) & 0x0f));
    bmideDelay400ns(regs);
}

@implementation IDEController

+ (BOOL)probe:deviceDescription
{
    id controller;

    controller = [[self alloc] initFromDeviceDescription:deviceDescription];
    if (controller == nil)
        return NO;
    if ([controller scanController] == NO) {
        [controller free];
        return NO;
    }

    [controller setDeviceKind:"IDEController"];
    [controller registerDevice];
    return YES;
}

- initFromDeviceDescription:deviceDescription
{
    self = [super initFromDeviceDescription:deviceDescription];
    if (self == nil)
        return nil;

    bzero(_drives, sizeof(_drives));
    _bmiba = 0;
    _prdAlloc = 0;
    _prdAllocSize = 0;
    _prd = 0;
    _prdPhys = 0;
    _driveCount = 0;
    _atapiCount = 0;
    _diagDmaLogsLeft = DIAG_DMA_LOG_LIMIT;
    _dmaRetries = 0;
    _dmaTimeouts = 0;
    _dmaBmErrors = 0;
    _dmaAtaErrors = 0;
    _dmaResets = 0;
    _cmdLock = [NXLock new];
    if (_cmdLock == nil) {
        IOLog("IDE: failed to allocate command lock\n");
        [self free];
        return nil;
    }

    bmideSetLegacyRegs(&_regs[0], 0x1f0, 0x3f6);
    bmideSetLegacyRegs(&_regs[1], 0x170, 0x376);
    IOLog("IDE: using legacy ports pri 1f0/3f6 irq14, sec 170/376 irq15\n");
    return self;
}

- free
{
    if (_cmdLock != nil)
        [_cmdLock free];
    if (_prdAlloc != 0)
        IOFree(_prdAlloc, _prdAllocSize);
    return [super free];
}

- (BOOL)validatePCIAndBAR4
{
    unsigned long commandData;
    unsigned long classData;
    unsigned long bar4Data;
    unsigned long commandWrite;
    unsigned long commandVerify;
    unsigned long bmiba;
    unsigned int classCode;
    unsigned int subClass;
    unsigned int progIf;

    if ([self getPCIConfigData:&commandData atRegister:PCI_COMMAND_REG]
        != IO_R_SUCCESS) {
        IOLog("IDE: cannot read PCI command register\n");
        return NO;
    }
    if ([self getPCIConfigData:&classData atRegister:PCI_CLASS_REG]
        != IO_R_SUCCESS) {
        IOLog("IDE: cannot read PCI class register\n");
        return NO;
    }
    if ([self getPCIConfigData:&bar4Data atRegister:PCI_BAR4_REG]
        != IO_R_SUCCESS) {
        IOLog("IDE: cannot read PCI BAR4\n");
        return NO;
    }
    if ((commandData & 0xffffUL) == 0xffffUL ||
        classData == 0xffffffffUL || bar4Data == 0xffffffffUL) {
        IOLog("IDE: PCI configuration is unavailable (all ones)\n");
        return NO;
    }

    classCode = (classData >> 24) & 0xff;
    subClass = (classData >> 16) & 0xff;
    progIf = (classData >> 8) & 0xff;

    IOLog("IDE: class %02x/%02x prog-if %02x command %04x BAR4 %08x\n",
          classCode, subClass, progIf, (unsigned int)(commandData & 0xffff),
          (unsigned int)bar4Data);

    if (classCode != 0x01 || subClass != 0x01)
        return NO;
    if ((progIf & PCI_PROGIF_BM_CAPABLE) == 0) {
        IOLog("IDE: controller has no BM-DMA prog-if bit\n");
        return NO;
    }
    if (progIf & PCI_PROGIF_NATIVE) {
        IOLog("IDE: native-mode IDE channels are unsupported\n");
        return NO;
    }
    if ((bar4Data & 0x01) == 0) {
        IOLog("IDE: BAR4 is not an I/O BAR\n");
        return NO;
    }

    /* Validate the full I/O address before narrowing it to a port number. */
    bmiba = bar4Data & 0xfffffffcUL;
    if (bmiba == 0 || bmiba > 0xfff0UL || (bmiba & 0x0fUL) != 0) {
        IOLog("IDE: BAR4 has an unassigned or unsupported I/O address %08x\n",
              (unsigned int)bar4Data);
        return NO;
    }

    if ((commandData & (PCI_COMMAND_IO | PCI_COMMAND_BM))
        != (PCI_COMMAND_IO | PCI_COMMAND_BM)) {
        /* DriverKit writes a dword: write zero to the W1C Status half. */
        commandWrite = (commandData & 0xffffUL)
            | PCI_COMMAND_IO | PCI_COMMAND_BM;
        if ([self setPCIConfigData:commandWrite atRegister:PCI_COMMAND_REG]
            != IO_R_SUCCESS) {
            IOLog("IDE: cannot enable PCI I/O and BusMaster (command %04x -> %04x)\n",
                  (unsigned int)(commandData & 0xffffUL),
                  (unsigned int)commandWrite);
            return NO;
        }
        if ([self getPCIConfigData:&commandVerify atRegister:PCI_COMMAND_REG]
            != IO_R_SUCCESS) {
            IOLog("IDE: cannot verify PCI I/O and BusMaster enable\n");
            return NO;
        }
        if ((commandVerify & 0xffffUL) == 0xffffUL ||
            (commandVerify & (PCI_COMMAND_IO | PCI_COMMAND_BM))
            != (PCI_COMMAND_IO | PCI_COMMAND_BM)) {
            IOLog("IDE: PCI I/O and BusMaster enable did not read back (wanted %04x, read %04x)\n",
                  (unsigned int)commandWrite,
                  (unsigned int)(commandVerify & 0xffffUL));
            return NO;
        }
        IOLog("IDE: enabled PCI I/O and BusMaster (command %04x -> %04x)\n",
              (unsigned int)(commandData & 0xffffUL),
              (unsigned int)(commandVerify & 0xffffUL));
    }

    _bmiba = (unsigned short)bmiba;

    IOLog("IDE: version %s accepted BAR4 BMIBA %04x primary %04x secondary %04x max %u sectors\n",
          BMIDE_DRIVER_VERSION, _bmiba, _bmiba, _bmiba + 0x08,
          BMIDE_MAX_SECTORS_IO);
    return YES;
}

- (BOOL)allocPrdTable
{
    unsigned int aligned;

    _prdAllocSize = PRD_ALLOC_BYTES;
    _prdAlloc = IOMalloc(_prdAllocSize);
    if (_prdAlloc == 0)
        return NO;

    aligned = (((unsigned int)_prdAlloc) + (PRD_TABLE_BYTES - 1))
        & ~(PRD_TABLE_BYTES - 1);
    _prd = (BMIDEPrd *)aligned;
    bzero(_prd, PRD_TABLE_BYTES);

    if (IOPhysicalFromVirtual(IOVmTaskSelf(), (vm_address_t)_prd, &_prdPhys)
        != IO_R_SUCCESS) {
        IOLog("IDE: cannot translate PRD table\n");
        return NO;
    }
    if (_prdPhys & 0x03) {
        IOLog("IDE: PRD table is not dword aligned\n");
        return NO;
    }
    IOLog("IDE: PRD table virt %08x phys %08x bytes %d\n",
          (unsigned int)_prd, _prdPhys, PRD_TABLE_BYTES);
    return YES;
}

- (void)softResetChannel:(unsigned int)channel
{
    BMIDERegs *regs;

    regs = &_regs[channel];
    outb(regs->deviceControl, ATA_CTRL_NIEN | ATA_CTRL_SRST);
    IODelay(10);
    outb(regs->deviceControl, ATA_CTRL_NIEN);
    IOSleep(2);
    bmideDelay400ns(regs);
}

- (BOOL)selectDrive:(unsigned int)drive regs:(BMIDERegs *)regs
{
    unsigned char status;

    outb(regs->device, 0xa0 | (drive ? ATA_DEV_SLAVE : ATA_DEV_MASTER));
    bmideDelay400ns(regs);
    if (!bmideWaitNotBusy(regs, &status))
        return NO;
    if (status == 0xff)
        return NO;
    return YES;
}

- (BOOL)identifyChannel:(unsigned int)channel
                  drive:(unsigned int)drive
               identify:(unsigned short *)identify
{
    BMIDERegs *regs;
    unsigned char status;
    unsigned char cl;
    unsigned char ch;

    regs = &_regs[channel];
    if ([self selectDrive:drive regs:regs] == NO)
        return NO;

    IOLog("IDE: IDENTIFY channel %d drive %d\n", channel, drive);

    outb(regs->sectorCount, 0);
    outb(regs->lbaLow, 0);
    outb(regs->lbaMid, 0);
    outb(regs->lbaHigh, 0);
    outb(regs->command, ATA_CMD_IDENTIFY);
    bmideDelay400ns(regs);

    status = inb(regs->status);
    if (status == 0 || status == 0xff) {
        IOLog("IDE: no ATA status on channel %d drive %d (%02x)\n",
              channel, drive, status);
        return NO;
    }

    if (!bmideWaitDrq(regs, &status)) {
        cl = inb(regs->lbaMid);
        ch = inb(regs->lbaHigh);
        if (bmideIsAtapiSignature(cl, ch))
            IOLog("IDE: channel %d drive %d is ATAPI; probing packet device\n",
                  channel, drive);
        else
            IOLog("IDE: IDENTIFY failed channel %d drive %d status %02x sig %02x/%02x\n",
                  channel, drive, status, cl, ch);
        return NO;
    }

    bmideReadWords(regs, identify, 256);
    return YES;
}

- (BOOL)atapiSignatureChannel:(unsigned int)channel
                        drive:(unsigned int)drive
{
    BMIDERegs *regs;
    unsigned char cl;
    unsigned char ch;

    regs = &_regs[channel];
    if ([self selectDrive:drive regs:regs] == NO)
        return NO;
    cl = inb(regs->lbaMid);
    ch = inb(regs->lbaHigh);
    return bmideIsAtapiSignature(cl, ch);
}

- (void)scanDrives
{
    unsigned int channel;
    unsigned int drive;
    unsigned int index;
    unsigned short identify[256];

    for (channel = 0; channel < BMIDE_MAX_CHANNELS; channel++) {
        [self softResetChannel:channel];
        for (drive = 0; drive < BMIDE_DRIVES_PER_CHAN; drive++) {
            index = channel * BMIDE_DRIVES_PER_CHAN + drive;
            _drives[index].channel = channel;
            _drives[index].drive = drive;
            bzero(identify, sizeof(identify));
            if ([self identifyChannel:channel drive:drive identify:identify]
                == NO) {
                if ([self atapiSignatureChannel:channel drive:drive] == NO)
                    continue;
                bzero(identify, sizeof(identify));
                if ([self atapiIdentifyDevice:IOVmTaskSelf()
                                         addr:(caddr_t)identify
                                         unit:index] != ATAPI_R_SUCCESS) {
                    IOLog("ATAPI: IDENTIFY PACKET failed channel %d drive %d\n",
                          channel, drive);
                    continue;
                }
                _drives[index].atapiPresent = YES;
                bmideBuildModel(identify, _drives[index].model,
                                 sizeof(_drives[index].model));
                [self atapiInitParameters:identify Device:index];
                _atapiCount++;
                [self logAtapiDevice:index];
                continue;
            }

            _drives[index].lbaSupported =
                ((identify[ID_WORD_CAPS] & ID_CAP_LBA) != 0);
            _drives[index].dmaSupported =
                ((identify[ID_WORD_CAPS] & ID_CAP_DMA) != 0);
            _drives[index].sectors =
                ((unsigned int)identify[ID_WORD_LBA_LOW]) |
                (((unsigned int)identify[ID_WORD_LBA_HIGH]) << 16);
            bmideBuildModel(identify, _drives[index].model,
                             sizeof(_drives[index].model));

            if (_drives[index].lbaSupported && _drives[index].dmaSupported &&
                _drives[index].sectors != 0) {
                _drives[index].present = YES;
                _driveCount++;
                IOLog("IDE: drive %d:%d %s %u LBA28 sectors DMA\n",
                      channel, drive, _drives[index].model,
                      _drives[index].sectors);
                bmideLogDmaModes(channel, drive, identify);
            } else {
                IOLog("IDE: drive %d:%d lacks LBA/DMA; skipped\n",
                      channel, drive);
            }
        }
    }
}

- (BOOL)scanController
{
    if ([self validatePCIAndBAR4] == NO)
        return NO;
    if ([self allocPrdTable] == NO)
        return NO;
    [self scanDrives];
    return ((_driveCount != 0) || (_atapiCount != 0)) ? YES : NO;
}

- (BOOL)drivePresentAtIndex:(unsigned int)index
{
    if (index >= BMIDE_MAX_DRIVES)
        return NO;
    return _drives[index].present;
}

- (unsigned int)numDevices
{
    return BMIDE_MAX_DRIVES;
}

- (BOOL)isAtapiDevice:(unsigned char)unit
{
    if (unit >= BMIDE_MAX_DRIVES)
        return NO;
    return _drives[unit].atapiPresent;
}

- (unsigned int)driveSectorCountAtIndex:(unsigned int)index
{
    if (index >= BMIDE_MAX_DRIVES)
        return 0;
    return _drives[index].sectors;
}

- (const char *)driveModelAtIndex:(unsigned int)index
{
    if (index >= BMIDE_MAX_DRIVES)
        return "";
    return _drives[index].model;
}

- (BOOL)buildPrdForBuffer:(void *)buffer
                   length:(unsigned int)length
                   client:(vm_task_t)client
{
    unsigned int remaining;
    unsigned int virt;
    unsigned int phys;
    unsigned int prdBase;
    unsigned int prdLength;
    unsigned int offset64k;
    unsigned int offsetPage;
    unsigned int chunk;
    unsigned int entry;

    if (((unsigned int)buffer) & 0x03)
        return NO;

    bzero(_prd, PRD_TABLE_BYTES);
    remaining = length;
    virt = (unsigned int)buffer;
    entry = 0;
    prdBase = 0;
    prdLength = 0;

    while (remaining != 0) {
        if (IOPhysicalFromVirtual(client, (vm_address_t)virt, &phys)
            != IO_R_SUCCESS) {
            IOLog("IDE: cannot translate buffer VA %08x\n", virt);
            return NO;
        }
        if (phys & 0x03) {
            IOLog("IDE: unaligned physical buffer %08x\n", phys);
            return NO;
        }

        offset64k = phys & 0xffff;
        offsetPage = phys & 0x0fff;
        chunk = bmideMin3(remaining, PRD_BOUNDARY_BYTES - offset64k,
                           PRD_PAGE_BYTES - offsetPage);

        if (prdLength != 0 &&
            phys == (prdBase + prdLength) &&
            bmideSamePrdWindow(prdBase, phys) &&
            prdLength + chunk <= PRD_BOUNDARY_BYTES) {
            prdLength += chunk;
            bmideSetPrdLength(&_prd[entry - 1], prdLength);
        } else {
            if (entry >= PRD_MAX_ENTRIES) {
                IOLog("IDE: PRD table exhausted for buffer %08x length %u\n",
                      (unsigned int)buffer, length);
                return NO;
            }
            prdBase = phys;
            prdLength = chunk;
            _prd[entry].base = prdBase;
            bmideSetPrdLength(&_prd[entry], prdLength);
            _prd[entry].flags = 0;
            entry++;
        }

        remaining -= chunk;
        virt += chunk;
    }

    if (entry == 0) {
        IOLog("IDE: empty PRD request buffer %08x length %u\n",
              (unsigned int)buffer, length);
        return NO;
    }
    _prd[entry - 1].flags |= PRD_EOT;
    return YES;
}

- (IOReturn)dmaTransferDrive:(unsigned int)index
                         lba:(unsigned int)lba
                 sectorCount:(unsigned int)sectors
                      buffer:(void *)buffer
                      client:(vm_task_t)client
                     isWrite:(BOOL)isWrite
                      actual:(unsigned int *)actual
{
    BMIDEDriveInfo *drive;
    BMIDERegs *regs;
    unsigned short bmBase;
    unsigned int length;
    unsigned int waited;
    unsigned char status;
    unsigned char bmStatus;
    unsigned char bmCommand;
    unsigned char ataSectorCount;
    unsigned char ataError;
    unsigned int attempt;
    IOReturn rtn;
    unsigned long pciCommandStatus;
    unsigned short pciStatus;
    BOOL pciStatusValid;
    BMIDEDMACompletion completion;
    BMIDEDMAResult dmaResult;

    if (actual != 0)
        *actual = 0;
    if (index >= BMIDE_MAX_DRIVES || _drives[index].present == NO) {
        IOLog("IDE: DMA request for absent drive index %d\n", index);
        return IO_R_NO_DEVICE;
    }
    if (sectors == 0 || sectors > BMIDE_MAX_SECTORS_IO) {
        IOLog("IDE: invalid DMA sector count %u\n", sectors);
        return IO_R_INVALID_ARG;
    }
    if (lba > (_drives[index].sectors - sectors)) {
        IOLog("IDE: DMA beyond end drive %d lba %u sectors %u disk %u\n",
              index, lba, sectors, _drives[index].sectors);
        return IO_R_INVALID_ARG;
    }

    length = sectors * BMIDE_SECTOR_SIZE;
    ataSectorCount = bmideAtaSectorCount(sectors);
    status = 0;
    bmStatus = 0;
    ataError = 0;
    attempt = 1;
    pciStatus = 0;
    [_cmdLock lock];
    if ([self buildPrdForBuffer:buffer length:length client:client] == NO) {
        IOLog("IDE: PRD setup failed, no PIO fallback\n");
        rtn = IO_R_INVALID_ARG;
        goto done;
    }

    drive = &_drives[index];
    regs = &_regs[drive->channel];
    bmBase = bmideBmBaseForChannel(_bmiba, drive->channel);

    if (_diagDmaLogsLeft != 0) {
        IOLog("IDE: DMA %s drive %d ch %d dev %d lba %u sectors %u buf %08x bm %04x prd %08x\n",
              bmideDirectionString(isWrite), index, drive->channel,
              drive->drive, lba, sectors, (unsigned int)buffer, bmBase,
              _prdPhys);
        _diagDmaLogsLeft--;
    }

retryDma:
    bmideStopBmDma(bmBase);
    bmideProgramPrd(bmBase, _prdPhys);

    bmCommand = isWrite ? 0 : BM_CMD_READ;
    outb(bmBase + BM_REG_COMMAND, bmCommand);

    if ([self selectDrive:drive->drive regs:regs] == NO) {
        bmStatus = inb(bmBase + BM_REG_STATUS);
        status = inb(regs->status);
        ataError = inb(regs->error);
        IOLog("IDE: select failed drive %d before DMA BM %02x ATA %02x ERR %02x\n",
              index, bmStatus, status, ataError);
        _dmaAtaErrors++;
        rtn = IO_R_IO;
        goto failedDma;
    }
    if (!bmideWaitMask(regs, ATA_SR_BSY | ATA_SR_DRQ, ATA_SR_DRDY,
                        WAIT_NOT_BUSY_US, &status)) {
        IOLog("IDE: drive %d not ready before DMA status %02x\n",
              index, status);
        bmStatus = inb(bmBase + BM_REG_STATUS);
        ataError = inb(regs->error);
        _dmaAtaErrors++;
        rtn = IO_R_BUSY;
        goto failedDma;
    }

    bmideProgramLba28(regs, drive->drive, lba, ataSectorCount);

    outb(regs->command, isWrite ? ATA_CMD_WRITE_DMA : ATA_CMD_READ_DMA);
    /* Flush the task-file command and allow its status transition before
     * handing the transfer to the bus master (ATA HDMA0 -> HDMA1).
     */
    (void)inb(regs->altStatus);
    IODelay(1); /* DriverKit's microsecond API rounds the 400 ns minimum up. */
    outb(bmBase + BM_REG_COMMAND, bmCommand | BM_CMD_START);

    dmaResult = bmidePollDma(bmBase, regs, WAIT_DMA_US, &completion);
    bmStatus = completion.bmStatus;
    status = completion.ataStatus;
    waited = completion.waited;
    ataError = (dmaResult == BMIDE_DMA_COMPLETE) ? 0 : inb(regs->error);
    bmideFinishBmDma(bmBase, bmCommand, bmStatus);

    if (dmaResult != BMIDE_DMA_COMPLETE) {
        if (dmaResult == BMIDE_DMA_TIMEOUT) {
            _dmaTimeouts++;
            rtn = IO_R_TIMEOUT;
        } else {
            if (dmaResult == BMIDE_DMA_DEVICE_ERROR)
                _dmaAtaErrors++;
            else
                _dmaBmErrors++;
            rtn = IO_R_IO;
        }
        IOLog("IDE: DMA failed drive %d LBA %u result %d waited %u BM %02x ATA %02x ERR %02x\n",
              index, lba, dmaResult, waited, bmStatus, status, ataError);
        goto failedDma;
    }

    if (actual != 0)
        *actual = length;
    rtn = IO_R_SUCCESS;
    goto done;

failedDma:
    bmideStopBmDma(bmBase);
    pciStatusValid = ([self getPCIConfigData:&pciCommandStatus
                                 atRegister:PCI_COMMAND_REG] == IO_R_SUCCESS);
    pciStatus = pciStatusValid ? (pciCommandStatus >> 16) & 0xffff : 0;
    bmideLogDecodedStatus("DMA failure", bmStatus, status, ataError,
                          pciStatus, pciStatusValid);
    _dmaResets++;
    [self softResetChannel:drive->channel];
    (void)bmideWaitNotBusy(regs, 0);
    if (attempt < DMA_MAX_ATTEMPTS) {
        attempt++;
        _dmaRetries++;
        IOLog("IDE: retry DMA %s drive %d LBA %u sectors %u attempt %u rtn %d BM %02x ATA %02x ERR %02x pciStat %04x valid %u counts retry %u timeout %u bmerr %u ataerr %u reset %u\n",
              bmideDirectionString(isWrite), index, lba, sectors, attempt,
              rtn, bmStatus, status, ataError, pciStatus, pciStatusValid, _dmaRetries,
              _dmaTimeouts, _dmaBmErrors, _dmaAtaErrors, _dmaResets);
        goto retryDma;
    }
    IOLog("IDE: final DMA failure %s drive %d ch %u dev %u LBA %u sectors %u rtn %d BM %02x ATA %02x ERR %02x pciStat %04x valid %u counts retry %u timeout %u bmerr %u ataerr %u reset %u\n",
          bmideDirectionString(isWrite), index, drive->channel, drive->drive,
          lba, sectors, rtn, bmStatus, status, ataError, pciStatus, pciStatusValid,
          _dmaRetries,
          _dmaTimeouts, _dmaBmErrors, _dmaAtaErrors, _dmaResets);
    goto done;

done:
    [_cmdLock unlock];
    return rtn;
}

@end
