// ps5ctl - developer tool for Shimmer's PS5 Remote Play work, on chiaki-ng's libchiaki.
//
//   ps5ctl status   <ip>                     discovery probe (power state, running app)
//   ps5ctl wake     <ip>                     wake a registered PS5 from rest mode
//   ps5ctl devices                           list consoles on the PSN account
//   ps5ctl register [--duid HEX]             PIN-less registration over PSN, saved to the keychain
//   ps5ctl register-pin <ip> <PIN>           LAN registration with the Link Device PIN
//   ps5ctl stream   <ip> [options]           LAN session with the saved registration
//        --seconds N        stop after N seconds (default 10)
//        --out FILE         write the raw Annex-B video stream to FILE
//        --press NAME@SEC   tap a button at SEC (repeatable): ps cross circle square triangle
//                           up down left right options share l1 r1 touchpad
//        --codec h264|h265  (default h265)    --res 720|1080 (default 1080)    --fps 30|60
//
// Secrets never touch stdout: the PSN token and the registration live in the login keychain.
//   PSN access token                 service "PSN access token", account psn
//   PSN account ID                   service "PlayStation Network account ID", account psn
//   registration                     service "PS5 Remote Play registration", account <console MAC hex>

#include <chiaki/base64.h>
#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/regist.h>
#include <chiaki/remote/holepunch.h>
#include <chiaki/session.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PSN_USER "psn"
#define REGIST_SERVICE "PS5 Remote Play registration"

static ChiakiLog g_log;
static bool g_verbose = false;

static void log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if(!g_verbose && level == CHIAKI_LOG_VERBOSE)
		return;
	const char *tag = level == CHIAKI_LOG_ERROR ? "E" : level == CHIAKI_LOG_WARNING ? "W" : level == CHIAKI_LOG_INFO ? "I" : "D";
	fprintf(stderr, "[%s] %s\n", tag, msg);
}

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

// ---------------------------------------------------------------------------
// keychain via security(1)

