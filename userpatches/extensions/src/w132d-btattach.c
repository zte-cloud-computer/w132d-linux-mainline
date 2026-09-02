// SPDX-License-Identifier: MIT
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifndef N_HCI
#define N_HCI 15
#endif

#define HCI_UART_H4 0
#define HCIUARTSETPROTO _IOW('U', 200, int)
#define HCIUARTSETFLAGS _IOW('U', 203, int)

#define HCI_PSKEY 0xFCA0
#define HCI_ENABLE 0xFCA1
#define HCI_RF_PARA 0xFCA2

#define H4_COMMAND 0x01
#define H4_EVENT 0x04
#define EVT_COMMAND_COMPLETE 0x0E
#define EVT_COMMAND_STATUS 0x0F

#define BDADDR_FILE "/var/lib/bluetooth/w132d-bdaddr"

struct buffer {
	uint8_t *data;
	size_t len;
	size_t cap;
	bool failed;
};

static volatile sig_atomic_t stopping;

static void on_signal(int signo)
{
	(void)signo;
	stopping = 1;
}

static void put_u8(struct buffer *buf, uint8_t value)
{
	if (buf->len >= buf->cap) {
		buf->failed = true;
		return;
	}
	buf->data[buf->len++] = value;
}

static void put_u16(struct buffer *buf, uint16_t value)
{
	put_u8(buf, value & 0xff);
	put_u8(buf, value >> 8);
}

static void put_u32(struct buffer *buf, uint32_t value)
{
	put_u16(buf, value & 0xffff);
	put_u16(buf, value >> 16);
}

static void put_bytes(struct buffer *buf, const uint8_t *values, size_t count)
{
	for (size_t i = 0; i < count; i++)
		put_u8(buf, values[i]);
}

static void put_u16s(struct buffer *buf, const uint16_t *values, size_t count)
{
	for (size_t i = 0; i < count; i++)
		put_u16(buf, values[i]);
}

static void put_u32s(struct buffer *buf, const uint32_t *values, size_t count)
{
	for (size_t i = 0; i < count; i++)
		put_u32(buf, values[i]);
}

static void put_zero_u32s(struct buffer *buf, size_t count)
{
	for (size_t i = 0; i < count; i++)
		put_u32(buf, 0);
}

static size_t build_pskey(uint8_t *payload, size_t capacity,
			  const uint8_t bdaddr[6])
{
	static const uint8_t feature_set[16] = {
		0xbf, 0xff, 0x8d, 0xfe, 0xdb, 0x3d, 0x7b, 0x87,
		0xff, 0xa7, 0xff, 0x7f, 0x00, 0xe0, 0xf7, 0x3e,
	};
	static const uint16_t coex_threshold[8] = {
		0x04e2, 0x1f40, 0x0020, 0x00c8,
		0x0006, 0x0000, 0x0000, 0x0000,
	};
	struct buffer buf = { .data = payload, .cap = capacity };

	put_u32(&buf, 0x001f00);
	put_bytes(&buf, feature_set, 16);
	for (int i = 5; i >= 0; i--)
		put_u8(&buf, bdaddr[i]);
	put_u16(&buf, 0x01ec);
	put_u8(&buf, 1);       /* UART communication supported */
	put_u8(&buf, 1);       /* CP2 log mode */
	put_u8(&buf, 0xff);    /* log level */
	put_u8(&buf, 0);       /* central/peripheral */
	put_u16(&buf, 0xffff); /* log mask */
	put_u8(&buf, 0);       /* super SSP */
	put_u8(&buf, 0);       /* common RFU byte */
	put_zero_u32s(&buf, 8); /* common, LE, LMP and LC RFU words */
	put_u16(&buf, 0x0000);
	put_u16(&buf, 0x1855);
	put_u16(&buf, 0x0000);
	put_u16(&buf, 0x1855);
	put_u8(&buf, 0); /* SCO transmit mode */
	put_u8(&buf, 0);
	put_u8(&buf, 0);
	put_u8(&buf, 0);
	put_zero_u32s(&buf, 2);
	put_u8(&buf, 1); /* standby sleep */
	put_u8(&buf, 1); /* master sleep */
	put_u8(&buf, 1); /* slave sleep */
	put_u8(&buf, 0);
	put_zero_u32s(&buf, 2);
	put_u32(&buf, 40); /* receive window extension */
	put_u8(&buf, 6);
	put_u8(&buf, 8);
	put_u8(&buf, 12);
	put_u8(&buf, 34);
	put_zero_u32s(&buf, 2);
	put_u8(&buf, 0);    /* AGC mode */
	put_u8(&buf, 0xff); /* differential/equalization */
	put_u8(&buf, 0);    /* ramp mode */
	put_u8(&buf, 0);
	put_zero_u32s(&buf, 2);
	put_u32(&buf, 0); /* BQB mask 1 */
	put_u32(&buf, 0); /* BQB mask 2 */
	put_u16s(&buf, coex_threshold, 8);
	put_zero_u32s(&buf, 6);

	return buf.failed ? 0 : buf.len;
}

