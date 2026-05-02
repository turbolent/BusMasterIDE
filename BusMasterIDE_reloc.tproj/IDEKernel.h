#ifndef _IDE_KERNEL_H_
#define _IDE_KERNEL_H_

#import <sys/types.h>
#import <driverkit/IODisk.h>

struct proc;
struct uio;
struct buf;

__private_extern__ void bmide_init_idmap(id self);
__private_extern__ IODevAndIdInfo *bmide_idmap(void);
__private_extern__ int bmideopen(dev_t dev, int flag, int devtype, struct proc *pp);
__private_extern__ int bmideclose(dev_t dev, int flag, int devtype, struct proc *pp);
__private_extern__ int bmideread(dev_t dev, struct uio *uiop, int ioflag);
__private_extern__ int bmidewrite(dev_t dev, struct uio *uiop, int ioflag);
__private_extern__ void bmidestrategy(struct buf *bp);
__private_extern__ int bmideioctl(dev_t dev, u_long cmd, caddr_t data, int flag, struct proc *pp);
__private_extern__ int bmidesize(dev_t dev);
__private_extern__ void bmide_block_char_majors(int *blockmajor, int *charmajor);

#endif
