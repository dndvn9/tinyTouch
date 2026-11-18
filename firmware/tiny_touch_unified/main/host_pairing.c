#include "host_pairing.h"

#include <stdatomic.h>
#include <string.h>
#include "esp_random.h"
#include "esp_timer.h"
#include "mbedtls/ecdh.h"
#include "mbedtls/gcm.h"
#include "mbedtls/platform_util.h"
#include "mbedtls/sha256.h"

// All cryptographic state belongs to the console task. The USB callback
// invalidates its epoch without racing the ECDH or GCM contexts.
static atomic_uint usb_epoch;
static unsigned opened_epoch;
static int64_t deadline;
static uint8_t wrapping_key[32];
static const uint8_t label[] = "tinyTouch host pairing v1";

unsigned host_pairing_epoch(void) { return atomic_load(&usb_epoch); }

void host_pairing_usb_reset(void) { atomic_fetch_add(&usb_epoch, 1); }

static int random_bytes(void *unused, unsigned char *out, size_t size) {
  (void)unused;
  esp_fill_random(out, size);
  return 0;
}

bool host_pairing_open(const uint8_t peer[65], uint8_t public_key[65]) {
  deadline = 0;
  mbedtls_platform_zeroize(wrapping_key, sizeof(wrapping_key));
  opened_epoch = atomic_load(&usb_epoch);
  mbedtls_ecp_group group;
  mbedtls_ecp_point remote, local;
  mbedtls_mpi private_key, shared;
  mbedtls_ecp_group_init(&group);
  mbedtls_ecp_point_init(&remote);
  mbedtls_ecp_point_init(&local);
  mbedtls_mpi_init(&private_key);
  mbedtls_mpi_init(&shared);
  size_t written = 0;
  uint8_t transcript[sizeof(label)-1 + 65 + 65 + 32];
  memcpy(transcript, label, sizeof(label)-1);
  memcpy(transcript + sizeof(label)-1, peer, 65);
  bool ok = peer[0] == 4 &&
      mbedtls_ecp_group_load(&group, MBEDTLS_ECP_DP_SECP256R1) == 0 &&
      mbedtls_ecp_point_read_binary(&group, &remote, peer, 65) == 0 &&
      mbedtls_ecp_check_pubkey(&group, &remote) == 0 &&
      mbedtls_ecdh_gen_public(&group, &private_key, &local, random_bytes, NULL) == 0 &&
      mbedtls_ecp_point_write_binary(&group, &local, MBEDTLS_ECP_PF_UNCOMPRESSED,
                                     &written, public_key, 65) == 0 && written == 65 &&
      mbedtls_ecdh_compute_shared(&group, &shared, &remote, &private_key, random_bytes, NULL) == 0 &&
      mbedtls_mpi_write_binary(&shared, transcript + sizeof(transcript)-32, 32) == 0;
  if (ok) {
    memcpy(transcript + sizeof(label)-1 + 65, public_key, 65);
    ok = mbedtls_sha256(transcript, sizeof(transcript), wrapping_key, 0) == 0;
  }
  mbedtls_platform_zeroize(transcript, sizeof(transcript));
  mbedtls_mpi_free(&shared);
  mbedtls_mpi_free(&private_key);
  mbedtls_ecp_point_free(&local);
  mbedtls_ecp_point_free(&remote);
  mbedtls_ecp_group_free(&group);
  if (ok) deadline = esp_timer_get_time() + 30000000;
  return ok;
}

bool host_pairing_finish(const uint8_t packet[68], uint8_t id[8], uint8_t key[32]) {
  bool live = deadline > esp_timer_get_time() && opened_epoch == atomic_load(&usb_epoch);
  deadline = 0;
  memcpy(id, packet, 8);
  mbedtls_gcm_context gcm;
  mbedtls_gcm_init(&gcm);
  bool ok = live &&
      mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, wrapping_key, 256) == 0 &&
      mbedtls_gcm_auth_decrypt(&gcm, 32, packet+8, 12, id, 8,
                               packet+52, 16, packet+20, key) == 0;
  mbedtls_gcm_free(&gcm);
  mbedtls_platform_zeroize(wrapping_key, sizeof(wrapping_key));
  return ok;
}
