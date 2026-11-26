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
/* Aggregate across all main channels in this process, not an RSS limit.
 * Leave headroom for four concurrent maximum-size clipboard messages. */
#define MRV_AGENT_TOTAL_MAX ((gsize)(96u * 1024u * 1024u))
/* Process-wide owning wire payload allocations, independent of Agent.
 * Four maximum-size frames plus one frame of headroom. Not total RSS. */
#define MRV_WIRE_TOTAL_MAX ((gsize)(640u * 1024u * 1024u))

typedef struct {
    GMutex lock;
    gsize used;
    gsize limit;
} MRVReceiveBudget;

static inline gboolean mrv_receive_budget_reserve(MRVReceiveBudget *budget, gsize bytes)
{
    gboolean ok;
    g_mutex_lock(&budget->lock);
    ok = bytes > 0 && budget->used <= budget->limit &&
         bytes <= budget->limit - budget->used;
    if (ok)
        budget->used += bytes;
    g_mutex_unlock(&budget->lock);
    return ok;
}

static inline void mrv_receive_budget_release(MRVReceiveBudget *budget, gsize bytes)
{
    if (!bytes)
        return;
    g_mutex_lock(&budget->lock);
    /* An accounting mismatch is an internal bug; fail closed (never wrap). */
    if (G_UNLIKELY(bytes > budget->used))
        g_error("MRV receive budget accounting mismatch");
    budget->used -= bytes;
    g_mutex_unlock(&budget->lock);
}

static inline guint8 *mrv_receive_budget_alloc(MRVReceiveBudget *budget, gsize bytes,
                                              gsize *charge)
{
    guint8 *buffer;
    bytes = MAX(bytes, (gsize)1);
    if (*charge != 0)
        return NULL;
    if (!mrv_receive_budget_reserve(budget, bytes)) {
        mrv_receive_test_trace("MRV_NATIVE_RECEIVE_BUDGET_EXHAUSTED");
        return NULL;
    }
    buffer = g_try_malloc0(bytes);
    if (!buffer) {
        mrv_receive_budget_release(budget, bytes);
        mrv_receive_test_trace("MRV_NATIVE_RECEIVE_ALLOC_FAILED");
        return NULL;
    }
    *charge = bytes;
    if (bytes >= 1024u * 1024u)
        mrv_receive_test_trace("MRV_NATIVE_RECEIVE_LARGE_RESERVED");
    return buffer;
}

static inline void mrv_receive_budget_clear(MRVReceiveBudget *budget, guint8 **buffer,
                                            gsize *charge)
{
    gsize bytes = *charge;
    g_clear_pointer(buffer, g_free);
    *charge = 0;
    mrv_receive_budget_release(budget, bytes);
    if (bytes >= 1024u * 1024u)
        mrv_receive_test_trace("MRV_NATIVE_RECEIVE_LARGE_RELEASED");
}

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
