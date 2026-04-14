#include <stdio.h>
#include "platform.h"
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xscugic.h"
#include "xil_exception.h"

// -------------------------------------------------------
// AXI DMA 1 - MM2S with Scatter Gather
// -------------------------------------------------------
#define DMA_BASE_ADDR   0x40410000
#define MM2S_DMACR      (DMA_BASE_ADDR + 0x00)
#define MM2S_DMASR      (DMA_BASE_ADDR + 0x04)
#define MM2S_CURDESC    (DMA_BASE_ADDR + 0x08)
#define MM2S_TAILDESC   (DMA_BASE_ADDR + 0x10)

// -------------------------------------------------------
// Memory layout
//
//  0x0F000000  BD0 (64 bytes, describes FB_A)
//  0x0F000040  BD1 (64 bytes, describes FB_B)
//  0x10000000  FB_A (~3 MB)
//  0x10400000  FB_B (~3 MB)
// -------------------------------------------------------
#define BD0_ADDR        0x0F000000
#define BD1_ADDR        0x0F000040
#define FB_A_ADDR       0x10000000
#define FB_B_ADDR       0x10400000

#define H_VISIBLE       1024
#define V_VISIBLE       768
#define FB_SIZE_BYTES   (H_VISIBLE * V_VISIBLE * 4)

#define BD_CTRL_SOF     (1 << 27)
#define BD_CTRL_EOF     (1 << 26)

#define DMA_IRQ_IOC     (1 << 12)
#define DMA_IRQ_ALL     (7 << 12)
#define DMA_IRQ_EN_IOC  (1 << 12)
#define DMA_ERR_MASK    0x00000770

#if defined(XPAR_AXIDMA_2_DEVICE_ID)
#define DMA2_DEV_ID     XPAR_AXIDMA_2_DEVICE_ID
#elif defined(XPAR_AXI_DMA_2_DEVICE_ID)
#define DMA2_DEV_ID     XPAR_AXI_DMA_2_DEVICE_ID
#else
#define DMA2_DEV_ID     XPAR_AXIDMA_0_DEVICE_ID
#endif

#define DMA2_TEST_WORDS     256
#define DMA2_TEST_BYTES     (DMA2_TEST_WORDS * sizeof(u32))
#define DMA2_TX_BUFFER_ADDR  0x10800000U
#define DMA2_RX_BUFFER_ADDR  0x10801000U

// IRQ_F2P[2] → GIC ID 63
// xlconcat: In0=dma0_mm2s In1=dma0_s2mm In2=dma1_mm2s
#define DMA_IRQ_ID      63

#define MAKE_PIXEL(r,g,b) (((r&0xF)<<8)|((g&0xF)<<4)|(b&0xF))
#define PATTERN_HOLD_FRAMES 120

// -------------------------------------------------------
// SG descriptor - aligned to 0x40 bytes
// -------------------------------------------------------
typedef struct {
    u32 next_desc;
    u32 next_desc_msb;
    u32 buf_addr;
    u32 buf_addr_msb;
    u32 reserved0;
    u32 reserved1;
    u32 control;
    u32 status;
    u32 app[5];
    u32 padding[3];
} __attribute__((aligned(0x40))) sg_desc_t;

// -------------------------------------------------------
// Shared ISR <-> main state
// -------------------------------------------------------
static volatile int  buf_to_fill = -1;
static volatile int  frame_count = 0;
static volatile int  bd_index    = 0;  // which BD just completed
static XScuGic       gic;
static XAxiDma       dma2;
static u32          *const dma2_tx_buffer = (u32 *)DMA2_TX_BUFFER_ADDR;
static u32          *const dma2_rx_buffer = (u32 *)DMA2_RX_BUFFER_ADDR;

// -------------------------------------------------------
// Patterns
// -------------------------------------------------------
typedef enum {
    PATTERN_COLOR_BARS = 0,
    PATTERN_CHECKERBOARD,
    PATTERN_SOLID_RED,
    PATTERN_SOLID_GREEN,
    PATTERN_SOLID_BLUE,
    PATTERN_COUNT
} vga_pattern_t;

