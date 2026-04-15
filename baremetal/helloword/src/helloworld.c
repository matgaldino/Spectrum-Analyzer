#include <stdio.h>
#include "platform.h"
#include "xaxidma.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xscugic.h"
#include "xil_exception.h"

#define DMA_BASE_ADDR   0x40410000
#define MM2S_DMACR      (DMA_BASE_ADDR + 0x00)
#define MM2S_DMASR      (DMA_BASE_ADDR + 0x04)
#define MM2S_CURDESC    (DMA_BASE_ADDR + 0x08)
#define MM2S_TAILDESC   (DMA_BASE_ADDR + 0x10)

// -------------------------------------------------------
// Memory layout
//
//  0x0F000000  BD0 — FB_A terço 0 (SOF)
//  0x0F000040  BD1 — FB_A terço 1
//  0x0F000080  BD2 — FB_A terço 2 (EOF) ← IRQ aqui
//  0x0F0000C0  BD3 — FB_B terço 0 (SOF)
//  0x0F000100  BD4 — FB_B terço 1
//  0x0F000140  BD5 — FB_B terço 2 (EOF) ← IRQ aqui
//  0x10000000  FB_A (~3 MB)
//  0x10400000  FB_B (~3 MB)
// -------------------------------------------------------
#define BD0_ADDR        0x0F000000
#define BD1_ADDR        0x0F000040
#define BD2_ADDR        0x0F000080
#define BD3_ADDR        0x0F0000C0
#define BD4_ADDR        0x0F000100
#define BD5_ADDR        0x0F000140

#define FB_A_ADDR       0x10000000
#define FB_B_ADDR       0x10400000

#define H_VISIBLE       1024
#define V_VISIBLE       768
#define FB_SIZE_BYTES   (H_VISIBLE * V_VISIBLE * 4)
#define BD_CHUNK_BYTES  (FB_SIZE_BYTES / 3)  // 1,048,576 bytes = 256 linhas por BD

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

#define DMA2_TEST_WORDS      256
#define DMA2_TEST_BYTES      (DMA2_TEST_WORDS * sizeof(u32))
#define DMA2_TX_BUFFER_ADDR  0x10800000U
#define DMA2_RX_BUFFER_ADDR  0x10801000U

#define DMA_IRQ_ID      63

#define MAKE_PIXEL(r,g,b) (((r&0xF)<<8)|((g&0xF)<<4)|(b&0xF))
#define PATTERN_HOLD_FRAMES 120

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

static volatile int  buf_to_fill = -1;
static volatile int  frame_count = 0;
static XScuGic       gic;
static XAxiDma       dma2;
static u32          *const dma2_tx_buffer = (u32 *)DMA2_TX_BUFFER_ADDR;
static u32          *const dma2_rx_buffer = (u32 *)DMA2_RX_BUFFER_ADDR;

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
    for (int i = 0; i < words; i++)
        buf[i] = 0xA5000000U + (u32)i;
}

static void dma2_clear_rx_buffer(u32 *buf, int words)
{
    for (int i = 0; i < words; i++)
        buf[i] = 0xDEADBEEFU;
}

static void dma2_print_buffer(const char *name, u32 *buf, int words_to_print)
{
    xil_printf("%s\r\n", name);
    for (int i = 0; i < words_to_print; i++)
        xil_printf("  [%d] = 0x%08lx\r\n", i, (unsigned long)buf[i]);
}

static int dma2_compare_buffers(u32 *tx, u32 *rx, int words)
{
    for (int i = 0; i < words; i++) {
        if (tx[i] != rx[i]) {
            xil_printf("Mismatch at %d: TX=0x%08lx RX=0x%08lx\r\n",
                       i, (unsigned long)tx[i], (unsigned long)rx[i]);
            return XST_FAILURE;
        }
    }
    return XST_SUCCESS;
}

static int dma2_wait_done(XAxiDma *inst, int dir)
{
    int timeout = 10000000;
    while (timeout-- > 0)
        if (!XAxiDma_Busy(inst, dir)) return XST_SUCCESS;
    xil_printf("Timeout on DMA channel %s\r\n",
               (dir == XAXIDMA_DMA_TO_DEVICE) ? "MM2S" : "S2MM");
    return XST_FAILURE;
}

static void dma2_print_status(void)
{
    xil_printf("DMA2 MM2S_DMASR = 0x%08lx\r\n",
               (unsigned long)XAxiDma_ReadReg(dma2.RegBase, XAXIDMA_SR_OFFSET));
    xil_printf("DMA2 S2MM_DMASR = 0x%08lx\r\n",
               (unsigned long)XAxiDma_ReadReg(dma2.RegBase,
               XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET));
}

