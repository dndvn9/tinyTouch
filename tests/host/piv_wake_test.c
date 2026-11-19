#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DEVICE_MODE_HID 0
#define DEVICE_MODE_PIV 1
#define KEYBOARD_MODIFIER_LEFTSHIFT 2
#define pdMS_TO_TICKS(ms) ((ms) / 10)
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
typedef unsigned TickType_t;
typedef struct { unsigned slot; } fingerprint_match_t;
typedef struct { bool piv_auto_type; } device_options_t;
typedef enum { HOST_SCREEN_NONE, HOST_SCREEN_UNLOCKED, HOST_SCREEN_PASSWORD } host_screen_t;
static host_screen_t screen, next_screen;
static int64_t screen_at;
static unsigned next_screen_at;
static bool enabled, suspended, allow_wake, send_ok, reconnect_deferred;
static bool unmounted;
static unsigned resume_at, disconnect_at, lift_at, prompt_at, expires_at, hid_ready_at, reset_at;
static unsigned grants, pin_entries, cancels;
static uint16_t delay_ms;
static device_options_t options;
static unsigned now, session, remote_requests, keypresses, insertions;

static bool usb_ccid_touch_enabled(void) { return enabled; }
static void usb_ccid_defer_reconnect_for_touch(void) { reconnect_deferred = true; }
static bool tud_mounted(void) { return !unmounted; }
static bool tud_hid_ready(void) { return now >= hid_ready_at; }
static bool tud_suspended(void) { return suspended; }
static bool tud_remote_wakeup(void) {
  assert(reconnect_deferred);
  remote_requests++;
  return allow_wake;
}
static int device_config_mode(void) { return DEVICE_MODE_PIV; }
static unsigned hid_session_id(void) { return session; }
static unsigned xTaskGetTickCount(void) { return pdMS_TO_TICKS(now); }
static int64_t esp_timer_get_time(void) { return (int64_t)now * 1000; }
static int64_t esp_timer_get_time(void);
static void vTaskDelay(unsigned ticks) {
  now += ticks * 10;
  // The helper reports again once it reconnects after the card is inserted.
  if (next_screen_at && now >= next_screen_at) {
    screen = next_screen; screen_at = esp_timer_get_time(); next_screen_at = 0;
  }
  if (resume_at && now >= resume_at) suspended = false;
  if (disconnect_at && now >= disconnect_at) { session++; disconnect_at = 0; }
  // A host that resets the bus on wake remounts the device on a new session.
  if (reset_at && now >= reset_at) { suspended = false; unmounted = true; session++; reset_at = 0; }
  if (unmounted && hid_ready_at && now >= hid_ready_at) unmounted = false;
}
static bool send_key(uint8_t modifier, uint8_t key, unsigned expected_session) {
  assert((reconnect_deferred || screen == HOST_SCREEN_UNLOCKED) &&
         !suspended && !insertions && expected_session == session);
  assert(modifier == KEYBOARD_MODIFIER_LEFTSHIFT && key == 0);
  keypresses++;
  return send_ok;
}
static host_screen_t host_screen_report(int64_t *reported_at) {
  *reported_at = screen_at;
  return screen;
}
static void touch_pin_hid_log_event(const char *name, int value) {
  (void)name; (void)value;
}
static void usb_ccid_touch_begin(void) {
  assert(keypresses >= 1 && now >= 700);
  insertions++;
  expires_at = now + 20000;
}

static bool usb_ccid_wait_for_piv(void) {
  if (enabled) { assert(insertions == 1); session++; }
  return true;
}
static bool usb_ccid_touch_ready(void) { return now < expires_at; }
static void usb_ccid_touch_cancel(void) { expires_at = 0; cancels++; }
static bool fingerprint_present_hint(void) { return now < lift_at; }
static void fingerprint_wait_for_touch(void) { vTaskDelay(1); }
static bool fingerprint_prompted_authorization_active(void) { return prompt_at && now >= prompt_at; }
static uint16_t device_config_piv_delay_ms(void) { return delay_ms; }
static device_options_t device_config_options(void) { return options; }
static bool request_and_type_password(fingerprint_match_t match) { (void)match; return false; }
static void piv_note_user_presence(void) { grants++; }
static bool type_ascii_in_session(const uint8_t *data, size_t length, uint32_t expected) {
  assert(data && length == 6 && grants == 1 && expected == session);
  pin_entries++;
  return true;
}

/* prepare */

static void reset(void) {
  enabled = send_ok = allow_wake = true;
  suspended = reconnect_deferred = unmounted = false;
  resume_at = disconnect_at = lift_at = prompt_at = expires_at = hid_ready_at = reset_at = 0;
  grants = pin_entries = cancels = 0;
  options.piv_auto_type = true;
  delay_ms = 50;
  now = session = remote_requests = keypresses = insertions = 0;
  screen = next_screen = HOST_SCREEN_NONE;
  screen_at = 0;
  next_screen_at = 0;
}

// A helper report made `age_ms` before a touch at 10 s of uptime.
static void report(host_screen_t state, unsigned age_ms) {
  now = 10000;
  screen = state;
  screen_at = (int64_t)(now - age_ms) * 1000;
}

