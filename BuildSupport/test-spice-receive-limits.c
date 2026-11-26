#include "spice-receive-limits.h"
#include <stdint.h>
#include <stdio.h>

typedef struct {
    MRVReceiveBudget budget;
    GMutex lock;
    GCond ready;
    guint arrived;
    guint accepted;
} ConcurrentBudget;

static gpointer contend(gpointer data)
{
    ConcurrentBudget *state = data;
    gsize charge = 0;
    guint8 *buffer = mrv_receive_budget_alloc(&state->budget, 16, &charge);
    g_mutex_lock(&state->lock);
    if (buffer)
        ++state->accepted;
    ++state->arrived;
    g_cond_broadcast(&state->ready);
    while (state->arrived < 8)
        g_cond_wait(&state->ready, &state->lock);
    g_mutex_unlock(&state->lock);
    mrv_receive_budget_clear(&state->budget, &buffer, &charge);
    return NULL;
}

static void test_budget(void)
{
    MRVReceiveBudget budget = { .limit = MRV_AGENT_TOTAL_MAX };
    for (unsigned i = 0; i < 5; ++i)
        g_assert_true(mrv_receive_budget_reserve(&budget, MRV_AGENT_MAX));
    g_assert_false(mrv_receive_budget_reserve(&budget, MRV_AGENT_MAX));
    g_assert_false(mrv_receive_budget_reserve(&budget, G_MAXSIZE));
    for (unsigned i = 0; i < 5; ++i)
        mrv_receive_budget_release(&budget, MRV_AGENT_MAX);
    g_assert_cmpuint(budget.used, ==, 0);
    g_assert_true(mrv_receive_budget_reserve(&budget, budget.limit));
    g_assert_false(mrv_receive_budget_reserve(&budget, 1));
    mrv_receive_budget_release(&budget, budget.limit);
    g_mutex_clear(&budget.lock);

    MRVReceiveBudget small = { .limit = 32 };
    gsize a_charge = 0, b_charge = 0;
    guint8 *a = mrv_receive_budget_alloc(&small, 0, &a_charge);
    g_assert_nonnull(a);
    g_assert_cmpuint(a_charge, ==, 1);
    g_assert_cmpuint(a[0], ==, 0);
    guint8 *b = mrv_receive_budget_alloc(&small, 32, &b_charge);
    g_assert_null(b);
    g_assert_cmpuint(b_charge, ==, 0);
    mrv_receive_budget_clear(&small, &a, &a_charge);
    mrv_receive_budget_clear(&small, &a, &a_charge);
    b = mrv_receive_budget_alloc(&small, 32, &b_charge);
    g_assert_nonnull(b);
    g_assert_cmpuint(b[31], ==, 0);
    g_assert_cmpuint(small.used, ==, 32);
    mrv_receive_budget_clear(&small, &b, &b_charge);
    g_assert_cmpuint(small.used, ==, 0);
    g_mutex_clear(&small.lock);

    ConcurrentBudget state = { .budget = { .limit = 64 } };
    GThread *threads[8];
    for (unsigned i = 0; i < G_N_ELEMENTS(threads); ++i)
        threads[i] = g_thread_new("receive-budget", contend, &state);
    for (unsigned i = 0; i < G_N_ELEMENTS(threads); ++i)
        g_thread_join(threads[i]);
    g_assert_cmpuint(state.accepted, ==, 4);
    g_assert_cmpuint(state.budget.used, ==, 0);
    g_cond_clear(&state.ready);
    g_mutex_clear(&state.lock);
    g_mutex_clear(&state.budget.lock);
    puts("MRV_SPICE_AGENT_AGGREGATE_BUDGET_OK");
}

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
    test_budget();
    puts("MRV_SPICE_RECEIVE_POLICY_BOUNDARIES_OK");
    return 0;
}
