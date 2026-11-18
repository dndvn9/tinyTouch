#include <assert.h>
#include <stdbool.h>
#include <stdint.h>

#define DEVICE_MODE_PIV 1
#define KEYBOARD_MODIFIER_LEFTSHIFT 2
#define pdMS_TO_TICKS(ms) (ms)
typedef unsigned TickType_t;
static bool enabled, visible, suspended, allow_wake, resume, disconnect, send_ok;
static unsigned now, session, remote_requests, keypresses, insertions;

static bool usb_ccid_touch_enabled(void) { return enabled; }
static bool usb_ccid_piv_visible(void) { return visible; }
static bool tud_mounted(void) { return true; }
static bool tud_suspended(void) { return suspended; }
static bool tud_remote_wakeup(void) { remote_requests++; return allow_wake; }
static int device_config_mode(void) { return DEVICE_MODE_PIV; }
static unsigned hid_session_id(void) { return session; }
static unsigned xTaskGetTickCount(void) { return now; }
static void vTaskDelay(unsigned ticks) {
  now += ticks;
  if (resume) suspended = false;
  if (disconnect) session++;
}
static bool send_key(uint8_t modifier, uint8_t key, unsigned expected_session) {
  assert(!suspended && !insertions && expected_session == session);
  assert(modifier == KEYBOARD_MODIFIER_LEFTSHIFT && key == 0);
  keypresses++;
  return send_ok;
}
static void touch_pin_hid_log_event(const char *name, int value) {
  (void)name; (void)value;
}
static void usb_ccid_touch_begin(void) {
  assert(visible || (keypresses == 1 && now >= 1000));
  insertions++;
}

/* prepare */

static void reset(void) {
  enabled = send_ok = allow_wake = true;
  visible = suspended = disconnect = resume = false;
  now = session = remote_requests = keypresses = insertions = 0;
}

int main(void) {
  reset();
  assert(prepare_piv_touch() && insertions == 1 && !remote_requests);
  reset(); suspended = resume = true;
  assert(prepare_piv_touch() && remote_requests == 1 && insertions == 1);
  reset(); suspended = true; allow_wake = false;
  assert(!prepare_piv_touch() && !keypresses && !insertions);
  reset(); suspended = true;
  assert(!prepare_piv_touch() && now == 2000 && !insertions);
  reset(); disconnect = true;
  assert(!prepare_piv_touch() && !insertions);
  reset(); send_ok = false;
  assert(!prepare_piv_touch() && !insertions);
  reset(); visible = true;
  assert(prepare_piv_touch() && !keypresses && !now && insertions == 1);
  reset(); enabled = false;
  assert(prepare_piv_touch() && !keypresses && !insertions);
  return 0;
}