static int run_dma2_loopback_test(void)
{
    XAxiDma_Config *cfg;
    int status;

    xil_printf("=== AXI DMA 2 loopback test ===\r\n");

    cfg = XAxiDma_LookupConfig(DMA2_DEV_ID);
    if (!cfg) { xil_printf("ERROR: No DMA2 config\r\n"); return XST_FAILURE; }

    status = XAxiDma_CfgInitialize(&dma2, cfg);
    if (status != XST_SUCCESS) { xil_printf("ERROR: DMA2 init\r\n"); return XST_FAILURE; }

    if (XAxiDma_HasSg(&dma2)) {
        xil_printf("ERROR: DMA2 in SG mode, simple expected\r\n");
        return XST_FAILURE;
    }

    dma2_fill_tx_pattern(dma2_tx_buffer, DMA2_TEST_WORDS);
    dma2_clear_rx_buffer(dma2_rx_buffer, DMA2_TEST_WORDS);
    dma2_print_buffer("TX:", dma2_tx_buffer, 8);
    dma2_print_buffer("RX:", dma2_rx_buffer, 8);

    Xil_DCacheFlushRange((UINTPTR)dma2_tx_buffer, DMA2_TEST_BYTES);
    Xil_DCacheInvalidateRange((UINTPTR)dma2_rx_buffer, DMA2_TEST_BYTES);

    status = XAxiDma_SimpleTransfer(&dma2, (UINTPTR)dma2_rx_buffer,
                                    DMA2_TEST_BYTES, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) { dma2_print_status(); return XST_FAILURE; }

    status = XAxiDma_SimpleTransfer(&dma2, (UINTPTR)dma2_tx_buffer,
                                    DMA2_TEST_BYTES, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) { dma2_print_status(); return XST_FAILURE; }

    if (dma2_wait_done(&dma2, XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS) return XST_FAILURE;
    if (dma2_wait_done(&dma2, XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS) return XST_FAILURE;

    Xil_DCacheInvalidateRange((UINTPTR)dma2_rx_buffer, DMA2_TEST_BYTES);
    dma2_print_buffer("RX após:", dma2_rx_buffer, 8);

    status = dma2_compare_buffers(dma2_tx_buffer, dma2_rx_buffer, DMA2_TEST_WORDS);
    xil_printf("%s\r\n", status == XST_SUCCESS ? "SUCCESS" : "FAIL");
    dma2_print_status();
    return status;
}

// -------------------------------------------------------
// ISR
//
// O IRQ só dispara quando um BD com EOF completa.
// BD2 = EOF de FB_A → CURDESC avança para BD3
// BD5 = EOF de FB_B → CURDESC avança para BD0
//
// Para cada frame completado:
//   1. Limpa status dos 3 BDs do frame
//   2. Sinaliza buf_to_fill para o main
//   3. Re-arma com TAILDESC = BD do EOF completado
// -------------------------------------------------------
void dma_isr(void *callback)
{
    u32 sr = Xil_In32(MM2S_DMASR);
    Xil_Out32(MM2S_DMASR, DMA_IRQ_ALL);

    if (!(sr & DMA_IRQ_IOC)) return;
    if (sr & DMA_ERR_MASK) {
        xil_printf("DMA ERROR! DMASR=0x%08X\r\n", sr);
        return;
    }

    // Invalida cache antes de ler status — DMA escreveu direto na DDR
    Xil_DCacheInvalidateRange(BD0_ADDR, 6 * sizeof(sg_desc_t));

    sg_desc_t *bd2 = (sg_desc_t *)BD2_ADDR;
    sg_desc_t *bd5 = (sg_desc_t *)BD5_ADDR;

    // Bit 31 do status = Cmplt, setado pelo DMA quando o BD é concluído
    int fb_a_done = (bd2->status & 0x80000000) ? 1 : 0;
    int fb_b_done = (bd5->status & 0x80000000) ? 1 : 0;

    if (fb_a_done) {
        ((sg_desc_t *)BD0_ADDR)->status = 0;
        ((sg_desc_t *)BD1_ADDR)->status = 0;
        bd2->status = 0;
        Xil_DCacheFlushRange(BD0_ADDR, 3 * sizeof(sg_desc_t));
        buf_to_fill = 0;
        frame_count++;
        Xil_Out32(MM2S_TAILDESC, BD2_ADDR);
    }

    if (fb_b_done) {
        ((sg_desc_t *)BD3_ADDR)->status = 0;
        ((sg_desc_t *)BD4_ADDR)->status = 0;
        bd5->status = 0;
        Xil_DCacheFlushRange(BD3_ADDR, 3 * sizeof(sg_desc_t));
        buf_to_fill = 1;
        frame_count++;
        Xil_Out32(MM2S_TAILDESC, BD5_ADDR);
    }
}

int gic_init(void)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if (!cfg) return -1;

    if (XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) != XST_SUCCESS)
        return -1;

    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
        (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);
    Xil_ExceptionEnable();

    XScuGic_Connect(&gic, DMA_IRQ_ID, (Xil_InterruptHandler)dma_isr, NULL);
    XScuGic_Enable(&gic, DMA_IRQ_ID);
    return 0;
}