int main(void) {
  reset();
  assert(prepare_piv_touch() && insertions == 1 && !remote_requests);
  reset(); suspended = true; resume_at = 1500;
  assert(prepare_piv_touch() && remote_requests == 1 && insertions == 1 && now == 2200);
  // A resume request missed while the Mac enters sleep is repeated.
  reset(); suspended = true; resume_at = 4000;
  assert(prepare_piv_touch() && remote_requests == 2 && insertions == 1 && now == 4700);
  // A bus reset during wake moves the touch to the new connection.
  reset(); suspended = true; reset_at = 1500; hid_ready_at = 3000;
  assert(prepare_piv_touch() && remote_requests == 1 && keypresses == 1 && insertions == 1);
  assert(now == 3700);
  // A Mac that is slow to poll HID after wake still gets the wake key.
  reset(); hid_ready_at = 5000;
  assert(prepare_piv_touch() && keypresses == 1 && insertions == 1 && now == 5700);
  reset(); suspended = true; allow_wake = false;
  assert(!prepare_piv_touch() && !keypresses && !insertions);
  reset(); suspended = true;
  assert(!prepare_piv_touch() && now == 20000 && !insertions);
  // A reconnect while the display wakes repeats the wake key on the new session.
  reset(); disconnect_at = 500;
  assert(prepare_piv_touch() && keypresses == 2 && insertions == 1 && now == 1400);
  reset(); hid_ready_at = 30000;
  assert(!prepare_piv_touch() && !keypresses && !insertions && now == 20000);
  reset(); send_ok = false;
  assert(!prepare_piv_touch() && !insertions);
  reset(); enabled = false;
  assert(prepare_piv_touch() && !reconnect_deferred && !keypresses && !insertions);

  fingerprint_match_t match = {.slot = 1};
  const uint16_t delays[] = {0, 25, 50, 100};
  for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
    reset(); delay_ms = delays[i];
    handle_fingerprint_match(match);
    assert(pin_entries == 1 && !cancels && now >= 700 + (unsigned)delay_ms);
    assert(now < 710 + (unsigned)delay_ms);
  }
  reset(); lift_at = 7000;
  handle_fingerprint_match(match);
  assert(pin_entries == 1 && now == lift_at && !cancels);
  reset(); lift_at = 30000;
  handle_fingerprint_match(match);
  assert(!pin_entries && !grants && cancels == 1 && now == 20700);
  reset(); lift_at = 7000; disconnect_at = 3000;
  handle_fingerprint_match(match);
  assert(!pin_entries && !grants && cancels == 1 && now == 3000);
  reset(); lift_at = 7000; prompt_at = 3000;
  handle_fingerprint_match(match);
  assert(!pin_entries && !grants && cancels == 1 && now == 3000);
  reset(); options.piv_auto_type = false; lift_at = 7000;
  handle_fingerprint_match(match);
  assert(!pin_entries && grants == 1 && !cancels && now == 750);
  reset(); enabled = false; lift_at = 7000;
  handle_fingerprint_match(match);
  assert(pin_entries == 1 && !insertions && now == 0);

  // An unlocked Mac only wakes its display: no card, no keystrokes.
  reset(); report(HOST_SCREEN_UNLOCKED, 1000);
  handle_fingerprint_match(match);
  assert(keypresses == 1 && !insertions && !pin_entries && !grants && !reconnect_deferred);
  reset(); enabled = false; report(HOST_SCREEN_UNLOCKED, 1000);
  handle_fingerprint_match(match);
  assert(!keypresses && !pin_entries && grants == 1);
  // A locked Mac types once the reconnected helper confirms the password field.
  reset(); report(HOST_SCREEN_PASSWORD, 1000);
  next_screen = HOST_SCREEN_PASSWORD; next_screen_at = 12500;
  handle_fingerprint_match(match);
  assert(pin_entries == 1 && grants == 1 && !cancels && now == 12500);
  // A helper that was reporting must confirm before keystrokes are sent.
  reset(); report(HOST_SCREEN_PASSWORD, 1000);
  handle_fingerprint_match(match);
  assert(!pin_entries && !grants && cancels == 1 && now == 13750);
  // Unlocking while the card is shown blocks entry.
  reset(); report(HOST_SCREEN_PASSWORD, 1000);
  next_screen = HOST_SCREEN_UNLOCKED; next_screen_at = 11500;
  handle_fingerprint_match(match);
  assert(!pin_entries && !grants && cancels == 1);
  // A helper silent before the touch (asleep, or logged out) may be gone.
  reset(); report(HOST_SCREEN_UNLOCKED, 7000);
  handle_fingerprint_match(match);
  assert(pin_entries == 1 && insertions == 1 && now == 13750);
  // A Mac that wakes unlocked reports so before the PIN is typed.
  reset(); report(HOST_SCREEN_UNLOCKED, 9000);
  next_screen = HOST_SCREEN_UNLOCKED; next_screen_at = 11800;
  handle_fingerprint_match(match);
  assert(!pin_entries && !grants && cancels == 1 && now == 11800);
  // Disabling automatic entry still grants presence without asking the helper.
  reset(); options.piv_auto_type = false; report(HOST_SCREEN_PASSWORD, 1000);
  handle_fingerprint_match(match);
  assert(grants == 1 && !pin_entries && !cancels && now == 10750);
  return 0;
}
