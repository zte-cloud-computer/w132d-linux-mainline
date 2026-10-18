# SPDX-License-Identifier: MIT
"""Check display clock synthesis and RGB sink capability filtering."""
from fractions import Fraction
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'userpatches/kernel/w132d/0004-display.patch'


def additions():
    return '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                     if line.startswith('+') and not line.startswith('+++'))


def added_function(name):
    # Diff context may contain a closing brace shared with an upstream function.
    source = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                       if line.startswith((' ', '+')) and not line.startswith('+++'))
    match = re.search(r'static\s+(?:enum drm_mode_status|int|void)\s+' + re.escape(name)
                      + r'\([^;{]*\)\n\{', source)
    if match is None:
        raise ValueError('Missing added function: ' + name)
    start = match.start()
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def compile_and_run(harness):
    with tempfile.TemporaryDirectory() as temp:
        source = Path(temp) / 'display.c'
        binary = Path(temp) / 'display'
        source.write_text(harness)
        for command in (['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                         str(source), '-o', str(binary)], [str(binary)]):
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)


class DisplayClocks(unittest.TestCase):
    def test_pc_clocks_synthesize_the_advertised_pixel_and_tmds_rates(self):
        rows = []
        for match in re.findall(r'\{\s*(\d[^{}]+)\}', additions()):
            fields = [field.strip() for field in match.split(',')]
            if len(fields) == 13 and all(re.fullmatch(r'(?:0x[0-9a-fA-F]+|\d+)', x)
                                         for x in fields):
                rows.append([int(field, 0) for field in fields])
        self.assertEqual({row[0] for row in rows},
                         {234590000, 304250000, 497750000, 533250000, 586000000})
        for row in rows:
            pixel, tmds, nr, nf, ta, tb, tc, pa, pb, pc, pd, div5, frac = row
            with self.subTest(pixel=pixel):
                self.assertTrue(1 <= nr <= 63)
                self.assertTrue(1 <= nf <= 4095)
                self.assertTrue(0 <= frac < 1 << 24)
                self.assertTrue(0 <= ta <= 3 and 0 <= tb <= 3 and 0 <= tc <= 3)
                self.assertTrue(1 <= pa <= 31 and 0 <= pb <= 3)
                self.assertTrue(0 <= pc <= 3 and 1 <= pd <= 31)
                vco = Fraction(24000000, nr) * (nf + Fraction(frac, 1 << 24))
                self.assertTrue(1400000000 <= vco <= 3200000000)
                pixel_div = 5 if div5 else (pb + 2 if pa == 1 else pa) * pd * 2
                actual_pixel = vco / pixel_div
                actual_pre_pixel = vco / ((pb + 2 if pa == 1 else pa) * (1 << pc))
                actual_tmds = vco / (4 * (1, 2, 3, 5)[ta] * (1 << tc))
                self.assertLess(abs(actual_pixel - pixel), 1)
                self.assertLess(abs(actual_pre_pixel - pixel), 1)
                self.assertLess(abs(actual_tmds - tmds), 1)
                self.assertEqual(1 << tb, (1 << tc) * (4 if tmds > 340000000 else 1))


@unittest.skipUnless(shutil.which('cc'), 'A host C compiler is required')
class SinkCapabilities(unittest.TestCase):
    def test_rgb_modes_respect_sink_bandwidth_and_scrambling(self):
        # Execute the actual added callback with an independent EDID capability matrix.
        harness = r'''
#include <assert.h>
#include <stdbool.h>
enum drm_mode_status { MODE_OK, MODE_CLOCK_HIGH, MODE_NOCLOCK };
struct dw_hdmi { int unused; };
struct drm_display_mode { int clock; };
struct drm_display_info {
    int max_tmds_clock;
    struct { struct {
        bool supported;
        struct { bool supported; } scrambling;
    } scdc; } hdmi;
};
static enum drm_mode_status base_status = MODE_OK;
static enum drm_mode_status dw_hdmi_rockchip_mode_valid(
    struct dw_hdmi *hdmi, void *data, const struct drm_display_info *info,
    const struct drm_display_mode *mode)
{
    (void)hdmi; (void)data; (void)info; (void)mode;
    return base_status;
}
'''
        harness += added_function('dw_hdmi_rk3528_mode_valid')
        harness += r'''
int main(void)
{
    struct drm_display_info info = { .max_tmds_clock = 600000 };
    struct drm_display_mode mode = { .clock = 594000 };
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_CLOCK_HIGH);
    info.hdmi.scdc.supported = true;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_CLOCK_HIGH);
    info.hdmi.scdc.scrambling.supported = true;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_OK);
    info.max_tmds_clock = 300000;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_CLOCK_HIGH);
    mode.clock = 297000;
    info.hdmi.scdc.supported = false;
    info.hdmi.scdc.scrambling.supported = false;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_OK);
    info.max_tmds_clock = 165000;
    mode.clock = 241500;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_CLOCK_HIGH);
    mode.clock = 148500;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_OK);
    info.max_tmds_clock = 0;
    mode.clock = 340000;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_OK);
    mode.clock = 340001;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_CLOCK_HIGH);
    info.hdmi.scdc.supported = true;
    info.hdmi.scdc.scrambling.supported = true;
    mode.clock = 533250;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_CLOCK_HIGH);
    info.max_tmds_clock = 600000;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_OK);
    base_status = MODE_NOCLOCK;
    assert(dw_hdmi_rk3528_mode_valid(0, 0, &info, &mode) == MODE_NOCLOCK);
    return 0;
}
'''
        compile_and_run(harness)


@unittest.skipUnless(shutil.which('cc'), 'A host C compiler is required')
class DisplayRecovery(unittest.TestCase):
    def test_failed_port_completes_events_without_waiting_for_vblank(self):
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <stddef.h>
struct drm_pending_vblank_event { int unused; };
struct vop2_video_port { bool enabled; struct drm_pending_vblank_event *event; };
struct drm_device { int event_lock; };
struct drm_crtc_state { struct drm_pending_vblank_event *event; };
struct drm_crtc { struct drm_device *dev; struct drm_crtc_state *state; struct vop2_video_port *port; };
static int gets, sends, references, vblank_error;
static struct vop2_video_port *to_vop2_video_port(struct drm_crtc *crtc) { return crtc->port; }
static void spin_lock_irq(int *lock) { assert(*lock == 0); ++*lock; }
static void spin_unlock_irq(int *lock) { assert(*lock == 1); --*lock; }
static int drm_crtc_vblank_get(struct drm_crtc *crtc)
{
    assert(crtc->dev->event_lock == 1);
    gets++;
    if (vblank_error)
        return vblank_error;
    references++;
    return 0;
}
static void drm_crtc_send_vblank_event(struct drm_crtc *crtc, struct drm_pending_vblank_event *event)
{ assert(crtc->dev->event_lock == 1 && event); sends++; }
'''
        harness += added_function('vop2_crtc_queue_event')
        harness += r'''
int main(void)
{
    struct drm_pending_vblank_event event = {0};
    struct drm_crtc_state state = { &event };
    struct drm_device dev = {0};
    struct vop2_video_port port = {0};
    struct drm_crtc crtc = { &dev, &state, &port };
    vop2_crtc_queue_event(&crtc);
    assert(sends == 1 && gets == 0 && references == 0 && state.event == NULL && port.event == NULL);
    port.enabled = true;
    state.event = &event;
    vblank_error = -EINVAL;
    vop2_crtc_queue_event(&crtc);
    assert(sends == 2 && gets == 1 && references == 0 && state.event == NULL && port.event == NULL);
    state.event = &event;
    vblank_error = 0;
    vop2_crtc_queue_event(&crtc);
    assert(sends == 2 && gets == 2 && references == 1 && state.event == NULL && port.event == &event);
    vop2_crtc_queue_event(&crtc);
    assert(sends == 2 && gets == 2 && references == 1 && dev.event_lock == 0);
    return 0;
}
'''
        compile_and_run(harness)

    def test_phy_lost_lock_and_direct_clock_failures_allow_retry(self):
        harness = r'''
#include <assert.h>
#include <errno.h>
#include <stddef.h>
#define BIT(n) (1U << (n))
#define RK3328_BANDGAP_ENABLE BIT(2)
#define RK3328_POST_PLL_POWER_DOWN BIT(0)
#define RK3328_PRE_PLL_LOCK_STATUS BIT(0)
struct clk_hw { int unused; };
struct inno_hdmi_phy { struct clk_hw hw; unsigned long pixclock, tmdsclock; };
static unsigned int regs[256];
static int programs, rate_error;
static struct inno_hdmi_phy *to_inno_hdmi_phy(struct clk_hw *hw)
{ return (struct inno_hdmi_phy *)hw; }
static unsigned int inno_read(struct inno_hdmi_phy *inno, unsigned int reg)
{ (void)inno; return regs[reg]; }
static void inno_write(struct inno_hdmi_phy *inno, unsigned int reg, unsigned int val)
{ (void)inno; regs[reg] = val; }
static void inno_update_bits(struct inno_hdmi_phy *inno, unsigned int reg,
                             unsigned int mask, unsigned int val)
{ (void)inno; regs[reg] = (regs[reg] & ~mask) | (val & mask); }
static int inno_hdmi_phy_rk3328_clk_set_rate(struct clk_hw *hw, unsigned long rate,
                                           unsigned long parent)
{
    struct inno_hdmi_phy *inno = to_inno_hdmi_phy(hw);
    assert(parent == 24000000);
    if (inno->pixclock == rate && inno->tmdsclock == rate)
        return 0;
    programs++;
    if (rate_error)
        return rate_error;
    inno->pixclock = inno->tmdsclock = rate;
    regs[0xa9] = RK3328_PRE_PLL_LOCK_STATUS;
    return 0;
}
'''
        harness += added_function('inno_hdmi_phy_rk3528_power_off') + '\n'
        harness += added_function('inno_hdmi_phy_rk3528_clk_set_rate')
        harness += r'''
int main(void)
{
    struct inno_hdmi_phy inno = { .pixclock = 297000000, .tmdsclock = 297000000 };
    regs[0xa9] = RK3328_PRE_PLL_LOCK_STATUS;
    assert(inno_hdmi_phy_rk3528_clk_set_rate(&inno.hw, 297000000, 24000000) == 0);
    assert(programs == 0);
    regs[0xa9] = 0;
    assert(inno_hdmi_phy_rk3528_clk_set_rate(&inno.hw, 297000000, 24000000) == 0);
    assert(programs == 1 && inno.tmdsclock == 297000000);
    regs[0xb2] = 0x0f;
    regs[0xbe] = 0x70;
    rate_error = -ETIMEDOUT;
    assert(inno_hdmi_phy_rk3528_clk_set_rate(&inno.hw, 533250000, 24000000) == -ETIMEDOUT);
    assert(inno.tmdsclock == 0 && programs == 2);
    assert(regs[0xb2] == 0 && regs[0xbe] == 0 && regs[0xcc] == 0);
    assert(!(regs[0xb0] & RK3328_BANDGAP_ENABLE));
    assert(regs[0xaa] & RK3328_POST_PLL_POWER_DOWN);
    rate_error = 0;
    assert(inno_hdmi_phy_rk3528_clk_set_rate(&inno.hw, 533250000, 24000000) == 0);
    assert(programs == 3 && inno.tmdsclock == 533250000);
    inno_hdmi_phy_rk3528_power_off(&inno);
    assert(inno.tmdsclock == 0);
    assert(inno_hdmi_phy_rk3528_clk_set_rate(&inno.hw, 533250000, 24000000) == 0);
    assert(programs == 4);
    return 0;
}
'''
        compile_and_run(harness)

    def test_vop_ports_balance_clock_and_shared_resources_after_failure(self):
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <stddef.h>
struct clk { int references; int prepare_error; int parents_restored; };
struct vop2 { unsigned int enable_count; int start_error; int starts, stops; };
struct vop2_video_port { struct vop2 *vop2; struct clk *dclk, *dclk_src; bool enabled; };
static int clk_prepare_enable(struct clk *clk)
{
    if (clk->prepare_error)
        return clk->prepare_error;
    clk->references++;
    return 0;
}
static void clk_disable_unprepare(struct clk *clk)
{ assert(clk->references > 0); clk->references--; }
static int clk_set_parent(struct clk *clk, struct clk *parent)
{ assert(parent); clk->parents_restored++; return 0; }
static int vop2_enable(struct vop2 *vop)
{ vop->starts++; return vop->start_error; }
static void vop2_disable(struct vop2 *vop) { vop->stops++; }
'''
        harness += added_function('vop2_vp_enable') + '\n'
        harness += added_function('vop2_vp_disable')
        harness += r'''
int main(void)
{
    struct vop2 vop = {0};
    struct clk clock0 = {0}, clock1 = {0}, parent = {0};
    struct vop2_video_port vp0 = { &vop, &clock0, NULL, false };
    struct vop2_video_port vp1 = { &vop, &clock1, &parent, false };
    clock0.prepare_error = -ETIMEDOUT;
    assert(vop2_vp_enable(&vp0) == -ETIMEDOUT);
    vop2_vp_disable(&vp0);
    assert(!vp0.enabled && vop.enable_count == 0 && vop.starts == 0);
    clock0.prepare_error = 0;
    vop.start_error = -EIO;
    assert(vop2_vp_enable(&vp0) == -EIO);
    vop2_vp_disable(&vp0);
    assert(clock0.references == 0 && vop.enable_count == 0 && vop.stops == 0);
    vop.start_error = 0;
    assert(vop2_vp_enable(&vp0) == 0);
    assert(vp0.enabled && vop.enable_count == 1 && clock0.references == 1);
    assert(vop2_vp_enable(&vp0) == 0);
    assert(vop.enable_count == 1 && clock0.references == 1);
    clock1.prepare_error = -EIO;
    assert(vop2_vp_enable(&vp1) == -EIO);
    vop2_vp_disable(&vp1);
    assert(vop.enable_count == 1 && clock0.references == 1 && vop.stops == 0);
    clock1.prepare_error = 0;
    assert(vop2_vp_enable(&vp1) == 0);
    assert(vop.enable_count == 2 && clock1.references == 1 && vop.starts == 2);
    vop2_vp_disable(&vp0);
    assert(!vp0.enabled && vop.enable_count == 1 && vop.stops == 0);
    vop2_vp_disable(&vp0);
    assert(vop.enable_count == 1 && vop.stops == 0);
    vop2_vp_disable(&vp1);
    assert(!vp1.enabled && vop.enable_count == 0 && vop.stops == 1);
    assert(clock0.references == 0 && clock1.references == 0 && clock1.parents_restored == 1);
    vop2_vp_disable(&vp1);
    assert(vop.enable_count == 0 && vop.stops == 1);
    return 0;
}
'''
        compile_and_run(harness)


if __name__ == '__main__':
    unittest.main()