void fill_color_bars(u32 base)
{
    u32 colors[8] = {
        MAKE_PIXEL(0xF,0x0,0x0), MAKE_PIXEL(0x0,0xF,0x0),
        MAKE_PIXEL(0x0,0x0,0xF), MAKE_PIXEL(0xF,0xF,0x0),
        MAKE_PIXEL(0x0,0xF,0xF), MAKE_PIXEL(0xF,0x0,0xF),
        MAKE_PIXEL(0xF,0xF,0xF), MAKE_PIXEL(0x0,0x0,0x0),
    };
    for (int y = 0; y < V_VISIBLE; y++)
        for (int x = 0; x < H_VISIBLE; x++)
            Xil_Out32(base + (y*H_VISIBLE+x)*4, colors[x/128]);
}

void fill_checkerboard(u32 base)
{
    for (int y = 0; y < V_VISIBLE; y++)
        for (int x = 0; x < H_VISIBLE; x++) {
            int tile = ((x/32)+(y/32)) & 1;
            Xil_Out32(base + (y*H_VISIBLE+x)*4,
                      tile ? MAKE_PIXEL(0,0,0) : MAKE_PIXEL(0xF,0xF,0xF));
        }
}

void fill_solid(u32 base, u32 color)
{
    for (int y = 0; y < V_VISIBLE; y++)
        for (int x = 0; x < H_VISIBLE; x++)
            Xil_Out32(base + (y*H_VISIBLE+x)*4, color);
}

void fill_pattern(vga_pattern_t p, u32 base)
{
    switch (p) {
    case PATTERN_COLOR_BARS:   fill_color_bars(base);                      break;
    case PATTERN_CHECKERBOARD: fill_checkerboard(base);                    break;
    case PATTERN_SOLID_RED:    fill_solid(base, MAKE_PIXEL(0xF,0x0,0x0)); break;
    case PATTERN_SOLID_GREEN:  fill_solid(base, MAKE_PIXEL(0x0,0xF,0x0)); break;
    case PATTERN_SOLID_BLUE:   fill_solid(base, MAKE_PIXEL(0x0,0x0,0xF)); break;
    default:                   fill_color_bars(base);                      break;
    }
}

static void dma2_fill_tx_pattern(u32 *buf, int words)
{
    for (int i = 0; i < words; i++) {
        buf[i] = 0xA5000000U + (u32)i;
    }
}

static void dma2_clear_rx_buffer(u32 *buf, int words)
{
    for (int i = 0; i < words; i++) {
        buf[i] = 0xDEADBEEFU;
    }
}

static void dma2_print_buffer(const char *name, u32 *buf, int words_to_print)
{
    xil_printf("%s\r\n", name);
    for (int i = 0; i < words_to_print; i++) {
        xil_printf("  [%d] = 0x%08lx\r\n", i, (unsigned long)buf[i]);
    }
}

static int dma2_compare_buffers(u32 *tx, u32 *rx, int words)
{
    for (int i = 0; i < words; i++) {
        if (tx[i] != rx[i]) {
            xil_printf("Mismatch at index %d : TX=0x%08lx RX=0x%08lx\r\n",
                       i, (unsigned long)tx[i], (unsigned long)rx[i]);
            return XST_FAILURE;
        }
    }
    return XST_SUCCESS;
}

static int dma2_wait_done(XAxiDma *InstancePtr, int direction)
{
    int timeout = 10000000;

    while (timeout > 0) {
        if (!XAxiDma_Busy(InstancePtr, direction)) {
            return XST_SUCCESS;
        }
        timeout--;
    }

    xil_printf("Timeout on DMA channel %s\r\n",
               (direction == XAXIDMA_DMA_TO_DEVICE) ? "MM2S" : "S2MM");
    return XST_FAILURE;
}

static void dma2_print_status(void)
{
    u32 mm2s_sr = XAxiDma_ReadReg(dma2.RegBase, XAXIDMA_SR_OFFSET);
    u32 s2mm_sr = XAxiDma_ReadReg(dma2.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);

    xil_printf("DMA2 MM2S_DMASR = 0x%08lx\r\n", (unsigned long)mm2s_sr);
    xil_printf("DMA2 S2MM_DMASR = 0x%08lx\r\n", (unsigned long)s2mm_sr);
}

