#import "IDE.h"
#import "IDEKernel.h"

#import <driverkit/kernelDiskMethods.h>
#import <driverkit/kernelDriver.h>
#import <driverkit/generalFuncs.h>
#import <driverkit/IODiskPartition.h>
#import <bsd/dev/ldd.h>
#import <sys/buf.h>
#import <sys/uio.h>
#import <sys/errno.h>
#import <sys/fcntl.h>
#import <sys/systm.h>

typedef struct {
    struct buf *physbuf;
} BMIDEDev;

typedef struct {
    unsigned short type;
    unsigned char control_byte;
    unsigned char interleave;
    unsigned int total_sectors;
    unsigned short cylinders;
    unsigned char heads;
    unsigned char sectors_per_trk;
    unsigned int bytes_per_sector;
    unsigned int access_time;
    unsigned short precomp;
    unsigned short landing_zone;
} BMIDECompatDriveInfo;

#define BMIDE_IDEDIOCINFO      0x40186901

static IODevAndIdInfo bmideIdMap[BMIDE_MAX_DRIVES];
static BMIDEDev bmideDev[BMIDE_MAX_DRIVES];
static int bmideBlockMajor = -1;
static int bmideRawMajor = -1;
static int bmideIoctlLogsLeft = 0;
static int bmideLabelLogsLeft = 0;
static int bmideIoctlReturnLogsLeft = 0;
static int bmideCloseLogsLeft = 0;
static int bmidePsizeLogsLeft = 0;

static unsigned bmideminphys(struct buf *bp);
static id bmide_dev_to_id(dev_t dev);

__private_extern__ void
bmide_init_idmap(id self)
{
    int unit;

    bmideBlockMajor = [self blockMajor];
    bmideRawMajor = [self characterMajor];
    IOLog("IDE: init id map block major %d raw major %d\n",
          bmideBlockMajor, bmideRawMajor);
    bzero(bmideIdMap, sizeof(bmideIdMap));
    bzero(bmideDev, sizeof(bmideDev));

    for (unit = 0; unit < BMIDE_MAX_DRIVES; unit++) {
        bmideIdMap[unit].rawDev =
            makedev(bmideRawMajor, (unit << 3));
        bmideIdMap[unit].blockDev =
            makedev(bmideBlockMajor, (unit << 3));
        bmideDev[unit].physbuf =
            (struct buf *)IOMalloc(sizeof(struct buf));
        if (bmideDev[unit].physbuf != 0)
            bmideDev[unit].physbuf->b_flags = 0;
    }
}

__private_extern__ IODevAndIdInfo *
bmide_idmap(void)
{
    return bmideIdMap;
}

__private_extern__ int
bmideopen(dev_t dev, int flag, int devtype, struct proc *pp)
{
    id diskObj;

    diskObj = bmide_dev_to_id(dev);
    if (diskObj == nil)
        return ENXIO;
    if ([diskObj isDiskReady:NO])
        return ENXIO;

    if (IO_DISK_PART(dev) != BMIDE_LIVE_PART) {
        if (major(dev) == bmideBlockMajor)
            [diskObj setBlockDeviceOpen:YES];
        else
            [diskObj setRawDeviceOpen:YES];
    }
    return 0;
}

__private_extern__ int
bmideclose(dev_t dev, int flag, int devtype, struct proc *pp)
{
    id diskObj;

    diskObj = bmide_dev_to_id(dev);
    if (diskObj == nil)
        return ENXIO;

    if (bmideCloseLogsLeft > 0) {
        IOLog("IDE: close dev %08x unit %d part %d major %d blockMajor %d rawMajor %d\n",
              (unsigned int)dev, IO_DISK_UNIT(dev), IO_DISK_PART(dev),
              major(dev), bmideBlockMajor, bmideRawMajor);
        bmideCloseLogsLeft--;
    }

    if (IO_DISK_PART(dev) == BMIDE_LIVE_PART)
        return 0;
    if (![diskObj isInstanceOpen])
        return ENXIO;

    if (major(dev) == bmideBlockMajor)
        [diskObj setBlockDeviceOpen:NO];
    else
        [diskObj setRawDeviceOpen:NO];

    return 0;
}

__private_extern__ int
bmideread(dev_t dev, struct uio *uiop, int ioflag)
{
    id diskObj;
    int unit;

    diskObj = bmide_dev_to_id(dev);
    unit = IO_DISK_UNIT(dev);
    if (diskObj == nil || unit >= BMIDE_MAX_DRIVES ||
        bmideDev[unit].physbuf == 0)
        return ENXIO;

    return physio((int (*)())bmidestrategy,
                  bmideDev[unit].physbuf, dev, B_READ,
                  bmideminphys, uiop, [diskObj blockSize]);
}

__private_extern__ int
bmidewrite(dev_t dev, struct uio *uiop, int ioflag)
{
    id diskObj;
    int unit;

    diskObj = bmide_dev_to_id(dev);
    unit = IO_DISK_UNIT(dev);
    if (diskObj == nil || unit >= BMIDE_MAX_DRIVES ||
        bmideDev[unit].physbuf == 0)
        return ENXIO;

    return physio((int (*)())bmidestrategy,
                  bmideDev[unit].physbuf, dev, B_WRITE,
                  bmideminphys, uiop, [diskObj blockSize]);
}