static size_t build_rf_config(uint8_t *payload, size_t capacity)
{
	static const uint16_t gain_a[6] = {
		0xe000, 0xe000, 0xe000, 0xe000, 0xe000, 0xe000,
	};
	static const uint16_t classic_a[10] = {
		0x4115, 0x3a15, 0x3415, 0x2e15, 0x2715,
		0x2115, 0x1715, 0x1115, 0x0b15, 0x0715,
	};
	static const uint16_t le_a[16] = {
		0x3b15, 0x3715, 0x3315, 0x2f15, 0x2b15, 0x2715,
		0x2315, 0x1f15, 0x1b15, 0x1715, 0x1315, 0x0f15,
		0x0b15, 0x0815, 0x0415, 0x0015,
	};
	static const uint16_t channel_a[8] = {
		0x1015, 0x1015, 0x1015, 0x1015,
		0x1015, 0x1015, 0x1015, 0x1015,
	};
	static const uint16_t le_channel_a[8] = {
		0x1515, 0x1515, 0x1515, 0x1515,
		0x1515, 0x1515, 0x1515, 0x1515,
	};
	static const uint16_t gain_b[6] = {
		0xe000, 0xe000, 0xe000, 0xe000, 0xe000, 0xe000,
	};
	static const uint16_t classic_b[10] = {
		0x4915, 0x4315, 0x4115, 0x3915, 0x3115,
		0x2a15, 0x2215, 0x1b15, 0x1415, 0x0e15,
	};
	static const uint16_t le_b[16] = {
		0x4b15, 0x4b15, 0x4b15, 0x4b15, 0x4b15, 0x4615,
		0x4015, 0x3b15, 0x3615, 0x3015, 0x2b15, 0x2615,
		0x2015, 0x1a15, 0x1415, 0x0e15,
	};
	static const uint16_t br_channel_b[8] = {
		0x0815, 0x0915, 0x0c15, 0x0c15,
		0x0c15, 0x0c15, 0x0c15, 0x0b15,
	};
	static const uint16_t edr_channel_b[8] = {
		0x0a15, 0x0b15, 0x0d15, 0x0e15,
		0x0e15, 0x0e15, 0x0e15, 0x0d15,
	};
	static const uint16_t le_channel_b[8] = {
		0x0e15, 0x0e15, 0x1115, 0x1115,
		0x1115, 0x1115, 0x1115, 0x1015,
	};
	static const uint32_t common_rfu[5] = {
		0x555f4334, 0x55555555, 0x55555555, 0x55555555, 0x55555555,
	};
	struct buffer buf = { .data = payload, .cap = capacity };

	put_u16s(&buf, gain_a, 6);
	put_u16s(&buf, classic_a, 10);
	put_u16s(&buf, le_a, 16);
	put_u16s(&buf, channel_a, 8); /* BR */
	put_u16s(&buf, channel_a, 8); /* EDR */
	put_u16s(&buf, le_channel_a, 8);
	put_u16s(&buf, gain_b, 6);
	put_u16s(&buf, classic_b, 10);
	put_u16s(&buf, le_b, 16);
	put_u16s(&buf, br_channel_b, 8);
	put_u16s(&buf, edr_channel_b, 8);
	put_u16s(&buf, le_channel_b, 8);
	put_u16(&buf, 0x0000); /* fixed LE power word */
	put_u8(&buf, 0xff);    /* classic power control by channel */
	put_u8(&buf, 0xff);    /* LE power control by channel */
	put_u8(&buf, 0x01);    /* RF switch mode */
	put_u8(&buf, 0x00);    /* data capture */
	put_u8(&buf, 0x00);    /* analog IQ debug */
	put_u8(&buf, 0x55);    /* common RFU byte */
	put_u32s(&buf, common_rfu, 5);

	return buf.failed ? 0 : buf.len;
}