static char *keychain_get(const char *service, const char *account)
{
	char cmd[512];
	snprintf(cmd, sizeof(cmd), "security find-generic-password -s '%s' -a '%s' -w 2>/dev/null", service, account);
	FILE *p = popen(cmd, "r");
	if(!p)
		return NULL;
	static char buf[8192];
	size_t n = fread(buf, 1, sizeof(buf) - 1, p);
	int rc = pclose(p);
	if(rc != 0 || n == 0)
		return NULL;
	buf[n] = 0;
	while(n && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
		buf[--n] = 0;
	return strdup(buf);
}

static bool keychain_set(const char *service, const char *account, const char *value)
{
	// -X takes the value hex-encoded. (The piped `-w` prompt silently truncates
	// at 128 characters, which cut registrations short.)
	size_t n = strlen(value);
	char *hex = malloc(2 * n + 1);
	if(!hex)
		return false;
	for(size_t i = 0; i < n; i++)
		sprintf(hex + 2 * i, "%02x", (unsigned char)value[i]);
	hex[2 * n] = 0;
	char *cmd = malloc(2 * n + 512);
	if(!cmd) { free(hex); return false; }
	snprintf(cmd, 2 * n + 512, "security add-generic-password -U -s '%s' -a '%s' -l '%s' -X %s >/dev/null", service, account, service, hex);
	int rc = system(cmd);
	free(cmd);
	free(hex);
	return rc == 0;
}

// first registration in the keychain when no account is given
static char *keychain_find_any_regist(char *account_out, size_t account_size)
{
	FILE *p = popen("security find-generic-password -s '" REGIST_SERVICE "' 2>/dev/null | sed -n 's/.*\"acct\"<blob>=\"\\(.*\\)\"/\\1/p'", "r");
	if(!p)
		return NULL;
	char acct[128] = {0};
	if(!fgets(acct, sizeof(acct), p)) { pclose(p); return NULL; }
	pclose(p);
	acct[strcspn(acct, "\r\n")] = 0;
	if(!acct[0])
		return NULL;
	snprintf(account_out, account_size, "%s", acct);
	return keychain_get(REGIST_SERVICE, acct);
}

// ---------------------------------------------------------------------------
// hex helpers + registration (de)serialisation: "k=v;k=v;..."

static void to_hex(const uint8_t *b, size_t n, char *out)
{
	for(size_t i = 0; i < n; i++)
		sprintf(out + 2 * i, "%02x", b[i]);
	out[2 * n] = 0;
}

static bool from_hex(const char *s, uint8_t *out, size_t n)
{
	if(strlen(s) < 2 * n)
		return false;
	for(size_t i = 0; i < n; i++)
	{
		unsigned v;
		if(sscanf(s + 2 * i, "%2x", &v) != 1)
			return false;
		out[i] = (uint8_t)v;
	}
	return true;
}

static void regist_serialize(const ChiakiRegisteredHost *h, char *out, size_t size, char *mac_hex)
{
	char regist_key[2 * CHIAKI_SESSION_AUTH_SIZE + 1], rp_key[33];
	to_hex((const uint8_t *)h->rp_regist_key, CHIAKI_SESSION_AUTH_SIZE, regist_key);
	to_hex(h->rp_key, 16, rp_key);
	to_hex(h->server_mac, 6, mac_hex);
	snprintf(out, size, "target=%d;regist_key=%s;rp_key=%s;rp_key_type=%u;mac=%s;nickname=%s",
		(int)h->target, regist_key, rp_key, h->rp_key_type, mac_hex, h->server_nickname);
}

typedef struct
{
	int target;
	uint8_t regist_key[CHIAKI_SESSION_AUTH_SIZE];
	uint8_t rp_key[16];
	char nickname[64];
} Registration;

static bool regist_parse(const char *s, Registration *r)
{
	memset(r, 0, sizeof(*r));
	char *copy = strdup(s), *save = NULL;
	bool ok_key = false, ok_rp = false;
	for(char *kv = strtok_r(copy, ";", &save); kv; kv = strtok_r(NULL, ";", &save))
	{
		char *eq = strchr(kv, '=');
		if(!eq)
			continue;
		*eq = 0;
		const char *k = kv, *v = eq + 1;
		if(!strcmp(k, "target")) r->target = atoi(v);
		else if(!strcmp(k, "regist_key")) ok_key = from_hex(v, r->regist_key, CHIAKI_SESSION_AUTH_SIZE);
		else if(!strcmp(k, "rp_key")) ok_rp = from_hex(v, r->rp_key, 16);
		else if(!strcmp(k, "nickname")) snprintf(r->nickname, sizeof(r->nickname), "%s", v);
	}
	free(copy);
	return ok_key && ok_rp;
}

static bool load_account_id(uint8_t out[CHIAKI_PSN_ACCOUNT_ID_SIZE])
{
	char *b64 = keychain_get("PlayStation Network account ID", PSN_USER);
	if(!b64)
		return false;
	size_t n = CHIAKI_PSN_ACCOUNT_ID_SIZE;
	ChiakiErrorCode err = chiaki_base64_decode(b64, strlen(b64), out, &n);
	free(b64);
	return err == CHIAKI_ERR_SUCCESS && n == CHIAKI_PSN_ACCOUNT_ID_SIZE;
}

// ---------------------------------------------------------------------------
// status / wake

typedef struct { pthread_mutex_t m; pthread_cond_t c; bool done; ChiakiDiscoveryHost host; char buf[4][128]; } ProbeReply;

static void probe_cb(ChiakiDiscoveryHost *host, void *user)
{
	ProbeReply *r = user;
	pthread_mutex_lock(&r->m);
	if(!r->done)
	{
		r->host = *host;
		const char *src[4] = { host->host_name, host->host_id, host->running_app_name, host->running_app_titleid };
		for(int i = 0; i < 4; i++)
			snprintf(r->buf[i], sizeof(r->buf[i]), "%s", src[i] ? src[i] : "");
		r->done = true;
		pthread_cond_signal(&r->c);
	}
	pthread_mutex_unlock(&r->m);
}

static int cmd_status(const char *ip)
{
	ChiakiDiscovery discovery;
	if(chiaki_discovery_init(&discovery, &g_log, AF_INET) != CHIAKI_ERR_SUCCESS)
		return 1;
	ProbeReply reply = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, false };
	ChiakiDiscoveryThread thread;
	chiaki_discovery_thread_start_oneshot(&thread, &discovery, probe_cb, &reply);

	struct sockaddr_in addr = { .sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5) };
	inet_pton(AF_INET, ip, &addr.sin_addr);
	ChiakiDiscoveryPacket packet = { .cmd = CHIAKI_DISCOVERY_CMD_SRCH, .protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5 };
	bool got = false;
	for(int attempt = 0; attempt < 4 && !got; attempt++)
	{
		chiaki_discovery_send(&discovery, &packet, (struct sockaddr *)&addr, sizeof(addr));
		pthread_mutex_lock(&reply.m);
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_nsec += 700 * 1000000;
		until.tv_sec += until.tv_nsec / 1000000000;
		until.tv_nsec %= 1000000000;
		while(!reply.done && pthread_cond_timedwait(&reply.c, &reply.m, &until) == 0);
		got = reply.done;
		pthread_mutex_unlock(&reply.m);
	}
	chiaki_discovery_thread_stop(&thread);
	chiaki_discovery_fini(&discovery);
	if(!got)
	{
		printf("no reply from %s\n", ip);
		return 2;
	}
	printf("state=%s name=%s id=%s app=%s titleid=%s\n",
		reply.host.state == CHIAKI_DISCOVERY_HOST_STATE_READY ? "ready" :
		reply.host.state == CHIAKI_DISCOVERY_HOST_STATE_STANDBY ? "standby" : "unknown",
		reply.buf[0], reply.buf[1], reply.buf[2], reply.buf[3]);
	return 0;
}

