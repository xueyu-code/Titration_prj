/* sim/beaker.c against textbook values.
 * TODO(WP4): implement every case below; none may stay ignored. */
#include "unity.h"
#include "sim/beaker.h"

void setUp(void) {}
void tearDown(void) {}

/* beaker_init(p) -> ph == p (buffered and plain) */
static void test_init_keeps_ph(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

/* 50 mL water + 1 mL 0.1 M acid -> pH ~2.71 */
static void test_strong_acid_in_water(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

/* same dose moves a buffered sample far less near pKa 7.20 */
static void test_buffer_resists(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

/* base raises, acid lowers, always */
static void test_monotonic(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_init_keeps_ph);
    RUN_TEST(test_strong_acid_in_water);
    RUN_TEST(test_buffer_resists);
    RUN_TEST(test_monotonic);
    return UNITY_END();
}
