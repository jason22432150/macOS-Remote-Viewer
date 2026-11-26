#include "spice-receive-limits.h"
#include <stdint.h>
#include <stdio.h>

int main(void)
{
    g_assert_true(mrv_link_size_allowed(MRV_LINK_MAX));
    g_assert_false(mrv_link_size_allowed(MRV_LINK_MAX + 1u));
    g_assert_false(mrv_link_size_allowed(UINT32_MAX));
    g_assert_true(mrv_wire_size_allowed(0));
    g_assert_true(mrv_wire_size_allowed(MRV_WIRE_MAX));
    g_assert_false(mrv_wire_size_allowed(MRV_WIRE_MAX + 1u));
    g_assert_false(mrv_wire_size_allowed((guint32)G_MAXINT + 1u));
    g_assert_false(mrv_wire_size_allowed(UINT32_MAX));
    g_assert_true(mrv_agent_size_allowed(0));
    g_assert_true(mrv_agent_size_allowed(16u * 1024u * 1024u + 8u));
    g_assert_true(mrv_agent_size_allowed(MRV_AGENT_MAX));
    g_assert_false(mrv_agent_size_allowed(MRV_AGENT_MAX + 1u));
    g_assert_false(mrv_agent_size_allowed(UINT32_MAX));
    puts("MRV_SPICE_RECEIVE_POLICY_BOUNDARIES_OK");
    return 0;
}
