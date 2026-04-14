#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xscugic.h"
#include "xil_exception.h"

// -------------------------------------------------------
// AXI DMA 1 - MM2S com Scatter Gather
// -------------------------------------------------------
#define DMA_BASE_ADDR   0x40410000
#define MM2S_DMACR      (DMA_BASE_ADDR + 0x00)
#define MM2S_DMASR      (DMA_BASE_ADDR + 0x04)
#define MM2S_CURDESC    (DMA_BASE_ADDR + 0x08)
#define MM2S_TAILDESC   (DMA_BASE_ADDR + 0x10)

// -------------------------------------------------------
// Layout de memória
//
//  0x0F000000  BD0 (64 bytes, descreve FB_A)
//  0x0F000040  BD1 (64 bytes, descreve FB_B)
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

// IRQ_F2P[2] → GIC ID 63
// xlconcat: In0=dma0_mm2s In1=dma0_s2mm In2=dma1_mm2s
#define DMA_IRQ_ID      63

#define MAKE_PIXEL(r,g,b) (((r&0xF)<<8)|((g&0xF)<<4)|(b&0xF))
#define PATTERN_HOLD_FRAMES 120

// -------------------------------------------------------
// Descritor SG — alinhado a 0x40 bytes
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
// Estado compartilhado ISR <-> main
// -------------------------------------------------------
static volatile int  buf_to_fill = -1;
static volatile int  frame_count = 0;
static volatile int  bd_index    = 0;  // qual BD acabou de completar
static XScuGic       gic;

// -------------------------------------------------------
// Padrões
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

// -------------------------------------------------------
// ISR
//
// O DMA para ao atingir TAILDESC. Para manter o anel
// girando precisamos:
//   1. Identificar qual BD completou (via CURDESC)
//   2. Limpar o status desse BD e dar flush
//   3. Re-escrever TAILDESC apontando para o BD anterior
//      ao atual → isso re-enfileira o anel inteiro
// -------------------------------------------------------
void dma_isr(void *callback)
{
    u32 sr = Xil_In32(MM2S_DMASR);
    Xil_Out32(MM2S_DMASR, DMA_IRQ_ALL);  // limpa flags

    if (sr & DMA_ERR_MASK) {
        xil_printf("DMA ERROR! DMASR=0x%08X\r\n", sr);
        return;
    }

    if (!(sr & DMA_IRQ_IOC))
        return;

    // Descobre qual BD acabou de ser processado pelo DMA.
    // Após completar BD1, CURDESC avança para BD0 (next_desc do BD1).
    // Após completar BD0, CURDESC avança para BD1.
    // Então o BD que completou é o ANTERIOR ao CURDESC atual.
    u32 curdesc = Xil_In32(MM2S_CURDESC);
    int completed_bd = (curdesc == BD0_ADDR) ? 1 : 0;

    // Limpa o status do BD que completou para poder re-usá-lo
    sg_desc_t *bd = (sg_desc_t *)(completed_bd == 0 ? BD0_ADDR : BD1_ADDR);
    bd->status = 0;
    Xil_DCacheFlushRange((u32)bd, sizeof(sg_desc_t));

    // Sinaliza para o main qual buffer está livre para escrever
    buf_to_fill = completed_bd;
    frame_count++;

    // Re-arma o DMA escrevendo TAILDESC = BD que acabou de completar.
    // O DMA está em idle apontando para o BD seguinte (curdesc).
    // Escrevendo o BD anterior como novo tail, o DMA processa
    // curdesc → ... → novo tail, mantendo o anel girando.
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
// Inicializa SG e dispara
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

    // CURDESC antes do run bit
    Xil_Out32(MM2S_CURDESC, BD0_ADDR);

    // Run + IRQ IOC habilitado
    Xil_Out32(MM2S_DMACR, 0x1 | DMA_IRQ_EN_IOC);

    // Dispara processando BD0 e BD1
    Xil_Out32(MM2S_TAILDESC, BD1_ADDR);
}

// -------------------------------------------------------
// Main
// -------------------------------------------------------
int main()
{
    init_platform();
    xil_printf("=== VGA SG Double Buffer ===\r\n");

    // Preenche os dois buffers antes de ligar o DMA
    xil_printf("Preparando FB_A (color bars)...\r\n");
    fill_color_bars(FB_A_ADDR);
    Xil_DCacheFlushRange(FB_A_ADDR, FB_SIZE_BYTES);

    xil_printf("Preparando FB_B (checkerboard)...\r\n");
    fill_checkerboard(FB_B_ADDR);
    Xil_DCacheFlushRange(FB_B_ADDR, FB_SIZE_BYTES);

    if (gic_init() != 0) {
        xil_printf("GIC init falhou\r\n");
        cleanup_platform();
        return -1;
    }

    sg_init();
    xil_printf("DMA rodando\r\n");

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
            xil_printf("Frame %d, padrão %d → buf %c\r\n",
                       frame_count, next_pattern, buf == 0 ? 'A' : 'B');
            next_pattern = (next_pattern + 1) % PATTERN_COUNT;
        }
    }

    cleanup_platform();
    return 0;
}