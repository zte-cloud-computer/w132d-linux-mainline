# SPDX-License-Identifier: MIT
"""Exercise real register writes; set W132D_KERNEL_TREE to a patched Linux tree."""
from pathlib import Path
import os
import re
import shutil
import unittest
from test_bluetooth_driver import function, execute


@unittest.skipUnless(os.environ.get('W132D_KERNEL_TREE') and shutil.which('cc'),
                     'Set W132D_KERNEL_TREE to a patched verification tree')
class MMCRegisters(unittest.TestCase):
    def test_rk3528_timing_and_generic_defaults(self):
        source = (Path(os.environ['W132D_KERNEL_TREE']) /
                  'drivers/mmc/host/sdhci-of-dwcmshc.c').read_text()
        code = r'''
        #include <assert.h>
        #include <stdbool.h>
        #include <stdint.h>
        #include <string.h>
        typedef uint32_t u32;
        typedef uint8_t u8;
        #define BIT(n) (1U<<(n))
        #define MMC_TIMING_MMC_HS200 1
        #define MMC_TIMING_MMC_HS400 2
        #define MMC_TIMING_MMC_DDR52 3
        #define SDHCI_CLOCK_CONTROL 0x2c
        #define USEC_PER_MSEC 1000
        #define dev_err(...) ((void)0)
        #define mmc_dev(x) (x)
        '''
        for line in source.splitlines():
            if line.startswith('#define ') and re.match(r'#define (DWCMSHC_(?:EMMC_DLL|HOST_CTRL3|EMMC_ATCTRL)|DECMSHC_EMMC_DLL|DLL_)', line) and not line.endswith('\\'):
                code += line + '\n'
        code += r'''
        struct rk35xx_priv { u8 txclk_tapnum; };
        struct rockchip_pltfm_data { int revision; u8 hs200_tx_tap, hs400_tx_tap,
            hs400_cmd_tap, hs400_strbin_tap, ddr52_strbin_delay; bool tap_value_sel, allow_low_clock; };
        struct dwcmshc_priv { struct rk35xx_priv *priv; struct rockchip_pltfm_data *pdata; int vendor_specific_area1; };
        struct sdhci_pltfm_host { struct dwcmshc_priv *priv; int clk; };
        struct mmc_host { unsigned int actual_clock; struct { int timing; } ios; };
        struct sdhci_host { struct mmc_host *mmc; struct sdhci_pltfm_host *priv; u8 *ioaddr; };
        static struct sdhci_pltfm_host *sdhci_priv(struct sdhci_host *h) { return h->priv; }
        static struct dwcmshc_priv *sdhci_pltfm_priv(struct sdhci_pltfm_host *h) { return h->priv; }
        #define to_pltfm_data(p,n) ((p)->pdata)
        static int clk_set_rate(int clk,unsigned int clock) { (void)clk; (void)clock; return 0; }
        static void sdhci_set_clock(struct sdhci_host *h,unsigned int c) { h->mmc->actual_clock=c; }
        static void sdhci_enable_clk(struct sdhci_host *h,int c) { (void)h; (void)c; }
        static void sdhci_writew(struct sdhci_host *h,unsigned int v,unsigned int reg) { memcpy(h->ioaddr+reg,&v,2); }
        static u32 sdhci_readl(struct sdhci_host *h,unsigned int reg) { u32 v; memcpy(&v,h->ioaddr+reg,4); return v; }
        static void sdhci_writel(struct sdhci_host *h,u32 v,unsigned int reg) { memcpy(h->ioaddr+reg,&v,4); }
        static void udelay(int n) { (void)n; }
        static int poll_failure;
        #define readl_poll_timeout(addr,val,cond,delay,timeout) ((void)(addr),(void)(val),poll_failure)
        '''
        code += function(source, 'dwcmshc_rk3568_set_clock')
        # Use the maintained pdata initializers, including the generic defaults.
        code += '\nstatic struct rockchip_pltfm_data rk3528 = {\n'
        start = source.index('static const struct rockchip_pltfm_data sdhci_dwcmshc_rk3528_pdata = {')
        end = source.index('\n};', start)
        for line in source[start:end].splitlines():
            if re.match(r'\s*\.(?:revision|hs200_tx_tap|hs400_\w+|ddr52_strbin_delay|tap_value_sel|allow_low_clock) =', line):
                code += line + '\n'
        code += '};\n'
        code += r'''
        int main(void) {
            u8 regs[4096]={0};
            struct rk35xx_priv rk={.txclk_tapnum=16};
            struct dwcmshc_priv dwc={.priv=&rk,.pdata=&rk3528};
            struct sdhci_pltfm_host plt={.priv=&dwc};
            struct mmc_host mmc={0};
            struct sdhci_host host={.mmc=&mmc,.priv=&plt,.ioaddr=regs};
            const u32 lock=0x39, feedback=BIT(25)|(0x72<<8);
            sdhci_writel(&host,BIT(8)|lock,DWCMSHC_EMMC_DLL_STATUS0);
            mmc.ios.timing=MMC_TIMING_MMC_HS200;
            dwcmshc_rk3568_set_clock(&host,200000000);
            assert((sdhci_readl(&host,0x808)&0xff)==12);
            assert((sdhci_readl(&host,0x804)&(BIT(25)|0xff00))==feedback);
            assert((sdhci_readl(&host,0x808)&(BIT(25)|0xff00))==feedback);
            assert((sdhci_readl(&host,0x80c)&(BIT(25)|0xff00))==feedback);
            mmc.ios.timing=MMC_TIMING_MMC_HS400;
            dwcmshc_rk3568_set_clock(&host,200000000);
            assert((sdhci_readl(&host,0x808)&0xff)==6);
            assert((sdhci_readl(&host,0x810)&0xff)==6);
            assert((sdhci_readl(&host,0x80c)&0xff)==3);
            assert((sdhci_readl(&host,0x810)&(BIT(25)|0xff00))==feedback);
            for (int mode=1;mode<=3;mode++) {
                mmc.ios.timing=mode;
                dwcmshc_rk3568_set_clock(&host,52000000);
                assert(sdhci_readl(&host,0x800)==(BIT(24)|BIT(0)));
                assert(sdhci_readl(&host,0x808)==0 && sdhci_readl(&host,0x810)==0);
                assert(sdhci_readl(&host,0x80c)==(BIT(27)|BIT(26)|(10<<16)));
            }
            struct rockchip_pltfm_data generic={.revision=1}; dwc.pdata=&generic;
            mmc.ios.timing=MMC_TIMING_MMC_HS400;
            dwcmshc_rk3568_set_clock(&host,200000000);
            assert((sdhci_readl(&host,0x808)&0xff)==10);
            assert((sdhci_readl(&host,0x810)&0xff)==8);
            assert((sdhci_readl(&host,0x80c)&0xff)==4);
            assert(!(sdhci_readl(&host,0x804)&BIT(25)));
            assert(!(sdhci_readl(&host,0x808)&BIT(25)));
            mmc.ios.timing=MMC_TIMING_MMC_HS200;
            dwcmshc_rk3568_set_clock(&host,200000000);
            assert((sdhci_readl(&host,0x808)&0xff)==16);
            mmc.ios.timing=MMC_TIMING_MMC_DDR52;
            dwcmshc_rk3568_set_clock(&host,52000000);
            assert(sdhci_readl(&host,0x80c)==(BIT(27)|BIT(26)|(22<<16)));
            dwc.pdata=&rk3528; poll_failure=1;
            mmc.ios.timing=MMC_TIMING_MMC_HS200;
            sdhci_writel(&host,0,DWCMSHC_EMMC_DLL_TXCLK);
            dwcmshc_rk3568_set_clock(&host,200000000);
            assert(sdhci_readl(&host,0x808)==0);
            return 0;
        }
        '''
        execute(code)