static int parse_bdaddr(const char *text, uint8_t addr[6])
{
	unsigned int value[6];

	if (sscanf(text, "%2x:%2x:%2x:%2x:%2x:%2x",
		   &value[0], &value[1], &value[2],
		   &value[3], &value[4], &value[5]) != 6)
		return -1;
	for (size_t i = 0; i < 6; i++)
		addr[i] = value[i];
	return 0;
}

static int read_text_file(const char *path, char *buf, size_t capacity)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ssize_t count = read(fd, buf, capacity - 1);
	int saved_errno = errno;
	close(fd);
	if (count <= 0) {
		errno = saved_errno;
		return -1;
	}
	buf[count] = '\0';
	return 0;
}

static int read_net_address(const char *interface, uint8_t addr[6])
{
	char path[256];
	char text[64];

	if (snprintf(path, sizeof(path), "/sys/class/net/%s/address", interface) >=
	    (int)sizeof(path))
		return -1;
	return read_text_file(path, text, sizeof(text)) == 0 ?
		parse_bdaddr(text, addr) : -1;
}

static int find_ethernet_address(uint8_t addr[6])
{
	static const char *preferred[] = { "end0", "eth0" };
	DIR *dir;
	struct dirent *entry;

	for (size_t i = 0; i < sizeof(preferred) / sizeof(preferred[0]); i++) {
		if (read_net_address(preferred[i], addr) == 0)
			return 0;
	}
	dir = opendir("/sys/class/net");
	if (!dir)
		return -1;
	while ((entry = readdir(dir)) != NULL) {
		if (entry->d_name[0] == '.' || !strcmp(entry->d_name, "lo") ||
		    !strncmp(entry->d_name, "wlan", 4))
			continue;
		if (read_net_address(entry->d_name, addr) == 0) {
			closedir(dir);
			return 0;
		}
	}
	closedir(dir);
	return -1;
}

static void derive_fallback_address(uint8_t addr[6])
{
	char machine_id[128] = "w132d";
	uint64_t hash = 1469598103934665603ULL;

	(void)read_text_file("/etc/machine-id", machine_id, sizeof(machine_id));
	for (const unsigned char *p = (unsigned char *)machine_id; *p; p++) {
		hash ^= *p;
		hash *= 1099511628211ULL;
	}
	for (size_t i = 0; i < 6; i++)
		addr[i] = hash >> (i * 8);
}

static int persist_bdaddr(const uint8_t addr[6])
{
	char text[32];
	const char *temp = "/var/lib/bluetooth/.w132d-bdaddr.tmp";
	int fd;
	int length;

	if (mkdir("/var/lib/bluetooth", 0700) < 0 && errno != EEXIST)
		return -1;
	length = snprintf(text, sizeof(text), "%02X:%02X:%02X:%02X:%02X:%02X\n",
			  addr[0], addr[1], addr[2], addr[3], addr[4], addr[5]);
	fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0)
		return -1;
	if (write(fd, text, length) != length || fsync(fd) < 0) {
		int saved_errno = errno;
		close(fd);
		unlink(temp);
		errno = saved_errno;
		return -1;
	}
	if (close(fd) < 0 || rename(temp, BDADDR_FILE) < 0) {
		unlink(temp);
		return -1;
	}
	return chmod(BDADDR_FILE, 0600);
}

