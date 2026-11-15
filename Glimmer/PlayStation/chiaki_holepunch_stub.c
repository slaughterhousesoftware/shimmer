// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// PSN hole-punching stand-in for Shimmer.app's libchiaki (scripts/build-libchiaki.sh lan).
// The app connects to a PS5 directly - on the LAN, or through a Tailscale subnet route -
// so it never builds a holepunch session; chiaki-ng's holepunch.c would pull curl
// WebSockets, json-c, libevent and miniupnpc into the app for a path it does not use.
// libchiaki references these symbols, so each one reports "unsupported".
// session->holepunch_session is always NULL in the app, so none of them run.
// Pattern from github.com/inficity/chiaki-ios (AGPL-3.0).

#include <netinet/in.h>
#include <string.h>

#include <chiaki/remote/holepunch.h>

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_list_devices(const char *psn_oauth2_token,
	ChiakiHolepunchConsoleType console_type, ChiakiHolepunchDeviceInfo **devices,
	size_t *device_count, ChiakiLog *log)
{
	*devices = NULL;
	*device_count = 0;
	return CHIAKI_ERR_INVALID_DATA;
}

CHIAKI_EXPORT void chiaki_holepunch_free_device_list(ChiakiHolepunchDeviceInfo **devices) {}

CHIAKI_EXPORT ChiakiHolepunchRegistInfo chiaki_get_regist_info(ChiakiHolepunchSession session)
{
	ChiakiHolepunchRegistInfo info;
	memset(&info, 0, sizeof(info));
	return info;
}

CHIAKI_EXPORT void chiaki_get_ps_selected_addr(ChiakiHolepunchSession session, char *ps_ip) {}
CHIAKI_EXPORT uint16_t chiaki_get_ps_ctrl_port(ChiakiHolepunchSession session) { return 0; }
CHIAKI_EXPORT chiaki_socket_t *chiaki_get_holepunch_sock(ChiakiHolepunchSession session, ChiakiHolepunchPortType type) { return NULL; }

CHIAKI_EXPORT bool chiaki_holepunch_session_get_stun_allocation(ChiakiHolepunchSession session,
	int32_t *allocation_increment, bool *random_allocation)
{
	return false;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_generate_client_device_uid(char *out, size_t *out_size)
{
	return CHIAKI_ERR_INVALID_DATA;
}

CHIAKI_EXPORT ChiakiHolepunchSession chiaki_holepunch_session_init(const char *psn_oauth2_token, ChiakiLog *log) { return NULL; }
CHIAKI_EXPORT void chiaki_holepunch_session_force_port_guessing(ChiakiHolepunchSession session, bool enabled) {}
CHIAKI_EXPORT void chiaki_holepunch_session_set_ws_fqdn_override(ChiakiHolepunchSession session, const char *fqdn) {}
CHIAKI_EXPORT void chiaki_holepunch_session_set_port_guessing_ports(ChiakiHolepunchSession session, int count) {}
CHIAKI_EXPORT void chiaki_holepunch_session_set_port_guessing_socks(ChiakiHolepunchSession session, int count) {}
CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_session_create(ChiakiHolepunchSession session) { return CHIAKI_ERR_INVALID_DATA; }

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_session_start(ChiakiHolepunchSession session,
	const uint8_t *console_uid, ChiakiHolepunchConsoleType console_type)
{
	return CHIAKI_ERR_INVALID_DATA;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_upnp_discover(ChiakiHolepunchSession session) { return CHIAKI_ERR_INVALID_DATA; }
CHIAKI_EXPORT ChiakiErrorCode holepunch_session_create_offer(ChiakiHolepunchSession session) { return CHIAKI_ERR_INVALID_DATA; }

CHIAKI_EXPORT ChiakiErrorCode chiaki_holepunch_session_punch_hole(ChiakiHolepunchSession session,
	ChiakiHolepunchPortType port_type)
{
	return CHIAKI_ERR_INVALID_DATA;
}

CHIAKI_EXPORT void chiaki_holepunch_main_thread_cancel(ChiakiHolepunchSession session, bool stop_thread) {}
CHIAKI_EXPORT void chiaki_holepunch_session_fini(ChiakiHolepunchSession session) {}