__private_extern__ void
bmidestrategy(struct buf *bp)
{
    id diskObj;
    vm_task_t client;
    IOReturn rtn;

    diskObj = bmide_dev_to_id(bp->b_dev);
    if (diskObj == nil) {
        IOLog("IDE: strategy no disk for dev %08x blk %u flags %x\n",
              (unsigned int)bp->b_dev, (unsigned int)bp->b_blkno,
              (unsigned int)bp->b_flags);
        bp->b_error = ENXIO;
        goto bad;
    }

    if ((bp->b_flags & (B_PHYS | B_KERNSPACE)) == B_PHYS)
        client = IOVmTaskForBuf(bp);
    else
        client = IOVmTaskSelf();

    if (bp->b_flags & B_READ)
        rtn = [diskObj readAsyncAt:bp->b_blkno
                            length:bp->b_bcount
                            buffer:(unsigned char *)bp->b_un.b_addr
                           pending:bp
                            client:client];
    else
        rtn = [diskObj writeAsyncAt:bp->b_blkno
                             length:bp->b_bcount
                             buffer:(unsigned char *)bp->b_un.b_addr
                            pending:bp
                             client:client];

    if (rtn != IO_R_SUCCESS) {
        IOLog("IDE: strategy failed dev %08x blk %u count %u flags %x rtn %d\n",
              (unsigned int)bp->b_dev, (unsigned int)bp->b_blkno,
              (unsigned int)bp->b_bcount, (unsigned int)bp->b_flags, rtn);
        bp->b_error = [diskObj errnoFromReturn:rtn];
        goto bad;
    }
    return;

bad:
    bp->b_flags |= B_ERROR;
    bp->b_resid = bp->b_bcount;
    biodone(bp);
}

