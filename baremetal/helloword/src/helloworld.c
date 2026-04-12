#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "sleep.h"

// -------------------------------------------------------
// AXI DMA 1 - MM2S (VGA)
// -------------------------------------------------------
#define DMA1_BASE_ADDR  0x40410000
#define MM2S_DMACR      (DMA1_BASE_ADDR + 0x00)
#define MM2S_DMASR      (DMA1_BASE_ADDR + 0x04)
#define MM2S_SA         (DMA1_BASE_ADDR + 0x18)
#define MM2S_LENGTH     (DMA1_BASE_ADDR + 0x28)

// -------------------------------------------------------
// AXI DMA 2 - S2MM (I2S capture)
// -------------------------------------------------------
#define DMA2_BASE_ADDR  0x40420000
#define S2MM_DMACR      (DMA2_BASE_ADDR + 0x30)
#define S2MM_DMASR      (DMA2_BASE_ADDR + 0x34)
#define S2MM_DA         (DMA2_BASE_ADDR + 0x48)
#define S2MM_LENGTH     (DMA2_BASE_ADDR + 0x58)

// -------------------------------------------------------
// Frame buffer - VGA
// -------------------------------------------------------
#define FB_ADDR             0x10000000
#define H_VISIBLE           1024
#define V_VISIBLE           768
#define PIXELS_PER_FRAME    (H_VISIBLE * V_VISIBLE)
#define FB_SIZE_BYTES       (PIXELS_PER_FRAME * 4)

// -------------------------------------------------------
// Audio capture buffer
// 44100 Hz * 2 canais * 4 bytes * 1 segundo
// Cada sample é 64 bits (8 bytes) = par L+R
// -------------------------------------------------------
#define AUDIO_BUF_ADDR      0x11000000
#define AUDIO_SAMPLE_RATE   44100
#define AUDIO_SECONDS       1
#define AUDIO_PAIRS         (AUDIO_SAMPLE_RATE * AUDIO_SECONDS)
#define AUDIO_SIZE_BYTES    (AUDIO_PAIRS * 8)   // 8 bytes por par L+R

#define MAKE_PIXEL(r, g, b) (((r & 0xF) << 8) | ((g & 0xF) << 4) | (b & 0xF))

// -------------------------------------------------------
// Frame buffer
// -------------------------------------------------------
void fill_color_bars(void)
{
    unsigned int colors[8] = {
        MAKE_PIXEL(0xF, 0x0, 0x0),
        MAKE_PIXEL(0x0, 0xF, 0x0),
        MAKE_PIXEL(0x0, 0x0, 0xF),
        MAKE_PIXEL(0xF, 0xF, 0x0),
        MAKE_PIXEL(0x0, 0xF, 0xF),
        MAKE_PIXEL(0xF, 0x0, 0xF),
        MAKE_PIXEL(0xF, 0xF, 0xF),
        MAKE_PIXEL(0x0, 0x0, 0x0),
    };

    for (int y = 0; y < V_VISIBLE; y++) {
        for (int x = 0; x < H_VISIBLE; x++) {
            int band = x / 128;
            unsigned int addr = FB_ADDR + (y * H_VISIBLE + x) * 4;
            Xil_Out32(addr, colors[band]);
        }
    }
}

// -------------------------------------------------------
// MM2S DMA (VGA)
// -------------------------------------------------------
void dma_send_frame(void)
{
    unsigned int sr;

    Xil_Out32(MM2S_DMACR, 0x4);
    while (Xil_In32(MM2S_DMACR) & 0x4);

    Xil_Out32(MM2S_DMACR, 0x1);
    Xil_Out32(MM2S_SA, FB_ADDR);
    Xil_Out32(MM2S_LENGTH, FB_SIZE_BYTES);

    int timeout = 10000000;
    while (!(Xil_In32(MM2S_DMASR) & 0x1000) && timeout > 0)
        timeout--;

    sr = Xil_In32(MM2S_DMASR);
    if (timeout == 0)
        xil_printf("VGA DMA TIMEOUT! DMASR=0x%08X\r\n", sr);
}

// -------------------------------------------------------
// S2MM DMA (I2S capture)
// -------------------------------------------------------
void dma_capture_audio(void)
{
    int timeout;
    unsigned int sr;

    // 1. Reset
    Xil_Out32(S2MM_DMACR, 0x4);
    while (Xil_In32(S2MM_DMACR) & 0x4);

    // 2. Run
    Xil_Out32(S2MM_DMACR, 0x1);

    // 3. Destination address
    Xil_Out32(S2MM_DA, AUDIO_BUF_ADDR);

    // 4. Length — dispara a transferência
    Xil_Out32(S2MM_LENGTH, AUDIO_SIZE_BYTES);

    xil_printf("Capturando %d pares L+R (%d bytes)...\r\n",
               AUDIO_PAIRS, AUDIO_SIZE_BYTES);

    // 5. Aguarda IOC
    timeout = 100000000;
    while (!(Xil_In32(S2MM_DMASR) & 0x1000) && timeout > 0)
        timeout--;

    sr = Xil_In32(S2MM_DMASR);
    if (timeout == 0) {
        xil_printf("AUDIO DMA TIMEOUT! DMASR=0x%08X\r\n", sr);
        return;
    }

    xil_printf("Captura OK! DMASR=0x%08X\r\n", sr);

    // 6. Invalida cache antes de ler
    Xil_DCacheInvalidateRange(AUDIO_BUF_ADDR, AUDIO_SIZE_BYTES);

    // 7. Imprime primeiros 16 pares L+R para verificação
    xil_printf("Primeiros 16 pares L+R:\r\n");
    for (int i = 0; i < 16; i++) {
        unsigned int addr = AUDIO_BUF_ADDR + i * 8;
        unsigned int word0 = Xil_In32(addr + 0);  // bytes 0-3
        unsigned int word1 = Xil_In32(addr + 4);  // bytes 4-7
        xil_printf("[%2d] word0=0x%08X  word1=0x%08X\r\n", i, word0, word1);
    }
}

// -------------------------------------------------------
// Main
// -------------------------------------------------------
int main()
{
    init_platform();
    xil_printf("=== VGA + I2S DMA Test ===\r\n");

    // Frame buffer
    xil_printf("Preenchendo frame buffer...\r\n");
    fill_color_bars();
    Xil_DCacheFlushRange(FB_ADDR, FB_SIZE_BYTES);

    // Captura 1 segundo de audio
    xil_printf("Iniciando captura de audio...\r\n");
    dma_capture_audio();

    // Loop VGA
    xil_printf("Iniciando loop VGA...\r\n");
    while (1) {
        dma_send_frame();
    }

    cleanup_platform();
    return 0;
}