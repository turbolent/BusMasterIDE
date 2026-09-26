#ifndef _BMIDE_DMA_H_
#define _BMIDE_DMA_H_

/* Private polling code. Include after the DriverKit types and I/O primitives. */
#define BMIDE_DMA_TIMESTAMP_POLL_MASK 0xff
#define BMIDE_DMA_SLEEP_MS            1
#define BMIDE_DMA_SHORT_DELAY_US      5
#define BMIDE_DMA_FAST_POLLS         32
#define BMIDE_BM_START              0x01
#define BMIDE_BM_ACTIVE             0x01
#define BMIDE_BM_ERROR              0x02
#define BMIDE_BM_INTERRUPT          0x04
#define BMIDE_BM_CAPABILITIES       0x60
#define BMIDE_BM_STATUS_PORT        2
#define BMIDE_ATA_ERR               0x01
#define BMIDE_ATA_DRQ               0x08
#define BMIDE_ATA_DF                0x20
#define BMIDE_ATA_BSY               0x80

typedef enum {
    BMIDE_DMA_PENDING,
    BMIDE_DMA_COMPLETE,
    BMIDE_DMA_TIMEOUT,
    BMIDE_DMA_BUS_ERROR,
    BMIDE_DMA_DEVICE_ERROR,
    BMIDE_DMA_INCOMPLETE
} BMIDEDMAResult;

typedef struct {
    unsigned char bmStatus;
    unsigned char ataStatus;
    unsigned int waited;
} BMIDEDMACompletion;

static unsigned int
bmideDmaElapsedUsec(ns_time_t start, ns_time_t end)
{
    ns_time_t elapsed;

    /* OPENSTEP's PIT timestamp can step backward at rollover. That is not
     * an expired command. Do not let unsigned subtraction fabricate a
     * multi-year wait. Round without addition overflow or __umoddi3, which
     * the OPENSTEP kernel does not export. */
    if (end <= start)
        return 0;
    elapsed = ((end - start) - 1ULL) / 1000ULL + 1ULL;
    return elapsed > 0xffffffffULL ? 0xffffffffU : (unsigned int)elapsed;
}

static void
bmideClearBmStatus(unsigned short bmBase)
{
    unsigned char status;

    status = inb(bmBase + BMIDE_BM_STATUS_PORT);
    /* Bits 5/6 are writable capability flags; bits 1/2 are W1C. */
    outb(bmBase + BMIDE_BM_STATUS_PORT,
         (status & BMIDE_BM_CAPABILITIES) | BMIDE_BM_ERROR | BMIDE_BM_INTERRUPT);
}

static void
bmideStopBmDma(unsigned short bmBase)
{
    outb(bmBase, inb(bmBase) & ~BMIDE_BM_START);
    bmideClearBmStatus(bmBase);
}

static void
bmideFinishBmDma(unsigned short bmBase, unsigned char command,
                  unsigned char status)
{
    /* The caller owns the channel and already has the command and pre-STOP
     * status. Preserve capability flags without rereading both registers.
     */
    outb(bmBase, command & ~BMIDE_BM_START);
    outb(bmBase + BMIDE_BM_STATUS_PORT,
         (status & BMIDE_BM_CAPABILITIES) | BMIDE_BM_ERROR | BMIDE_BM_INTERRUPT);
}

static BMIDEDMAResult
bmideDmaClassify(unsigned char bmStatus, unsigned char ataStatus)
{
    if (bmStatus & BMIDE_BM_ERROR)
        return BMIDE_DMA_BUS_ERROR;
    /* Other device status bits are not valid while BSY is asserted. */
    if (ataStatus & BMIDE_ATA_BSY)
        return BMIDE_DMA_PENDING;
    if (ataStatus & (BMIDE_ATA_ERR | BMIDE_ATA_DF))
        return BMIDE_DMA_DEVICE_ERROR;
    if (ataStatus & BMIDE_ATA_DRQ)
        return BMIDE_DMA_PENDING;
    if ((bmStatus & BMIDE_BM_ACTIVE) == 0)
        return BMIDE_DMA_COMPLETE;
    if (bmStatus & BMIDE_BM_INTERRUPT)
        return BMIDE_DMA_INCOMPLETE;
    return BMIDE_DMA_PENDING;
}

