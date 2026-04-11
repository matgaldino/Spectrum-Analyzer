/******************************************************************************
*
* Copyright (C) 2009 - 2014 Xilinx, Inc.  All rights reserved.
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* Use of the Software is limited solely to applications:
* (a) running on a Xilinx device, or
* (b) that interact with a Xilinx device through a bus or interconnect.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
* XILINX  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
* WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
* OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*
* Except as contained in this notice, the name of the Xilinx shall not be used
* in advertising or otherwise to promote the sale, use or other dealings in
* this Software without prior written authorization from Xilinx.
*
******************************************************************************/

/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */

#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "sleep.h"

// -------------------------------------------------------
// AXI DMA 1 - MM2S registers
// -------------------------------------------------------
#define DMA_BASE_ADDR   0x40410000

#define MM2S_DMACR      (DMA_BASE_ADDR + 0x00)
#define MM2S_DMASR      (DMA_BASE_ADDR + 0x04)
#define MM2S_SA         (DMA_BASE_ADDR + 0x18)
#define MM2S_LENGTH     (DMA_BASE_ADDR + 0x28)

// -------------------------------------------------------
// Frame buffer in DDR
// -------------------------------------------------------
#define FB_ADDR         0x10000000
#define H_VISIBLE       1024
#define V_VISIBLE       768
#define PIXELS_PER_FRAME (H_VISIBLE * V_VISIBLE)
#define FB_SIZE_BYTES   (PIXELS_PER_FRAME * 4)

// Pixel RGB 4:4:4 — R[11:8] G[7:4] B[3:0]
#define MAKE_PIXEL(r, g, b) (((r & 0xF) << 8) | ((g & 0xF) << 4) | (b & 0xF))

// -------------------------------------------------------
// Fill the frame buffer with color bars
// -------------------------------------------------------
void fill_color_bars(void)
{
    unsigned int colors[8] = {
        MAKE_PIXEL(0xF, 0x0, 0x0),  // Red
        MAKE_PIXEL(0x0, 0xF, 0x0),  // Green
        MAKE_PIXEL(0x0, 0x0, 0xF),  // Blue
        MAKE_PIXEL(0xF, 0xF, 0x0),  // Yellow
        MAKE_PIXEL(0x0, 0xF, 0xF),  // Cyan
        MAKE_PIXEL(0xF, 0x0, 0xF),  // Magenta
        MAKE_PIXEL(0xF, 0xF, 0xF),  // White
        MAKE_PIXEL(0x0, 0x0, 0x0),  // Black
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
// Send one frame via MM2S DMA
// -------------------------------------------------------
void dma_send_frame(void)
{
    unsigned int sr;

    // 1. Reset
    Xil_Out32(MM2S_DMACR, 0x4);
    while (Xil_In32(MM2S_DMACR) & 0x4);
    xil_printf("DMA reset OK\r\n");

    // 2. Run
    Xil_Out32(MM2S_DMACR, 0x1);
    xil_printf("DMACR after run: 0x%08X\r\n", Xil_In32(MM2S_DMACR));

    // 3. Source address
    Xil_Out32(MM2S_SA, FB_ADDR);

    // 4. Frame size in bytes
    Xil_Out32(MM2S_LENGTH, FB_SIZE_BYTES);
    xil_printf("LENGTH written: %u bytes\r\n", FB_SIZE_BYTES);

    // 5. Wait for IOC_Irq with timeout
    int timeout = 10000000;
    while (!(Xil_In32(MM2S_DMASR) & 0x1000) && timeout > 0) {
        timeout--;
    }

    sr = Xil_In32(MM2S_DMASR);
    if (timeout == 0) {
        xil_printf("TIMEOUT! DMASR=0x%08X\r\n", sr);
    } else {
        xil_printf("DMA OK! DMASR=0x%08X\r\n", sr);
    }
}

int main()
{
    init_platform();

    xil_printf("=== VGA DMA Test ===\r\n");

    // 1. Fill the frame buffer
    xil_printf("Filling frame buffer...\r\n");
    fill_color_bars();

    // 2. Flush the cache - required before DMA reads from DDR
    Xil_DCacheFlushRange(FB_ADDR, FB_SIZE_BYTES);
    xil_printf("Cache flushed, starting DMA...\r\n");

    // 3. Send frames continuously
    while (1) {
        dma_send_frame();
    }

    cleanup_platform();
    return 0;
}