// -------------------------------------------------------
// Anel de 6 BDs:
//
//  BD0(SOF)→BD1→BD2(EOF)→BD3(SOF)→BD4→BD5(EOF)→BD0...
//   |←────── FB_A ──────→||←────── FB_B ──────→|
//
// Cada BD cobre 256 linhas (1/3 do frame = 1 MB)
// IRQ dispara apenas nos BDs com EOF (BD2 e BD5)
// -------------------------------------------------------
void sg_init(void)
{
    sg_desc_t *bd[6];
    bd[0] = (sg_desc_t *)BD0_ADDR;
    bd[1] = (sg_desc_t *)BD1_ADDR;
    bd[2] = (sg_desc_t *)BD2_ADDR;
    bd[3] = (sg_desc_t *)BD3_ADDR;
    bd[4] = (sg_desc_t *)BD4_ADDR;
    bd[5] = (sg_desc_t *)BD5_ADDR;

    u32 next_addrs[6] = { BD1_ADDR, BD2_ADDR, BD3_ADDR,
                          BD4_ADDR, BD5_ADDR, BD0_ADDR };
    u32 buf_addrs[6] = {
        FB_A_ADDR + 0*BD_CHUNK_BYTES,  // BD0: linhas 0..255   de FB_A
        FB_A_ADDR + 1*BD_CHUNK_BYTES,  // BD1: linhas 256..511 de FB_A
        FB_A_ADDR + 2*BD_CHUNK_BYTES,  // BD2: linhas 512..767 de FB_A
        FB_B_ADDR + 0*BD_CHUNK_BYTES,  // BD3: linhas 0..255   de FB_B
        FB_B_ADDR + 1*BD_CHUNK_BYTES,  // BD4: linhas 256..511 de FB_B
        FB_B_ADDR + 2*BD_CHUNK_BYTES,  // BD5: linhas 512..767 de FB_B
    };
    // SOF nos primeiros BDs de cada frame, EOF nos últimos
    u32 ctrl_flags[6] = {
        BD_CTRL_SOF,          // BD0
        0,                    // BD1
        BD_CTRL_EOF,          // BD2
        BD_CTRL_SOF,          // BD3
        0,                    // BD4
        BD_CTRL_EOF,          // BD5
    };

    for (int i = 0; i < 6; i++) {
        bd[i]->next_desc     = next_addrs[i];
        bd[i]->next_desc_msb = 0;
        bd[i]->buf_addr      = buf_addrs[i];
        bd[i]->buf_addr_msb  = 0;
        bd[i]->reserved0     = 0;
        bd[i]->reserved1     = 0;
        bd[i]->control       = BD_CHUNK_BYTES | ctrl_flags[i];
        bd[i]->status        = 0;
    }

    Xil_DCacheFlushRange(BD0_ADDR, 6 * sizeof(sg_desc_t));

    Xil_Out32(MM2S_DMACR, 0x4);
    while (Xil_In32(MM2S_DMACR) & 0x4);

    Xil_Out32(MM2S_CURDESC, BD0_ADDR);
    Xil_Out32(MM2S_DMACR, 0x1 | DMA_IRQ_EN_IOC);
    Xil_Out32(MM2S_TAILDESC, BD5_ADDR);  // dispara todos os 6 BDs
}

int main()
{
    init_platform();
    xil_printf("=== VGA SG Double Buffer (3 BDs/frame) ===\r\n");
    xil_printf("BD_CHUNK_BYTES = %lu (256 linhas por BD)\r\n",
               (unsigned long)BD_CHUNK_BYTES);

    if (run_dma2_loopback_test() != XST_SUCCESS) {
        xil_printf("DMA2 test failed\r\n");
        cleanup_platform();
        return -1;
    }

    fill_color_bars(FB_A_ADDR);
    Xil_DCacheFlushRange(FB_A_ADDR, FB_SIZE_BYTES);

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

        int buf = buf_to_fill;
        buf_to_fill = -1;

        u32 base = (buf == 0) ? FB_A_ADDR : FB_B_ADDR;

        fill_pattern((vga_pattern_t)next_pattern, base);
        Xil_DCacheFlushRange(base, FB_SIZE_BYTES);

        hold_counter++;
        if (hold_counter >= PATTERN_HOLD_FRAMES) {
            hold_counter = 0;
            xil_printf("Frame %d, pattern %d → buf %c\r\n",
                       frame_count, next_pattern, buf == 0 ? 'A' : 'B');
            next_pattern = (next_pattern + 1) % PATTERN_COUNT;
        }
    }

    cleanup_platform();
    return 0;
}