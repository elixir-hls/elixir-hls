/* host test only: what the Zephyr port's sys.c does for NIF collections (generic_unix has no such list) */
#include <string.h>
#include <nifs.h>
#include <platform_nifs.h>
#include <portnifloader.h>
struct NifCollectionDefListItem *nif_collection_list;
const struct Nif *__real_platform_nifs_get_nif(const char *nifname);
const struct Nif *__wrap_platform_nifs_get_nif(const char *nifname)
{
    const struct Nif *res = __real_platform_nifs_get_nif(nifname);
    if (res) return res;
    for (struct NifCollectionDefListItem *item = nif_collection_list; item != NULL; item = item->next) {
        res = item->def->nif_collection_resolve_nif_cb(nifname);
        if (res) return res;
    }
    return NULL;
}
