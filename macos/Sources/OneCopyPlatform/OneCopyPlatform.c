#include "OneCopyPlatform.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <sys/acl.h>
#include <sys/xattr.h>

int oc_extended_acl_status(const char *path) {
    errno = 0;
    acl_t acl = acl_get_file(path, ACL_TYPE_EXTENDED);
    if (acl != NULL) { acl_free(acl); return 1; }
    if (errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP) return 0;
    return -1;
}

#define OC_MAX_XATTR_BYTES (4 * 1024 * 1024)
static int oc_xattr_value(const char *path, const char *name, void **out, size_t *size) {
    ssize_t s = getxattr(path, name, NULL, 0, 0, 0);
    if (s < 0) return -1;
    if (s > OC_MAX_XATTR_BYTES) return -2;
    size_t count = (size_t)s;
    void *ptr = malloc(count ? count : 1);
    if (!ptr) return -1;
    ssize_t got = getxattr(path, name, ptr, count, 0, 0);
    if (got < 0 || got != s) { free(ptr); return -1; }
    *out = ptr;
    *size = count;
    return 0;
}

int oc_compare_xattrs(const char *a, const char *b) {
    ssize_t sz_a = listxattr(a, NULL, 0, 0);
    ssize_t sz_b = listxattr(b, NULL, 0, 0);
    if (sz_a < 0 || sz_b < 0) return -1;
    if (sz_a != sz_b) return 0;
    if (sz_a == 0) return 1;
    char *names = malloc((size_t)sz_a);
    if (!names) return -1;
    ssize_t got = listxattr(a, names, (size_t)sz_a, 0);
    if (got != sz_a) { free(names); return -1; }
    char *p = names;
    char *end = names + sz_a;
    int outcome = 1;
    while (p < end) {
        size_t remaining = (size_t)(end - p);
        size_t name_len = strnlen(p, remaining);
        if (name_len == remaining) { outcome = -1; break; }
        void *buf_a = NULL, *buf_b = NULL;
        size_t size_a = 0, size_b = 0;
        int result_a = oc_xattr_value(a, p, &buf_a, &size_a);
        int result_b = oc_xattr_value(b, p, &buf_b, &size_b);
        if (result_a == -2 || result_b == -2) outcome = -2;
        else if (result_a || result_b) outcome = -1;
        else if (size_a != size_b || memcmp(buf_a, buf_b, size_a) != 0) outcome = 0;
        free(buf_a); free(buf_b);
        if (outcome != 1) break;
        p += name_len + 1;
    }
    free(names);
    return outcome;
}
#else
int oc_extended_acl_status(const char *path) { (void)path; return 0; }
int oc_compare_xattrs(const char *a, const char *b) { (void)a; (void)b; return 1; }
#endif