static int cmd_wake(const char *ip)
{
	char acct[64];
	char *s = keychain_find_any_regist(acct, sizeof(acct));
	Registration r;
	if(!s || !regist_parse(s, &r)) { fprintf(stderr, "no registration in the keychain\n"); return 1; }
	free(s);
	// the wake credential is the regist key read as a hex string
	char key[CHIAKI_SESSION_AUTH_SIZE + 1] = {0};
	memcpy(key, r.regist_key, CHIAKI_SESSION_AUTH_SIZE);
	uint64_t credential = strtoull(key, NULL, 16);
	ChiakiErrorCode err = chiaki_discovery_wakeup(&g_log, NULL, ip, credential, true);
	printf("wake: %s\n", chiaki_error_string(err));
	return err == CHIAKI_ERR_SUCCESS ? 0 : 1;
}

// ---------------------------------------------------------------------------
// PSN: devices + register

static char *psn_token(void)
{
	// refresh first so a stale token never wastes a hole-punch attempt
	const char *refresher = getenv("PSN_TOKEN_REFRESH");
	if(refresher && *refresher)
		system(refresher);
	char *t = keychain_get("PSN access token", PSN_USER);
	if(!t)
		fprintf(stderr, "no PSN access token in the keychain\n");
	return t;
}

static int cmd_devices(void)
{
	char *token = psn_token();
	if(!token)
		return 1;
	ChiakiHolepunchDeviceInfo *devices = NULL;
	size_t count = 0;
	ChiakiErrorCode err = chiaki_holepunch_list_devices(token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &count, &g_log);
	free(token);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "list devices: %s\n", chiaki_error_string(err)); return 1; }
	for(size_t i = 0; i < count; i++)
	{
		char duid[65];
		to_hex(devices[i].device_uid, 32, duid);
		printf("%s duid=%s remoteplay=%s\n", devices[i].device_name, duid, devices[i].remoteplay_enabled ? "on" : "off");
	}
	chiaki_holepunch_free_device_list(&devices);
	return 0;
}

typedef struct
{
	pthread_mutex_t m;
	pthread_cond_t c;
	bool quit;
	bool connected;
	bool registered;
	ChiakiRegisteredHost host;
	char quit_reason[256];
	// stream stats
	atomic_long frames, bytes, lost;
	FILE *out;
} SessionState;

