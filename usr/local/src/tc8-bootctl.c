// tc8-bootctl — read/repair the AOSP bootloader_control block in `misc`.
//
// boota decrements the active slot's tries_remaining on EVERY boot and only
// stops once successful_boot is set — which stock Android does from
// userspace and Debian never did: after 7 boots without a reflash the slot
// went "unbootable" and the panel stranded itself in fastboot (root-caused
// on the bench, 2026-07-07). tc8-boot-successful.service runs
// `tc8-bootctl mark-successful` late in boot to close the loop.
//
// Struct (32 B at offset 2048 in misc, verified against a live dump):
//   [0..3] slot_suffix  [4..7] magic "BCAB"  [8] version  [9] nb_slot bits
//   [10..11] rsvd  [12..19] uint16 slot_info[4]  [20..27] rsvd
//   [28..31] crc32(zlib) over bytes 0..27
// slot_info bits (LSB first): priority:4 tries:3 successful:1 verity:1
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>

#define BC_OFF   2048
#define BC_MAGIC 0x42414342u

static uint32_t crc32z(const uint8_t *p, size_t n)
{
	uint32_t c = 0xffffffffu;
	for (size_t i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320u & (-(int32_t)(c & 1)));
	}
	return ~c;
}

static int find_misc(char *out, size_t n)
{
	// PARTNAME from sysfs — works before udev symlinks exist.
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;
	char path[256], buf[128];

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		FILE *f;
		snprintf(path, sizeof(path), "/sys/class/block/%s/uevent", e->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		while (fgets(buf, sizeof(buf), f)) {
			if (!strcmp(buf, "PARTNAME=misc\n")) {
				snprintf(out, n, "/dev/%s", e->d_name);
				fclose(f);
				closedir(d);
				return 0;
			}
		}
		fclose(f);
	}
	closedir(d);
	return -1;
}

static int booted_slot(void)
{
	char buf[4096] = "";
	FILE *f = fopen("/proc/cmdline", "r");
	char *p;

	if (f) {
		fread(buf, 1, sizeof(buf) - 1, f);
		fclose(f);
	}
	p = strstr(buf, "androidboot.slot_suffix=_");
	if (p)
		return p[strlen("androidboot.slot_suffix=_")] - 'a';
	return 0; // we only ship slot a
}

int main(int argc, char **argv)
{
	uint8_t bc[32];
	char dev[64];
	uint16_t si;
	int fd, slot;

	if (find_misc(dev, sizeof(dev))) {
		fprintf(stderr, "tc8-bootctl: no misc partition\n");
		return 1;
	}
	fd = open(dev, O_RDWR);
	if (fd < 0 || pread(fd, bc, 32, BC_OFF) != 32) {
		perror("tc8-bootctl: read misc");
		return 1;
	}
	if (*(uint32_t *)(bc + 4) != BC_MAGIC) {
		fprintf(stderr, "tc8-bootctl: no BCAB magic — bootctrl absent, nothing to do\n");
		return 0;
	}

	if (argc > 1 && !strcmp(argv[1], "status")) {
		for (int i = 0; i < 2; i++) {
			si = (uint16_t)(bc[12 + 2 * i] | bc[13 + 2 * i] << 8);
			printf("slot %c: priority=%u tries=%u successful=%u\n",
			       'a' + i, si & 0xf, (si >> 4) & 7, (si >> 7) & 1);
		}
		return 0;
	}

	// mark-successful (default): booted slot -> priority 15, tries 7,
	// successful 1. boota stops decrementing once successful is set.
	slot = booted_slot();
	si = 0xf | (7 << 4) | (1 << 7);
	bc[12 + 2 * slot] = si & 0xff;
	bc[13 + 2 * slot] = si >> 8;
	*(uint32_t *)(bc + 28) = crc32z(bc, 28);
	if (pwrite(fd, bc, 32, BC_OFF) != 32) {
		perror("tc8-bootctl: write misc");
		return 1;
	}
	fsync(fd);
	close(fd);
	printf("tc8-bootctl: slot %c marked successful\n", 'a' + slot);
	return 0;
}