__private_extern__ int
bmideioctl(dev_t dev, u_long cmd, caddr_t data, int flag, struct proc *pp)
{
    int unit;
    id diskObj;
    IODevAndIdInfo *idmap;
    IOReturn irtn;
    int rtn;
    int nblk;
    int i;

    unit = IO_DISK_UNIT(dev);
    if (unit >= BMIDE_MAX_DRIVES)
        return ENXIO;

    idmap = &bmideIdMap[unit];
    switch (cmd) {
      case DKIOCSFORMAT:
      case DKIOCGFORMAT:
      case DKIOCGLABEL:
      case DKIOCSLABEL:
        diskObj = idmap->partitionId[0];
        break;

      case DKIOCINFO:
      case DKIOCBLKSIZE:
      case DKIOCNUMBLKS:
      case BMIDE_IDEDIOCINFO:
        diskObj = idmap->liveId;
        break;

      default:
        IOLog("IDE: unsupported ioctl dev %08x cmd %08x\n",
              (unsigned int)dev, (unsigned int)cmd);
        return EINVAL;
    }

    if (bmideIoctlLogsLeft > 0) {
        IOLog("IDE: ioctl dev %08x cmd %08x unit %d part %d\n",
              (unsigned int)dev, (unsigned int)cmd,
              unit, IO_DISK_PART(dev));
        bmideIoctlLogsLeft--;
    }

    if (diskObj == nil) {
        IOLog("IDE: ioctl no disk for dev %08x cmd %08x\n",
              (unsigned int)dev, (unsigned int)cmd);
        return ENXIO;
    }

    rtn = 0;
    irtn = IO_R_SUCCESS;
    switch (cmd) {
      case DKIOCINFO:
        {
            struct drive_info info;

            bzero(&info, sizeof(info));
            strcpy(info.di_name, [diskObj driveName]);
            info.di_devblklen = [diskObj blockSize];
            info.di_maxbcount = BMIDE_MAX_PHYS_IO;
            if (info.di_devblklen)
                nblk = howmany(sizeof(struct disk_label),
                               info.di_devblklen);
            else
                nblk = 0;
            for (i = 0; i < NLABELS; i++)
                info.di_label_blkno[i] = nblk * i;
            *(struct drive_info *)data = info;
        }
        break;

      case DKIOCBLKSIZE:
        *(int *)data = [diskObj blockSize];
        break;

      case DKIOCNUMBLKS:
        *(int *)data = [diskObj diskSize];
        break;

      case BMIDE_IDEDIOCINFO:
        {
            BMIDECompatDriveInfo info;
            unsigned int total;
            unsigned int cylinders;

            bzero(&info, sizeof(info));
            total = [diskObj diskSize];
            info.type = 1;
            info.total_sectors = total;
            info.bytes_per_sector = [diskObj blockSize];
            info.heads = 16;
            info.sectors_per_trk = 63;
            cylinders = total / (info.heads * info.sectors_per_trk);
            if (cylinders > 65535)
                cylinders = 65535;
            info.cylinders = (unsigned short)cylinders;
            info.landing_zone = info.cylinders;
            *(BMIDECompatDriveInfo *)data = info;
        }
        break;

      case DKIOCGLABEL:
        {
            struct disk_label *labelp;
            struct disk_label *userLabelp;

            if (bmideLabelLogsLeft > 0) {
                IOLog("IDE: DKIOCGLABEL begin dev %08x obj %08x live %08x part0 %08x argp %08x size %u\n",
                      (unsigned int)dev, (unsigned int)diskObj,
                      (unsigned int)idmap->liveId,
                      (unsigned int)idmap->partitionId[0],
                      (unsigned int)data,
                      (unsigned int)sizeof(*labelp));
            }
            labelp = (struct disk_label *)IOMalloc(sizeof(*labelp));
            if (labelp == 0) {
                if (bmideLabelLogsLeft > 0) {
                    IOLog("IDE: DKIOCGLABEL IOMalloc failed size %u\n",
                          (unsigned int)sizeof(*labelp));
                    bmideLabelLogsLeft--;
                }
                return ENOMEM;
            }
            if (bmideLabelLogsLeft > 0) {
                IOLog("IDE: DKIOCGLABEL readLabel start label %08x\n",
                      (unsigned int)labelp);
            }
            irtn = [diskObj readLabel:labelp];
            if (bmideLabelLogsLeft > 0) {
                IOLog("IDE: DKIOCGLABEL readLabel done irtn %d\n",
                      irtn);
            }
            if (irtn == IO_R_SUCCESS) {
                userLabelp = *(struct disk_label **)data;
                if (bmideLabelLogsLeft > 0) {
                    IOLog("IDE: DKIOCGLABEL copyout label to user %08x\n",
                          (unsigned int)userLabelp);
                }
                if (userLabelp == 0)
                    rtn = EFAULT;
                else
                    rtn = copyout((caddr_t)labelp, (caddr_t)userLabelp,
                                  sizeof(*labelp));
                if (bmideLabelLogsLeft > 0) {
                    IOLog("IDE: DKIOCGLABEL copyout done rtn %d\n", rtn);
                }
            }
            IOFree(labelp, sizeof(*labelp));
            if (bmideLabelLogsLeft > 0) {
                IOLog("IDE: DKIOCGLABEL free done\n");
                bmideLabelLogsLeft--;
            }
        }
        break;

      case DKIOCSLABEL:
        {
            struct disk_label *labelp;
            struct disk_label *userLabelp;

            labelp = (struct disk_label *)IOMalloc(sizeof(*labelp));
            if (labelp == 0)
                return ENOMEM;
            userLabelp = *(struct disk_label **)data;
            if (userLabelp == 0)
                rtn = EFAULT;
            else
                rtn = copyin((caddr_t)userLabelp, (caddr_t)labelp,
                             sizeof(*labelp));
            if (rtn == 0)
                irtn = [diskObj writeLabel:labelp];
            IOFree(labelp, sizeof(*labelp));
        }
        break;

      case DKIOCGFORMAT:
        *(int *)data = [diskObj isFormatted];
        break;

      case DKIOCSFORMAT:
        irtn = [diskObj setFormatted:(*(u_int *)data)];
        break;

      default:
        return EINVAL;
    }

    if (irtn)
        rtn = [diskObj errnoFromReturn:irtn];
    if (bmideIoctlReturnLogsLeft > 0) {
        IOLog("IDE: ioctl return dev %08x cmd %08x irtn %d rtn %d\n",
              (unsigned int)dev, (unsigned int)cmd, irtn, rtn);
        bmideIoctlReturnLogsLeft--;
    }
    return rtn;
}

__private_extern__ int
bmidesize(dev_t dev)
{
    id diskObj;

    diskObj = bmide_dev_to_id(dev);
    if (diskObj == nil)
        return -1;

    if (bmidePsizeLogsLeft > 0) {
        IOLog("IDE: psize dev %08x blockSize %d\n",
              (unsigned int)dev, [diskObj blockSize]);
        bmidePsizeLogsLeft--;
    }
    return [diskObj blockSize];
}

__private_extern__ void
bmide_block_char_majors(int *blockmajor, int *charmajor)
{
    *blockmajor = bmideBlockMajor;
    *charmajor = bmideRawMajor;
}

static unsigned
bmideminphys(struct buf *bp)
{
    if (bp->b_bcount > BMIDE_MAX_PHYS_IO)
        bp->b_bcount = BMIDE_MAX_PHYS_IO;
    return bp->b_bcount;
}

static id
bmide_dev_to_id(dev_t dev)
{
    int unit;
    int part;
    IODevAndIdInfo *idmap;

    unit = IO_DISK_UNIT(dev);
    part = IO_DISK_PART(dev);
    if (unit >= BMIDE_MAX_DRIVES || part >= BMIDE_NUM_PART)
        return nil;

    idmap = &bmideIdMap[unit];
    if (part == BMIDE_LIVE_PART) {
        if (major(dev) == bmideBlockMajor)
            return nil;
        return idmap->liveId;
    }
    return idmap->partitionId[part];
}