static void event_cb(ChiakiEvent *event, void *user)
{
	SessionState *st = user;
	pthread_mutex_lock(&st->m);
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			st->connected = true;
			fprintf(stderr, "** connected\n");
			break;
		case CHIAKI_EVENT_REGIST:
			st->registered = true;
			st->host = event->host;
			fprintf(stderr, "** registered %s\n", event->host.server_nickname);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			fprintf(stderr, "** console asks for its login PIN - not supported here\n");
			break;
		case CHIAKI_EVENT_RUMBLE:
			if(g_verbose)
				fprintf(stderr, "** rumble %u/%u\n", event->rumble.left, event->rumble.right);
			break;
		case CHIAKI_EVENT_QUIT:
			snprintf(st->quit_reason, sizeof(st->quit_reason), "%s%s%s",
				chiaki_quit_reason_string(event->quit.reason),
				event->quit.reason_str ? ": " : "", event->quit.reason_str ? event->quit.reason_str : "");
			st->quit = true;
			fprintf(stderr, "** quit: %s\n", st->quit_reason);
			break;
		default:
			break;
	}
	pthread_cond_broadcast(&st->c);
	pthread_mutex_unlock(&st->m);
}

static int cmd_register(const char *duid_hex)
{
	uint8_t account_id[CHIAKI_PSN_ACCOUNT_ID_SIZE];
	if(!load_account_id(account_id)) { fprintf(stderr, "no PSN account ID in the keychain\n"); return 1; }
	char *token = psn_token();
	if(!token)
		return 1;

	uint8_t duid[32];
	if(duid_hex)
	{
		if(!from_hex(duid_hex, duid, 32)) { fprintf(stderr, "bad --duid\n"); return 1; }
	}
	else
	{
		ChiakiHolepunchDeviceInfo *devices = NULL;
		size_t count = 0;
		if(chiaki_holepunch_list_devices(token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &count, &g_log) != CHIAKI_ERR_SUCCESS || !count)
		{
			fprintf(stderr, "no PS5 on this PSN account\n");
			return 1;
		}
		size_t pick = 0;
		for(size_t i = 0; i < count; i++)
			if(devices[i].remoteplay_enabled) { pick = i; break; }
		memcpy(duid, devices[pick].device_uid, 32);
		fprintf(stderr, "registering %s\n", devices[pick].device_name);
		chiaki_holepunch_free_device_list(&devices);
	}

	ChiakiHolepunchSession hp = chiaki_holepunch_session_init(token, &g_log);
	free(token);
	if(!hp) { fprintf(stderr, "holepunch init failed\n"); return 1; }
	ChiakiErrorCode err;
#define STEP(call, what) do { err = (call); if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "%s: %s\n", what, chiaki_error_string(err)); chiaki_holepunch_session_fini(hp); return 1; } fprintf(stderr, ">> %s\n", what); } while(0)
	STEP(chiaki_holepunch_upnp_discover(hp), "upnp discover");
	STEP(chiaki_holepunch_session_create(hp), "create session");
	STEP(holepunch_session_create_offer(hp), "create offer");
	STEP(chiaki_holepunch_session_start(hp, duid, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5), "start session");
	STEP(chiaki_holepunch_session_punch_hole(hp, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL), "punch ctrl hole");
#undef STEP

	SessionState st = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	info.host = NULL;
	info.auto_regist = true;
	info.holepunch_session = hp;
	memcpy(info.psn_account_id, account_id, sizeof(account_id));
	chiaki_connect_video_profile_preset(&info.video_profile, CHIAKI_VIDEO_RESOLUTION_PRESET_720p, CHIAKI_VIDEO_FPS_PRESET_60);
	info.packet_loss_max = 0.05;

	ChiakiSession session;
	err = chiaki_session_init(&session, &info, &g_log);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "session init: %s\n", chiaki_error_string(err)); chiaki_holepunch_session_fini(hp); return 1; }
	chiaki_session_set_event_cb(&session, event_cb, &st);
	err = chiaki_session_start(&session);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "session start: %s\n", chiaki_error_string(err)); chiaki_session_fini(&session); return 1; }

	pthread_mutex_lock(&st.m);
	double deadline = now_s() + 60;
	while(!st.quit && !st.registered && now_s() < deadline)
	{
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_sec += 1;
		pthread_cond_timedwait(&st.c, &st.m, &until);
	}
	bool registered = st.registered;
	ChiakiRegisteredHost host = st.host;
	pthread_mutex_unlock(&st.m);

	chiaki_session_stop(&session);
	chiaki_session_join(&session);
	chiaki_session_fini(&session); // also finis the holepunch session

	if(!registered) { fprintf(stderr, "registration did not finish%s%s\n", st.quit_reason[0] ? ": " : "", st.quit_reason); return 1; }
	char value[1024], mac[13];
	regist_serialize(&host, value, sizeof(value), mac);
	if(!keychain_set(REGIST_SERVICE, mac, value)) { fprintf(stderr, "could not save the registration to the keychain\n"); return 1; }
	printf("registered %s (mac %s, target %d) - saved to keychain \"%s\"\n", host.server_nickname, mac, (int)host.target, REGIST_SERVICE);
	return 0;
}