static int get_bdaddr(uint8_t addr[6])
{
	char text[64];

	if (read_text_file(BDADDR_FILE, text, sizeof(text)) == 0 &&
	    parse_bdaddr(text, addr) == 0)
		return 0;

	if (find_ethernet_address(addr) < 0)
		derive_fallback_address(addr);
	addr[0] = (addr[0] | 0x02) & 0xfe; /* locally administered unicast */
	addr[5] ^= 0xa5;                    /* do not duplicate Ethernet MAC */
	return persist_bdaddr(addr);
}

static int64_t monotonic_ms(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int read_byte_until(int fd, uint8_t *value, int64_t deadline)
{
	for (;;) {
		int remaining = (int)(deadline - monotonic_ms());
		struct pollfd pfd = { .fd = fd, .events = POLLIN };

		if (remaining <= 0) {
			errno = ETIMEDOUT;
			return -1;
		}
		int result = poll(&pfd, 1, remaining);
		if (result < 0 && errno == EINTR)
			continue;
		if (result <= 0) {
			if (result == 0)
				errno = ETIMEDOUT;
			return -1;
		}
		ssize_t count = read(fd, value, 1);
		if (count == 1)
			return 0;
		if (count < 0 && errno == EINTR)
			continue;
		if (count == 0)
			errno = EIO;
		return -1;
	}
}

static int write_all(int fd, const uint8_t *data, size_t length)
{
	while (length) {
		ssize_t count = write(fd, data, length);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0)
			return -1;
		data += count;
		length -= count;
	}
	return 0;
}

static int wait_command_response(int fd, uint16_t opcode)
{
	int64_t deadline = monotonic_ms() + 12000;

	for (;;) {
		uint8_t type;
		uint8_t event_code;
		uint8_t length;
		uint8_t payload[255];

		if (read_byte_until(fd, &type, deadline) < 0)
			return -1;
		if (type != H4_EVENT)
			continue;
		if (read_byte_until(fd, &event_code, deadline) < 0 ||
		    read_byte_until(fd, &length, deadline) < 0)
			return -1;
		for (size_t i = 0; i < length; i++) {
			if (read_byte_until(fd, &payload[i], deadline) < 0)
				return -1;
		}
		if (event_code == EVT_COMMAND_COMPLETE && length >= 3 &&
		    (uint16_t)(payload[1] | payload[2] << 8) == opcode) {
			fprintf(stderr, "w132d-btattach: opcode 0x%04x complete", opcode);
			for (size_t i = 3; i < length && i < 15; i++)
				fprintf(stderr, " %02x", payload[i]);
			fputc('\n', stderr);
			return 0;
		}
		if (event_code == EVT_COMMAND_STATUS && length >= 4 &&
		    (uint16_t)(payload[2] | payload[3] << 8) == opcode) {
			if (payload[0] != 0) {
				fprintf(stderr,
					"w132d-btattach: opcode 0x%04x status 0x%02x\n",
					opcode, payload[0]);
				errno = EPROTO;
				return -1;
			}
		}
	}
}

static int send_vendor_command(int fd, uint16_t opcode,
			       const uint8_t *payload, size_t payload_length)
{
	uint8_t packet[4 + 255];

	if (payload_length > 255) {
		errno = EMSGSIZE;
		return -1;
	}
	packet[0] = H4_COMMAND;
	packet[1] = opcode & 0xff;
	packet[2] = opcode >> 8;
	packet[3] = payload_length;
	memcpy(packet + 4, payload, payload_length);
	if (write_all(fd, packet, payload_length + 4) < 0)
		return -1;
	return wait_command_response(fd, opcode);
}

