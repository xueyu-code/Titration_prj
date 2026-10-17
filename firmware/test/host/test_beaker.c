/* sim/beaker.c against textbook values. */
#include <math.h>

#include "unity.h"
#include "sim/beaker.h"

#define ACID (-0.1) /* net strong base molarity of the 0.1 M acid reagent */
#define BASE 0.1

void setUp(void) {}
void tearDown(void) {}

/* beaker_init(p) -> ph == p (buffered and plain); a zero dose finds p again */
static void test_init_keeps_ph(void)
{
    const double phs[] = {2.5, 5.5, 7.0, 8.5, 11.3};
    for (int buffered = 0; buffered <= 1; buffered++) {
        for (size_t i = 0; i < sizeof phs / sizeof phs[0]; i++) {
            beaker_t b;
            beaker_init(&b, phs[i], buffered);
            TEST_ASSERT_EQUAL_DOUBLE(phs[i], b.ph);
            TEST_ASSERT_EQUAL_DOUBLE(0.050, b.volume_l);
            beaker_dose(&b, 0.0, BASE);
            TEST_ASSERT_DOUBLE_WITHIN(1e-9, phs[i], b.ph);
        }
    }
}

/* 50 mL water + 1 mL 0.1 M acid -> pH ~2.71 */
static void test_strong_acid_in_water(void)
{
    beaker_t b;
    beaker_init(&b, 7.0, false);
    beaker_dose(&b, 1000.0, ACID);
    /* [H+] = 1e-4 mol / 0.051 L */
    TEST_ASSERT_DOUBLE_WITHIN(0.001, -log10(1e-4 / 0.051), b.ph);
    TEST_ASSERT_DOUBLE_WITHIN(0.01, 2.71, b.ph);
    TEST_ASSERT_DOUBLE_WITHIN(1e-12, 0.051, b.volume_l);

    /* the mirror image with base: pOH = 2.71 */
    beaker_init(&b, 7.0, false);
    beaker_dose(&b, 1000.0, BASE);
    TEST_ASSERT_DOUBLE_WITHIN(0.001, 14.0 + log10(1e-4 / 0.051), b.ph);
}

/* same dose moves a buffered sample far less near pKa 7.20 */
static void test_buffer_resists(void)
{
    beaker_t plain, buffered;
    beaker_init(&plain, 7.2, false);
    beaker_init(&buffered, 7.2, true);
    beaker_dose(&plain, 1000.0, ACID);
    beaker_dose(&buffered, 1000.0, ACID);

    double plain_drop = 7.2 - plain.ph;
    double buffered_drop = 7.2 - buffered.ph;
    TEST_ASSERT_TRUE(plain_drop > 4.0);
    TEST_ASSERT_TRUE(buffered_drop > 0.3);
    TEST_ASSERT_TRUE(buffered_drop < 1.0);
    TEST_ASSERT_TRUE(buffered_drop * 4.0 < plain_drop);
}

/* base raises, acid lowers, always */
static void test_monotonic(void)
{
    for (int buffered = 0; buffered <= 1; buffered++) {
        for (double start = 3.0; start <= 11.0; start += 2.0) {
            beaker_t up, down;
            beaker_init(&up, start, buffered);
            beaker_init(&down, start, buffered);
            for (int i = 0; i < 20; i++) {
                double up_before = up.ph, down_before = down.ph;
                beaker_dose(&up, 5.0 + 10.0 * i, BASE);
                beaker_dose(&down, 5.0 + 10.0 * i, ACID);
                TEST_ASSERT_TRUE(up.ph > up_before);
                TEST_ASSERT_TRUE(down.ph < down_before);
            }
        }
    }
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