// LAN registration with the 8-digit PIN from Settings → System → Remote Play → Link Device.
typedef struct { pthread_mutex_t m; pthread_cond_t c; bool done; bool ok; ChiakiRegisteredHost host; } RegistReply;

static void regist_pin_cb(ChiakiRegistEvent *event, void *user)
{
	RegistReply *r = user;
	pthread_mutex_lock(&r->m);
	r->ok = event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host;
	if(r->ok)
		r->host = *event->registered_host;
	r->done = true;
	pthread_cond_signal(&r->c);
	pthread_mutex_unlock(&r->m);
}

static int cmd_register_pin(const char *ip, const char *pin_str)
{
	uint8_t account_id[CHIAKI_PSN_ACCOUNT_ID_SIZE];
	if(!load_account_id(account_id)) { fprintf(stderr, "no PSN account ID in the keychain\n"); return 1; }
	if(strlen(pin_str) != 8) { fprintf(stderr, "the PIN has 8 digits\n"); return 1; }
	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = CHIAKI_TARGET_PS5_1;
	info.host = ip;
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, account_id, sizeof(account_id));
	info.pin = (uint32_t)strtoul(pin_str, NULL, 10);
	RegistReply reply = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
	ChiakiRegist regist;
	ChiakiErrorCode err = chiaki_regist_start(&regist, &g_log, &info, regist_pin_cb, &reply);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "regist start: %s\n", chiaki_error_string(err)); return 1; }
	pthread_mutex_lock(&reply.m);
	double deadline = now_s() + 20;
	while(!reply.done && now_s() < deadline)
	{
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_sec += 1;
		pthread_cond_timedwait(&reply.c, &reply.m, &until);
	}
	pthread_mutex_unlock(&reply.m);
	if(!reply.done)
		chiaki_regist_stop(&regist);
	chiaki_regist_fini(&regist);
	if(!reply.ok) { fprintf(stderr, "registration failed (wrong or expired PIN?)\n"); return 1; }
	char value[1024], mac[13];
	regist_serialize(&reply.host, value, sizeof(value), mac);
	if(!keychain_set(REGIST_SERVICE, mac, value)) { fprintf(stderr, "could not save the registration to the keychain\n"); return 1; }
	printf("registered %s (mac %s) - saved to keychain \"%s\"\n", reply.host.server_nickname, mac, REGIST_SERVICE);
	return 0;
}

// ---------------------------------------------------------------------------
// stream

