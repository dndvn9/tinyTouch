// Platform hooks for the native macOS pairing integration test.
#include <stdlib.h>
#include "esp_random.h"
#include "esp_timer.h"

int64_t test_clock_us = 1;

int64_t esp_timer_get_time(void) { return test_clock_us; }

void esp_fill_random(void *buffer, size_t length) {
  arc4random_buf(buffer, length);
}
