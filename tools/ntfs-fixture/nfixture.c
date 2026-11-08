/*
 * nfixture — fixture helper for the disktriage NTFS live tests.
 *
 * NOT product code. It exists only because ntfsprogs has no mkdir/rm
 * utility: ntfscp can create files, but nothing in the shipped tool set can
 * create a directory without mounting the image.
 *
 * It links libntfs-3g directly and is the only thing in the fixture builder
 * that opens an image read-write. The generated images are synthetic: mkntfs
 * plus files written by tools/ntfs-fixture/generate.sh. They contain no
 * device data, no serials and nothing from a real disk.
 *
 * usage:
 *   nfixture mkdir <image> /a/b/c
 *   nfixture rm    <image> /path/to/file
 */
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/attrib.h>

static ntfs_inode *open_root(ntfs_volume *vol)
{
	return ntfs_pathname_to_inode(vol, NULL, "/");
}

/* mkdir -p one component at a time, relative to root. */
static int do_mkdir(ntfs_volume *vol, const char *path)
{
	ntfs_inode *dir = open_root(vol);
	char *copy, *p, *save = NULL;

	if (!dir) {
		fprintf(stderr, "open root: %s\n", strerror(errno));
		return 1;
	}
	copy = strdup(path);
	if (!copy) return 1;

	for (p = strtok_r(copy, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
		u64 inum;
		ntfschar *ucs = NULL;
		int len;

		if (!*p) continue;
		inum = ntfs_inode_lookup_by_mbsname(dir, p);
		/* libntfs returns (u64)-1 (not 0) when the name is absent */
		if (inum && inum != (u64)-1) {
			ntfs_inode *next = ntfs_inode_open(vol, inum);
			ntfs_inode_close(dir);
			if (!next) {
				fprintf(stderr, "open %s: %s\n", p, strerror(errno));
				free(copy);
				return 1;
			}
			dir = next;
			continue;
		}
		len = ntfs_mbstoucs(p, &ucs);
		if (len < 0) {
			fprintf(stderr, "mbstoucs %s: %s\n", p, strerror(errno));
			free(copy);
			return 1;
		}
		{
			ntfs_inode *nd = ntfs_create(dir, 0, ucs, (u8)len, S_IFDIR);
			free(ucs);
			if (!nd) {
				fprintf(stderr, "mkdir %s: %s\n", p, strerror(errno));
				ntfs_inode_close(dir);
				free(copy);
				return 1;
			}
			ntfs_inode_close(dir);
			dir = nd;
		}
	}
	ntfs_inode_close(dir);
	free(copy);
	return 0;
}

static int do_rm(ntfs_volume *vol, const char *path)
{
	ntfs_inode *ni, *dir;
	char *copy, *base;

	copy = strdup(path);
	if (!copy) return 1;
	base = strrchr(copy, '/');
	if (!base || base == copy) {
		fprintf(stderr, "rm needs an absolute path\n");
		free(copy);
		return 1;
	}
	*base++ = '\0';
	dir = ntfs_pathname_to_inode(vol, NULL, copy);
	if (!dir) {
		fprintf(stderr, "open dir %s: %s\n", copy, strerror(errno));
		free(copy);
		return 1;
	}
	ni = ntfs_pathname_to_inode(vol, NULL, path);
	if (!ni) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		ntfs_inode_close(dir);
		free(copy);
		return 1;
	}
	{
		ntfschar *ucs = NULL;
		int len = ntfs_mbstoucs(base, &ucs);
		if (len < 0) {
			fprintf(stderr, "mbstoucs %s: %s\n", base, strerror(errno));
			ntfs_inode_close(ni);
			ntfs_inode_close(dir);
			free(copy);
			return 1;
		}
		if (ntfs_delete(vol, NULL, ni, dir, ucs, (u8)len) != 0) {
			fprintf(stderr, "delete %s: %s\n", path, strerror(errno));
			free(ucs);
			ntfs_inode_close(dir);
			free(copy);
			return 1;
		}
		free(ucs);
	}
	ntfs_inode_close(dir);
	free(copy);
	return 0;
}

int main(int argc, char **argv)
{
	ntfs_volume *vol;
	int rc;

	if (argc != 4) {
		fprintf(stderr, "usage: %s mkdir|rm <image> <path>\n", argv[0]);
		return 2;
	}
	vol = ntfs_mount(argv[2], NTFS_MNT_NONE);
	if (!vol) {
		fprintf(stderr, "mount %s: %s\n", argv[2], strerror(errno));
		return 1;
	}
	if (!strcmp(argv[1], "mkdir"))
		rc = do_mkdir(vol, argv[3]);
	else if (!strcmp(argv[1], "rm"))
		rc = do_rm(vol, argv[3]);
	else {
		fprintf(stderr, "unknown command %s\n", argv[1]);
		rc = 2;
	}
	if (ntfs_umount(vol, FALSE) != 0) {
		fprintf(stderr, "umount failed: %s\n", strerror(errno));
		rc = 1;
	}
	return rc;
}