static int run_dma2_loopback_test(void)
{
    XAxiDma_Config *cfg;
    int status;

    xil_printf("=== AXI DMA 2 loopback test ===\r\n");
    xil_printf("TX=0x%08lx RX=0x%08lx BYTES=%lu\r\n",
               (unsigned long)DMA2_TX_BUFFER_ADDR,
               (unsigned long)DMA2_RX_BUFFER_ADDR,
               (unsigned long)DMA2_TEST_BYTES);

    cfg = XAxiDma_LookupConfig(DMA2_DEV_ID);
    if (!cfg) {
        xil_printf("ERROR: No DMA2 config found\r\n");
        return XST_FAILURE;
    }

    status = XAxiDma_CfgInitialize(&dma2, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA2 init failed\r\n");
        return XST_FAILURE;
    }

    if (XAxiDma_HasSg(&dma2)) {
        xil_printf("ERROR: DMA2 is configured in SG mode, but simple mode is expected\r\n");
        return XST_FAILURE;
    }

    xil_printf("DMA2 init OK\r\n");

    dma2_fill_tx_pattern(dma2_tx_buffer, DMA2_TEST_WORDS);
    dma2_clear_rx_buffer(dma2_rx_buffer, DMA2_TEST_WORDS);

    xil_printf("Before transfer:\r\n");
    dma2_print_buffer("TX first words:", dma2_tx_buffer, 8);
    dma2_print_buffer("RX first words:", dma2_rx_buffer, 8);

    Xil_DCacheFlushRange((UINTPTR)dma2_tx_buffer, DMA2_TEST_BYTES);
    Xil_DCacheInvalidateRange((UINTPTR)dma2_rx_buffer, DMA2_TEST_BYTES);

    status = XAxiDma_SimpleTransfer(&dma2,
                                    (UINTPTR)dma2_rx_buffer,
                                    DMA2_TEST_BYTES,
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM transfer start failed\r\n");
        dma2_print_status();
        return XST_FAILURE;
    }

    status = XAxiDma_SimpleTransfer(&dma2,
                                    (UINTPTR)dma2_tx_buffer,
                                    DMA2_TEST_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S transfer start failed\r\n");
        dma2_print_status();
        return XST_FAILURE;
    }

    status = dma2_wait_done(&dma2, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S did not complete\r\n");
        dma2_print_status();
        return XST_FAILURE;
    }

    status = dma2_wait_done(&dma2, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM did not complete\r\n");
        dma2_print_status();
        return XST_FAILURE;
    }

    Xil_DCacheInvalidateRange((UINTPTR)dma2_rx_buffer, DMA2_TEST_BYTES);

    xil_printf("After transfer:\r\n");
    dma2_print_buffer("TX first words:", dma2_tx_buffer, 8);
    dma2_print_buffer("RX first words:", dma2_rx_buffer, 8);

    status = dma2_compare_buffers(dma2_tx_buffer, dma2_rx_buffer, DMA2_TEST_WORDS);
    if (status == XST_SUCCESS) {
        xil_printf("SUCCESS: loopback data matches\r\n");
    } else {
        xil_printf("FAIL: loopback data mismatch\r\n");
    }

    dma2_print_status();
    return status;
}

// -------------------------------------------------------
// ISR
//
// The DMA stops when it reaches TAILDESC. To keep the ring
// running we need to:
//   1. Identify which BD completed (via CURDESC)
//   2. Clear that BD's status and flush it
//   3. Rewrite TAILDESC pointing to the BD before the current one
//      -> this re-queues the entire ring
// -------------------------------------------------------
void dma_isr(void *callback)
{
    u32 sr = Xil_In32(MM2S_DMASR);
    Xil_Out32(MM2S_DMASR, DMA_IRQ_ALL);  // clear flags

    if (sr & DMA_ERR_MASK) {
        xil_printf("DMA ERROR! DMASR=0x%08X\r\n", sr);
        return;
    }

    if (!(sr & DMA_IRQ_IOC))
        return;

    // Determine which BD was just processed by the DMA.
    // After completing BD1, CURDESC advances to BD0 (BD1's next_desc).
    // After completing BD0, CURDESC advances to BD1.
    // So the completed BD is the one before the current CURDESC.
    u32 curdesc = Xil_In32(MM2S_CURDESC);
    int completed_bd = (curdesc == BD0_ADDR) ? 1 : 0;

    // Clear the completed BD status so it can be reused
    sg_desc_t *bd = (sg_desc_t *)(completed_bd == 0 ? BD0_ADDR : BD1_ADDR);
    bd->status = 0;
    Xil_DCacheFlushRange((u32)bd, sizeof(sg_desc_t));

    // Signal to main which buffer is free to write
    buf_to_fill = completed_bd;
    frame_count++;

    // Re-arm the DMA by writing TAILDESC = the BD that just completed.
    // The DMA is idle pointing to the next BD (curdesc).
    // Writing the previous BD as the new tail makes the DMA process
    // curdesc -> ... -> new tail, keeping the ring running.
    u32 new_tail = (completed_bd == 0) ? BD0_ADDR : BD1_ADDR;
    Xil_Out32(MM2S_TAILDESC, new_tail);
}

