#pragma once

#include <stdbool.h>
#include <stdint.h>

bool host_pairing_open(const uint8_t peer[65], uint8_t public_key[65]);
bool host_pairing_finish(const uint8_t packet[68], uint8_t id[8], uint8_t key[32]);
unsigned host_pairing_epoch(void);
void host_pairing_usb_reset(void);