typedef struct { const char *name; uint32_t mask; } ButtonName;
static const ButtonName kButtons[] = {
	{ "cross", CHIAKI_CONTROLLER_BUTTON_CROSS }, { "circle", CHIAKI_CONTROLLER_BUTTON_MOON },
	{ "square", CHIAKI_CONTROLLER_BUTTON_BOX }, { "triangle", CHIAKI_CONTROLLER_BUTTON_PYRAMID },
	{ "left", CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT }, { "right", CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT },
	{ "up", CHIAKI_CONTROLLER_BUTTON_DPAD_UP }, { "down", CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN },
	{ "l1", CHIAKI_CONTROLLER_BUTTON_L1 }, { "r1", CHIAKI_CONTROLLER_BUTTON_R1 },
	{ "options", CHIAKI_CONTROLLER_BUTTON_OPTIONS }, { "share", CHIAKI_CONTROLLER_BUTTON_SHARE },
	{ "touchpad", CHIAKI_CONTROLLER_BUTTON_TOUCHPAD }, { "ps", CHIAKI_CONTROLLER_BUTTON_PS },
};

typedef struct { uint32_t mask; double at; } Press;

static bool video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frame_recovered;
	SessionState *st = user;
	atomic_fetch_add(&st->frames, 1);
	atomic_fetch_add(&st->bytes, (long)buf_size);
	atomic_fetch_add(&st->lost, frames_lost);
	if(st->out)
		fwrite(buf, 1, buf_size, st->out);
	return true;
}