// -------------------------------------------------------
// GIC
// -------------------------------------------------------
int gic_init(void)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if (!cfg) return -1;

    if (XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) != XST_SUCCESS)
        return -1;

    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);
    Xil_ExceptionEnable();

    XScuGic_Connect(&gic, DMA_IRQ_ID,
        (Xil_InterruptHandler)dma_isr, NULL);
    XScuGic_Enable(&gic, DMA_IRQ_ID);

    return 0;
}

// -------------------------------------------------------
// Initialize SG and start it
// -------------------------------------------------------
void sg_init(void)
{
    sg_desc_t *bd0 = (sg_desc_t *)BD0_ADDR;
    sg_desc_t *bd1 = (sg_desc_t *)BD1_ADDR;

    bd0->next_desc     = BD1_ADDR;
    bd0->next_desc_msb = 0;
    bd0->buf_addr      = FB_A_ADDR;
    bd0->buf_addr_msb  = 0;
    bd0->reserved0     = 0;
    bd0->reserved1     = 0;
    bd0->control       = FB_SIZE_BYTES | BD_CTRL_SOF | BD_CTRL_EOF;
    bd0->status        = 0;

    bd1->next_desc     = BD0_ADDR;
    bd1->next_desc_msb = 0;
    bd1->buf_addr      = FB_B_ADDR;
    bd1->buf_addr_msb  = 0;
    bd1->reserved0     = 0;
    bd1->reserved1     = 0;
    bd1->control       = FB_SIZE_BYTES | BD_CTRL_SOF | BD_CTRL_EOF;
    bd1->status        = 0;

    Xil_DCacheFlushRange(BD0_ADDR, 2 * sizeof(sg_desc_t));

    // Reset
    Xil_Out32(MM2S_DMACR, 0x4);
    while (Xil_In32(MM2S_DMACR) & 0x4);

    // CURDESC before the run bit
    Xil_Out32(MM2S_CURDESC, BD0_ADDR);

    // Run + IOC interrupt enabled
    Xil_Out32(MM2S_DMACR, 0x1 | DMA_IRQ_EN_IOC);

    // Start by processing BD0 and BD1
    Xil_Out32(MM2S_TAILDESC, BD1_ADDR);
}

// -------------------------------------------------------
// Main
// -------------------------------------------------------
int main()
{
    init_platform();
    xil_printf("=== VGA SG Double Buffer ===\r\n");

    if (run_dma2_loopback_test() != XST_SUCCESS) {
        xil_printf("DMA2 test failed, aborting before VGA SG\r\n");
        cleanup_platform();
        return -1;
    }

    // Fill both buffers before enabling the DMA
    xil_printf("Preparing FB_A (color bars)...\r\n");
    fill_color_bars(FB_A_ADDR);
    Xil_DCacheFlushRange(FB_A_ADDR, FB_SIZE_BYTES);

    xil_printf("Preparing FB_B (checkerboard)...\r\n");
    fill_checkerboard(FB_B_ADDR);
    Xil_DCacheFlushRange(FB_B_ADDR, FB_SIZE_BYTES);

    if (gic_init() != 0) {
        xil_printf("GIC init failed\r\n");
        cleanup_platform();
        return -1;
    }

    sg_init();
    xil_printf("DMA running\r\n");

    int next_pattern = PATTERN_SOLID_RED;
    int hold_counter = 0;

    while (1) {
        if (buf_to_fill < 0)
            continue;

        int buf  = buf_to_fill;
        buf_to_fill = -1;

        u32 base = (buf == 0) ? FB_A_ADDR : FB_B_ADDR;

        fill_pattern((vga_pattern_t)next_pattern, base);
        Xil_DCacheFlushRange(base, FB_SIZE_BYTES);

        hold_counter++;
        if (hold_counter >= PATTERN_HOLD_FRAMES) {
            hold_counter = 0;
            xil_printf("Frame %d, pattern %d -> buf %c\r\n",
                       frame_count, next_pattern, buf == 0 ? 'A' : 'B');
            next_pattern = (next_pattern + 1) % PATTERN_COUNT;
        }
    }

    cleanup_platform();
    return 0;
}