static BMIDEDMAResult
bmidePollDma(unsigned short bmBase, BMIDERegs *regs,
             unsigned int timeoutUsec, BMIDEDMACompletion *completion)
{
    ns_time_t start;
    ns_time_t now;
    unsigned int polls;
    unsigned int sleepBudgetUsec;
    unsigned int sampledUsec;
    BMIDEDMAResult result;

    polls = 0;
    sleepBudgetUsec = 0;
    completion->waited = 0;
    /* Command settling belongs before DMA START, not in this polling loop. */
    for (;;) {
        /* Device interrupts are masked while polling. Read regular status
         * directly, then BM status, so completion uses the final task-file
         * status without a second pair of port reads. All checks precede
         * STOP, which would erase evidence of an incomplete transfer.
         */
        completion->ataStatus = inb(regs->status);
        completion->bmStatus = inb(bmBase + BMIDE_BM_STATUS_PORT);
        result = bmideDmaClassify(completion->bmStatus,
                                  completion->ataStatus);
        if (result != BMIDE_DMA_PENDING)
            break;
        if (polls == 0)
            IOGetTimestamp(&start);
        /* Saturate once the bounded fast path has finished. */
        if (polls <= BMIDE_DMA_TIMESTAMP_POLL_MASK)
            polls++;
        if (polls > BMIDE_DMA_TIMESTAMP_POLL_MASK) {
            IOGetTimestamp(&now);
            completion->waited = bmideDmaElapsedUsec(start, now);
            if (completion->waited < sleepBudgetUsec)
                completion->waited = sleepBudgetUsec;
            if (completion->waited >= timeoutUsec) {
                result = BMIDE_DMA_TIMEOUT;
                break;
            }
            /* Channel ownership and the DMA buffer remain held. Let other
             * kernel threads run while the device is busy. Sample status
             * and real elapsed time again after each wakeup. Also bound the
             * number of sleeps if the PIT timestamp stops advancing; never
             * restart the deadline when its counter steps backward. */
            IOSleep(BMIDE_DMA_SLEEP_MS);
            if (timeoutUsec - sleepBudgetUsec <= BMIDE_DMA_SLEEP_MS * 1000U)
                sleepBudgetUsec = timeoutUsec;
            else
                sleepBudgetUsec += BMIDE_DMA_SLEEP_MS * 1000U;
            continue;
        }
        /* Keep short completions cheap: immediate polls followed by at most
         * 224 five-microsecond busy delays before the first sleep. */
        if (polls >= BMIDE_DMA_FAST_POLLS)
            IODelay(BMIDE_DMA_SHORT_DELAY_US);
    }
    /* Elapsed-time diagnostics are consumed only on failure. Avoid a clock
     * read and 64-bit conversion on every successful command.
     */
    if (result != BMIDE_DMA_COMPLETE && polls != 0) {
        IOGetTimestamp(&now);
        /* Preserve the elapsed value that caused timeout if a later clock
         * sample steps backward before the caller logs the failure. */
        sampledUsec = bmideDmaElapsedUsec(start, now);
        if (completion->waited < sampledUsec)
            completion->waited = sampledUsec;
        if (completion->waited < sleepBudgetUsec)
            completion->waited = sleepBudgetUsec;
    }

    /* The caller must preserve this result and snapshot before stopping DMA.
     * Clearing START also clears ACTIVE, including after a short transfer.
     * IRQ is optional: nIEN can suppress it even after a full transfer.
     */
    return result;
}

#endif
