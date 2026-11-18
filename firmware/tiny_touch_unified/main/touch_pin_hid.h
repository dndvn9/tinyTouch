#pragma once

#include <stdbool.h>

void touch_pin_hid_start(void);
bool touch_pin_hid_prove(const char *request, char result[65]);
bool touch_pin_hid_submit_response(const char *response);
void touch_pin_hid_usb_attached(void);
void touch_pin_hid_usb_detached(void);
void touch_pin_hid_send_logs(void);
void touch_pin_hid_log_event(const char *event, int value);

typedef enum { HOST_SCREEN_NONE, HOST_SCREEN_UNLOCKED, HOST_SCREEN_PASSWORD } host_screen_t;
// Accepts LOCKED, SECURE or UNLOCKED from the helper's SCREEN command.
bool touch_pin_hid_set_host_screen(const char *state);
