/* Independent CI-only dynamic interposer; never bundled in the App. */
#include <glib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static atomic_bool injected = ATOMIC_VAR_INIT(0);

static gpointer fault_try_malloc0(gsize bytes)
{
    const char *kind = getenv("MRV_TEST_ALLOC_KIND");
    gsize target = 0;
    if (kind && strcmp(kind, "agent") == 0)
        target = 96u * 1024u * 1024u - 5u * (16u * 1024u * 1024u + 64u * 1024u);
    else if (kind && strcmp(kind, "wire") == 0)
        target = 40u * 1024u * 1024u;

    if (target && bytes == target && !atomic_exchange_explicit(&injected, 1, memory_order_relaxed)) {
        fputs("MRV_TEST_ALLOC_FAULT_INJECTED\n", stderr);
        fflush(stderr);
        return NULL;
    }
    /* dyld leaves the original symbol callable from its interposing image. */
    return g_try_malloc0(bytes);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    const void *replacement;
    const void *original;
} entry = {
    (const void *)(uintptr_t)&fault_try_malloc0,
    (const void *)(uintptr_t)&g_try_malloc0,
};
