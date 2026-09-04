// SPDX-License-Identifier: MIT
/*
 * w132d-bl31-cookie — 把出厂 BL31 安全串口调试器要的握手 cookie 写进去。
 *
 * ## 它在解决什么
 *
 * W132D 出厂的 Android 9 BL31（EL3）里有一个安全定时器回调，每分钟跑一次。
 * 前 30 次什么都不做；第 30 次起读 GRF 的 OS 便签寄存器 0xff370220，在 RK3528
 * （SoC id 0x3528）上要求里面是 0x2b4d1f7a。对上就直接返回；对不上就判定
 * "uart always busy"，往 UART0 喷波特率训练帧（'#'、'U'/'8'、'-'、']'），
 * 并改写 CRU 0xff4c8040 里的 UART 时钟分频 —— 整机随之每约 32 分钟挂死一次。
 *
 * 那个 cookie 本该由厂商内核的 fiq_debugger 驱动来写。主线内核没有这个驱动，
 * 于是从没人写过（实测该寄存器读出来是 0x00000000），宽限期一过必然触发。
 *
 * ## 它怎么做
 *
 * 开机早期从用户态经 /dev/mem 往那个寄存器做一次 32 位写入。OS 便签寄存器没有
 * 高 16 位写使能掩码，所以写整值即可；但必须是**一次 32 位访问** —— 逐字节写
 * 到设备内存上结果不可预期，这也是不用 python/dd 而写这几十行 C 的原因。
 *
 * 只认 DT compatible 里带 rockchip,rk3528 的机器，别的板子上直接拒绝。
 *
 * ## 状态
 *
 * ✅ 2026-09-04 在原版（未打补丁）BL31 上实机验证：写入后 42 分钟无挂死无复位，
 * 历史上的两个爆点（1919 s / 1979 s）都平安过去。早先"给 BL31 打 4 字节补丁"的
 * 办法已不需要。
 *
 * 退出码：0 = 跑完后寄存器里是 cookie；1 = 不是（写不进去或被改掉）；
 *         2 = 用法 / 环境错误（不是 RK3528、打不开 /dev/mem …）。
 *
 * 用法：w132d-bl31-cookie [--check]     --check 只读不写
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define GRF_OS_REG_COOKIE_PHYS 0xff370220UL /* syscon@ff300000 + 0x70220 */
#define BL31_UARTDBG_COOKIE_RK3528 0x2b4d1f7aU
#define DT_COMPATIBLE "/proc/device-tree/compatible"
#define SOC_COMPATIBLE "rockchip,rk3528"

static int is_rk3528(void)
{
	char buf[512];
	FILE *f = fopen(DT_COMPATIBLE, "rb");
	size_t n;

	if (!f)
		return 0;
	n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = '\0';
	/* compatible 是一串以 NUL 分隔的字符串，逐个比对 */
	for (size_t i = 0; i < n; i += strlen(&buf[i]) + 1)
		if (!strcmp(&buf[i], SOC_COMPATIBLE))
			return 1;
	return 0;
}

int main(int argc, char **argv)
{
	int check_only = 0;

	if (argc == 2 && !strcmp(argv[1], "--check"))
		check_only = 1;
	else if (argc != 1) {
		fprintf(stderr, "usage: %s [--check]\n", argv[0]);
		return 2;
	}

	if (!is_rk3528()) {
		fprintf(stderr, "w132d-bl31-cookie: not an RK3528 (%s), refusing to touch 0x%lx\n",
			DT_COMPATIBLE, GRF_OS_REG_COOKIE_PHYS);
		return 2;
	}

	int fd = open("/dev/mem", (check_only ? O_RDONLY : O_RDWR) | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "w132d-bl31-cookie: open /dev/mem: %s\n", strerror(errno));
		return 2;
	}

	long page = sysconf(_SC_PAGESIZE);
	off_t base = (off_t)(GRF_OS_REG_COOKIE_PHYS & ~((unsigned long)page - 1));
	void *map = mmap(NULL, (size_t)page, PROT_READ | (check_only ? 0 : PROT_WRITE),
			 MAP_SHARED, fd, base);
	if (map == MAP_FAILED) {
		fprintf(stderr, "w132d-bl31-cookie: mmap 0x%llx: %s\n",
			(unsigned long long)base, strerror(errno));
		close(fd);
		return 2;
	}

	volatile uint32_t *reg =
		(volatile uint32_t *)((char *)map + (GRF_OS_REG_COOKIE_PHYS - (unsigned long)base));
	uint32_t before = *reg;
	if (!check_only)
		*reg = BL31_UARTDBG_COOKIE_RK3528;
	uint32_t after = *reg;

	munmap(map, (size_t)page);
	close(fd);

	printf("w132d-bl31-cookie: 0x%lx was 0x%08x, now 0x%08x (%s)\n",
	       GRF_OS_REG_COOKIE_PHYS, before, after,
	       after == BL31_UARTDBG_COOKIE_RK3528 ? "cookie present" : "COOKIE MISSING");
	return after == BL31_UARTDBG_COOKIE_RK3528 ? 0 : 1;
}
