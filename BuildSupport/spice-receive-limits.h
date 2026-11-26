/* Review-only receive policy for the pinned spice-gtk candidate. */
#ifndef MRV_RECEIVE_LIMITS_H
#define MRV_RECEIVE_LIMITS_H

#include <glib.h>
#include <stdio.h>

/* Fixed test-only diagnostics bypass application GLib log handlers.
 * No remote-controlled values, addresses, tickets or packet bytes. */
static inline void mrv_receive_test_trace(const char *marker)
{
    if (g_strcmp0(g_getenv("MRV_ENABLE_INTEGRATION_PROBES"), "1") == 0 &&
        g_strcmp0(g_getenv("MRV_RECEIVE_TEST_TRACE"), "1") == 0) {
        fputs(marker, stderr);
        fputc('\n', stderr);
        fflush(stderr);
    }
}
#define MRV_LINK_MAX ((guint32)(1024u * 1024u))
#define MRV_WIRE_MAX ((guint32)(128u * 1024u * 1024u))
#define MRV_AGENT_MAX ((guint32)(16u * 1024u * 1024u + 64u * 1024u))

static inline gboolean mrv_link_size_allowed(guint32 size)
{
    return size <= MRV_LINK_MAX; /* protocol-specific minimum checked by caller */
}

static inline gboolean mrv_wire_size_allowed(guint32 size)
{
    return size <= MRV_WIRE_MAX && size <= G_MAXINT;
}

static inline gboolean mrv_agent_size_allowed(guint32 size)
{
    return size <= MRV_AGENT_MAX;
}
#endif