static int configure_tty(int fd)
{
	struct termios settings;

	if (tcgetattr(fd, &settings) < 0)
		return -1;
	cfmakeraw(&settings);
	settings.c_cflag |= CLOCAL | CREAD;
	settings.c_cflag &= ~CRTSCTS;
	cfsetispeed(&settings, B115200);
	cfsetospeed(&settings, B115200);
	return tcsetattr(fd, TCSANOW, &settings);
}

static int open_with_retry(const char *path)
{
	int64_t deadline = monotonic_ms() + 30000;
	int fd;

	while ((fd = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)) < 0) {
		if (errno != ENOENT && errno != ENODEV && errno != EBUSY)
			return -1;
		if (monotonic_ms() >= deadline) {
			errno = ETIMEDOUT;
			return -1;
		}
		usleep(250000);
	}
	return fd;
}

int main(int argc, char **argv)
{
	const char *device = argc > 1 ? argv[1] : "/dev/ttyBT0";
	uint8_t bdaddr[6];
	uint8_t pskey[255];
	uint8_t rf_config[255];
	uint8_t enable[] = { 0x00, 0x00, 0x01 }; /* dual mode, enable */
	size_t pskey_length;
	size_t rf_length;
	int fd;
	int ldisc;
	int flags = 0;
	int protocol = HCI_UART_H4;

	if (get_bdaddr(bdaddr) < 0) {
		perror("w132d-btattach: Bluetooth address");
		return EXIT_FAILURE;
	}
	pskey_length = build_pskey(pskey, sizeof(pskey), bdaddr);
	rf_length = build_rf_config(rf_config, sizeof(rf_config));
	if (pskey_length != 176 || rf_length != 252) {
		fprintf(stderr, "w132d-btattach: invalid payload sizes %zu/%zu\n",
			pskey_length, rf_length);
		return EXIT_FAILURE;
	}
	fprintf(stderr,
		"w132d-btattach: using address %02X:%02X:%02X:%02X:%02X:%02X\n",
		bdaddr[0], bdaddr[1], bdaddr[2], bdaddr[3], bdaddr[4], bdaddr[5]);

	fd = open_with_retry(device);
	if (fd < 0) {
		perror("w132d-btattach: open tty");
		return EXIT_FAILURE;
	}
	if (configure_tty(fd) < 0) {
		perror("w132d-btattach: configure tty");
		close(fd);
		return EXIT_FAILURE;
	}
	(void)tcflush(fd, TCIOFLUSH);
	usleep(200000);

	if (send_vendor_command(fd, HCI_PSKEY, pskey, pskey_length) < 0 ||
	    send_vendor_command(fd, HCI_RF_PARA, rf_config, rf_length) < 0 ||
	    send_vendor_command(fd, HCI_ENABLE, enable, sizeof(enable)) < 0) {
		perror("w132d-btattach: Marlin3 initialization");
		close(fd);
		return EXIT_FAILURE;
	}

	ldisc = N_HCI;
	if (ioctl(fd, TIOCSETD, &ldisc) < 0 ||
	    ioctl(fd, HCIUARTSETFLAGS, flags) < 0 ||
	    ioctl(fd, HCIUARTSETPROTO, protocol) < 0) {
		perror("w132d-btattach: attach HCI H4 line discipline");
		ldisc = N_TTY;
		(void)ioctl(fd, TIOCSETD, &ldisc);
		close(fd);
		return EXIT_FAILURE;
	}

	struct sigaction action = { .sa_handler = on_signal };
	sigemptyset(&action.sa_mask);
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGINT, &action, NULL);
	fprintf(stderr, "w132d-btattach: HCI H4 attached to %s\n", device);
	while (!stopping)
		pause();

	ldisc = N_TTY;
	(void)ioctl(fd, TIOCSETD, &ldisc);
	close(fd);
	return EXIT_SUCCESS;
}