static int cmd_stream(int argc, char **argv)
{
	if(argc < 1) { fprintf(stderr, "stream <ip> [options]\n"); return 1; }
	const char *ip = argv[0];
	double seconds = 10;
	const char *out_path = NULL;
	ChiakiCodec codec = CHIAKI_CODEC_H265;
	ChiakiVideoResolutionPreset res = CHIAKI_VIDEO_RESOLUTION_PRESET_1080p;
	ChiakiVideoFPSPreset fps = CHIAKI_VIDEO_FPS_PRESET_60;
	Press presses[32];
	int npress = 0;
	for(int i = 1; i < argc; i++)
	{
		if(!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
		else if(!strcmp(argv[i], "--out") && i + 1 < argc) out_path = argv[++i];
		else if(!strcmp(argv[i], "--codec") && i + 1 < argc) { i++; codec = !strcmp(argv[i], "h264") ? CHIAKI_CODEC_H264 : CHIAKI_CODEC_H265; }
		else if(!strcmp(argv[i], "--res") && i + 1 < argc) { i++; res = atoi(argv[i]) == 720 ? CHIAKI_VIDEO_RESOLUTION_PRESET_720p : CHIAKI_VIDEO_RESOLUTION_PRESET_1080p; }
		else if(!strcmp(argv[i], "--fps") && i + 1 < argc) { i++; fps = atoi(argv[i]) == 30 ? CHIAKI_VIDEO_FPS_PRESET_30 : CHIAKI_VIDEO_FPS_PRESET_60; }
		else if(!strcmp(argv[i], "--press") && i + 1 < argc && npress < 32)
		{
			char spec[64];
			snprintf(spec, sizeof(spec), "%s", argv[++i]);
			char *at = strchr(spec, '@');
			if(!at) { fprintf(stderr, "--press NAME@SEC\n"); return 1; }
			*at = 0;
			uint32_t mask = 0;
			for(size_t b = 0; b < sizeof(kButtons) / sizeof(kButtons[0]); b++)
				if(!strcmp(kButtons[b].name, spec)) mask = kButtons[b].mask;
			if(!mask) { fprintf(stderr, "unknown button %s\n", spec); return 1; }
			presses[npress++] = (Press){ mask, atof(at + 1) };
		}
		else { fprintf(stderr, "unknown option %s\n", argv[i]); return 1; }
	}

	char acct[64];
	char *s = keychain_find_any_regist(acct, sizeof(acct));
	Registration r;
	if(!s || !regist_parse(s, &r)) { fprintf(stderr, "no registration in the keychain - run `ps5ctl register` first\n"); return 1; }
	free(s);

	SessionState st = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
	if(out_path && !(st.out = fopen(out_path, "wb"))) { perror(out_path); return 1; }

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	info.host = ip;
	memcpy(info.regist_key, r.regist_key, sizeof(info.regist_key));
	memcpy(info.morning, r.rp_key, sizeof(info.morning));
	chiaki_connect_video_profile_preset(&info.video_profile, res, fps);
	info.video_profile.codec = codec;
	info.video_profile_auto_downgrade = true;
	info.enable_idr_on_fec_failure = true;
	info.packet_loss_max = 0.05;

	ChiakiSession session;
	ChiakiErrorCode err = chiaki_session_init(&session, &info, &g_log);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "session init: %s\n", chiaki_error_string(err)); return 1; }
	chiaki_session_set_event_cb(&session, event_cb, &st);
	chiaki_session_set_video_sample_cb(&session, video_cb, &st);
	err = chiaki_session_start(&session);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "session start: %s\n", chiaki_error_string(err)); chiaki_session_fini(&session); return 1; }

	// wait for CONNECTED (or quit), then run the clock from there
	double connect_deadline = now_s() + 20;
	pthread_mutex_lock(&st.m);
	while(!st.connected && !st.quit && now_s() < connect_deadline)
	{
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_sec += 1;
		pthread_cond_timedwait(&st.c, &st.m, &until);
	}
	bool connected = st.connected;
	pthread_mutex_unlock(&st.m);

	if(connected)
	{
		double t0 = now_s(), last = t0;
		long last_frames = 0;
		ChiakiControllerState idle;
		chiaki_controller_state_set_idle(&idle);
		uint32_t held = 0;
		double release_at = 0;
		while(now_s() - t0 < seconds && !st.quit)
		{
			double t = now_s() - t0;
			for(int i = 0; i < npress; i++)
				if(presses[i].at >= 0 && t >= presses[i].at)
				{
					ChiakiControllerState cs = idle;
					cs.buttons = presses[i].mask;
					chiaki_session_set_controller_state(&session, &cs);
					fprintf(stderr, "** press %#x at %.2fs\n", presses[i].mask, t);
					held = presses[i].mask;
					release_at = t + 0.15;
					presses[i].at = -1;
				}
			if(held && t >= release_at)
			{
				chiaki_session_set_controller_state(&session, &idle);
				held = 0;
			}
			if(now_s() - last >= 1.0)
			{
				long f = atomic_load(&st.frames);
				fprintf(stderr, "t=%4.1fs fps=%ld total=%ld lost=%ld MB=%.1f rtt=%.1fms\n", t, f - last_frames, f,
					atomic_load(&st.lost), atomic_load(&st.bytes) / 1e6, session.rtt_us / 1000.0);
				last_frames = f;
				last = now_s();
			}
			usleep(10000);
		}
	}

	chiaki_session_stop(&session);
	chiaki_session_join(&session);
	chiaki_session_fini(&session);
	if(st.out)
		fclose(st.out);
	printf("%s frames=%ld lost=%ld bytes=%ld%s%s\n", connected ? "streamed" : "did not connect",
		atomic_load(&st.frames), atomic_load(&st.lost), atomic_load(&st.bytes),
		st.quit_reason[0] ? " quit=" : "", st.quit_reason);
	return connected && atomic_load(&st.frames) > 0 ? 0 : 1;
}

int main(int argc, char **argv)
{
	if(getenv("PS5CTL_VERBOSE"))
		g_verbose = true;
	chiaki_log_init(&g_log, CHIAKI_LOG_ALL, log_cb, NULL);
	if(chiaki_lib_init() != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "chiaki_lib_init failed\n"); return 1; }
	if(argc < 2)
	{
		fprintf(stderr, "usage: ps5ctl status|wake <ip> | devices | register [--duid HEX] | stream <ip> [...]\n");
		return 1;
	}
	const char *cmd = argv[1];
	if(!strcmp(cmd, "status") && argc > 2) return cmd_status(argv[2]);
	if(!strcmp(cmd, "wake") && argc > 2) return cmd_wake(argv[2]);
	if(!strcmp(cmd, "devices")) return cmd_devices();
	if(!strcmp(cmd, "register-pin") && argc > 3) return cmd_register_pin(argv[2], argv[3]);
	if(!strcmp(cmd, "register")) return cmd_register(argc > 3 && !strcmp(argv[2], "--duid") ? argv[3] : NULL);
	if(!strcmp(cmd, "stream")) return cmd_stream(argc - 2, argv + 2);
	fprintf(stderr, "unknown command %s\n", cmd);
	return 1;
}
