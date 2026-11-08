#ifndef ONECOPY_PLATFORM_H
#define ONECOPY_PLATFORM_H
#ifdef __cplusplus
extern "C" {
#endif
// ACL: 1 = exists, 0 = no extended ACL, -1 = unknown/error.
int oc_extended_acl_status(const char *path);
// Xattrs: 1 = all names/values identical, 0 = differ,
// -1 = cannot read consistently, -2 = unusually large attribute.
int oc_compare_xattrs(const char *path_a, const char *path_b);
#ifdef __cplusplus
}
#endif
#endif
