/* Review-only receive policy for the pinned spice-gtk candidate. */
#ifndef MRV_RECEIVE_LIMITS_H
#define MRV_RECEIVE_LIMITS_H

#include <glib.h>
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
