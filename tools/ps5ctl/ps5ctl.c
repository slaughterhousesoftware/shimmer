#include <execinfo.h>
#include <signal.h>
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
//        --rest             put the console into rest mode at the end
//        --dualsense        present a DualSense: count haptics frames, print trigger effects
//
// Secrets never touch stdout: the PSN token and the registration live in the login keychain.
//   PSN access token                 service "PSN access token", account $PS5CTL_PSN_ACCOUNT
//   PSN account ID                   service "PlayStation Network account ID", account $PS5CTL_PSN_ACCOUNT
//   registration                     service "PS5 Remote Play registration", account <console MAC hex>

#include <chiaki/audioreceiver.h>
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

// Shimmer's libchiaki research hook (third_party/chiaki-ng-patches/0002).
extern int chiaki_shimmer_reorder_timeout_us;  // patch 0001 (default 4000)
extern int chiaki_shimmer_takion_version;       // patch 0002 (default 20; PS5CTL_TAKION=12 = no negotiation)
ChiakiErrorCode chiaki_shimmer_ctrl_send(ChiakiSession *session, uint16_t type, const uint8_t *payload, size_t payload_size);

// Keychain account name the PSN items are stored under (any label you chose).
static const char *psn_user(void)
{
	const char *user = getenv("PS5CTL_PSN_ACCOUNT");
	if(!user || !*user)
	{
		fprintf(stderr, "set PS5CTL_PSN_ACCOUNT to the keychain account of your PSN items\n");
		exit(1);
	}
	return user;
}
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
// ($PS5CTL_REGIST_FILE, when set, names a file holding the registration string
// instead - for a Mac without the keychain item)
static char *keychain_find_any_regist(char *account_out, size_t account_size)
{
	const char *file = getenv("PS5CTL_REGIST_FILE");
	if(file && *file)
	{
		FILE *f = fopen(file, "r");
		if(!f) { perror(file); return NULL; }
		static char buf[4096];
		size_t n = fread(buf, 1, sizeof(buf) - 1, f);
		fclose(f);
		buf[n] = 0;
		buf[strcspn(buf, "\r\n")] = 0;
		snprintf(account_out, account_size, "file");
		return strdup(buf);
	}
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
	char *b64 = keychain_get("PlayStation Network account ID", psn_user());
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
	char *t = keychain_get("PSN access token", psn_user());
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
	// audio arrival timing
	atomic_long audio_frames, audio_gaps_over_30ms, audio_gaps_over_60ms, audio_max_gap_us;
	double audio_last;
	// DualSense feedback
	atomic_long haptic_frames, haptic_active_frames, trigger_events, rumble_events;
	FILE *haptics_out;  // drive --capture: [f64 t][u16 n][pcm] per haptics frame
	FILE *events_out;   // drive --capture: one line per console feedback event
	// drive mode: capture a decodable clip (from an IDR) for a snapshot
	pthread_mutex_t snap_m;
	FILE *snap_out;
	int snap_frames_left;
	bool snap_waiting_idr;
	bool hevc;
	uint8_t params[4096]; // VPS/SPS/PPS from the first keyframe, for snapshot clips
	size_t params_len;
} SessionState;

// Players 2-4's haptics frames (patch 0005): counted per pad, with signal.
static atomic_ulong g_pad_haptics[4], g_pad_haptics_signal[4];
static void haptics_pad_frame_cb(uint8_t pad, uint8_t *buf, size_t size, void *user)
{
	(void)user;
	if(pad > 3) return;
	atomic_fetch_add(&g_pad_haptics[pad], 1);
	int16_t *s = (int16_t *)buf;
	for(size_t i = 0; i < size / 2; i++)
		if(s[i] > 300 || s[i] < -300) { atomic_fetch_add(&g_pad_haptics_signal[pad], 1); break; }
	static unsigned long last;
	unsigned long n = atomic_load(&g_pad_haptics[pad]);
	if(n - last >= 100) { last = n; fprintf(stderr, "** pad %u haptics frames %lu (signal %lu)\n", pad, n, atomic_load(&g_pad_haptics_signal[pad])); }
}

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
		case CHIAKI_EVENT_HAPTIC_INTENSITY:
		case CHIAKI_EVENT_TRIGGER_INTENSITY:
			fprintf(stderr, "** %s intensity %d\n", event->type == CHIAKI_EVENT_HAPTIC_INTENSITY ? "haptic" : "trigger",
				(int)event->intensity);
			if(st->events_out)
			{
				fprintf(st->events_out, "%.6f %s_intensity %d\n", now_s(),
					event->type == CHIAKI_EVENT_HAPTIC_INTENSITY ? "haptic" : "trigger", (int)event->intensity);
				fflush(st->events_out);
			}
			break;
		case CHIAKI_EVENT_RUMBLE:
			atomic_fetch_add(&st->rumble_events, 1);
			if(st->events_out)
			{
				fprintf(st->events_out, "%.6f rumble %u %u\n", now_s(), event->rumble.left, event->rumble.right);
				fflush(st->events_out);
			}
			if(g_verbose)
				fprintf(stderr, "** rumble pad %u %u/%u\n", event->rumble.pad, event->rumble.left, event->rumble.right);
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			atomic_fetch_add(&st->trigger_events, 1);
			if(st->events_out)
			{
				fprintf(st->events_out, "%.6f trigger %u %u L", now_s(),
					event->trigger_effects.type_left, event->trigger_effects.type_right);
				for(int i = 0; i < 10; i++) fprintf(st->events_out, " %02x", event->trigger_effects.left[i]);
				fprintf(st->events_out, " R");
				for(int i = 0; i < 10; i++) fprintf(st->events_out, " %02x", event->trigger_effects.right[i]);
				fprintf(st->events_out, "\n");
				fflush(st->events_out);
			}
			fprintf(stderr, "** trigger effects pad %u target %#x L type %u R type %u\n", event->trigger_effects.pad,
				event->trigger_effects.target, event->trigger_effects.type_left, event->trigger_effects.type_right);
			break;
		case CHIAKI_EVENT_PAD_JOIN:
			fprintf(stderr, "** pad message %#x pad %u status %u\n", (unsigned)event->pad_join.message,
					(unsigned)event->pad_join.pad, (unsigned)event->pad_join.status);
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
	pthread_mutex_init(&st.snap_m, NULL);
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
	pthread_mutex_lock(&st->snap_m);
	// Walk the NALs: remember parameter sets, note whether this is a keyframe.
	bool keyframe = false;
	size_t param_end = 0;
	for(size_t i = 0; i + 3 < buf_size; i++)
	{
		if(!(buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1)) continue;
		uint8_t h = buf[i + 3];
		int type = st->hevc ? (h >> 1) & 0x3f : h & 0x1f;
		bool param = st->hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
		bool idr = st->hevc ? (type >= 16 && type <= 21) : type == 5;
		if(idr) keyframe = true;
		if(param) param_end = 0; // keep scanning; we copy up to the first non-param NAL
		else if(!param_end) param_end = i > 0 && buf[i - 1] == 0 ? i - 1 : i;
	}
	bool first_is_param = false;
	if(buf_size > 4)
	{
		size_t j = buf[2] == 1 ? 3 : 4;
		int t = st->hevc ? (buf[j] >> 1) & 0x3f : buf[j] & 0x1f;
		first_is_param = st->hevc ? (t >= 32 && t <= 34) : (t == 7 || t == 8);
	}
	if(first_is_param && param_end == 0)
		param_end = buf_size; // a headers-only frame
	if(!first_is_param)
		param_end = 0;
	if(param_end > 0 && param_end <= sizeof(st->params) && st->params_len == 0)
	{
		memcpy(st->params, buf, param_end);
		st->params_len = param_end;
	}
	if(st->snap_out)
	{
		if(st->snap_waiting_idr && keyframe)
		{
			st->snap_waiting_idr = false;
			// a keyframe without its own headers needs the session's
			if(param_end == 0 && st->params_len)
				fwrite(st->params, 1, st->params_len, st->snap_out);
		}
		if(!st->snap_waiting_idr && st->snap_frames_left > 0)
		{
			fwrite(buf, 1, buf_size, st->snap_out);
			if(--st->snap_frames_left == 0)
			{
				fclose(st->snap_out);
				st->snap_out = NULL;
			}
		}
	}
	pthread_mutex_unlock(&st->snap_m);
	return true;
}

static void audio_header_cb(ChiakiAudioHeader *header, void *user)
{
	(void)user;
	fprintf(stderr, "** audio %u ch %u Hz, %u samples/frame\n", header->channels, header->rate, header->frame_size);
}

static void audio_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	(void)buf; (void)buf_size;
	SessionState *st = user;
	double t = now_s();
	if(st->audio_last > 0)
	{
		long gap_us = (long)((t - st->audio_last) * 1e6);
		if(gap_us > 30000) atomic_fetch_add(&st->audio_gaps_over_30ms, 1);
		if(gap_us > 60000) atomic_fetch_add(&st->audio_gaps_over_60ms, 1);
		if(gap_us > atomic_load(&st->audio_max_gap_us)) atomic_store(&st->audio_max_gap_us, gap_us);
	}
	st->audio_last = t;
	atomic_fetch_add(&st->audio_frames, 1);
}

static void haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	SessionState *st = user;
	atomic_fetch_add(&st->haptic_frames, 1);
	if(st->haptics_out)
	{
		double t = now_s();
		uint16_t n = (uint16_t)buf_size;
		fwrite(&t, sizeof(t), 1, st->haptics_out);
		fwrite(&n, sizeof(n), 1, st->haptics_out);
		fwrite(buf, 1, buf_size, st->haptics_out);
	}
	for(size_t i = 0; i + 1 < buf_size; i += 2)
	{
		int16_t v = (int16_t)(buf[i] | (buf[i + 1] << 8));
		if(v > 300 || v < -300) { atomic_fetch_add(&st->haptic_active_frames, 1); break; }
	}
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
	bool rest_after = false;
	bool dualsense = false;
	for(int i = 1; i < argc; i++)
	{
		if(!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
		else if(!strcmp(argv[i], "--out") && i + 1 < argc) out_path = argv[++i];
		else if(!strcmp(argv[i], "--rest")) rest_after = true;
		else if(!strcmp(argv[i], "--dualsense")) dualsense = true;
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
	pthread_mutex_init(&st.snap_m, NULL);
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
	info.enable_dualsense = dualsense;

	ChiakiSession session;
	ChiakiErrorCode err = chiaki_session_init(&session, &info, &g_log);
	if(err != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "session init: %s\n", chiaki_error_string(err)); return 1; }
	chiaki_session_set_event_cb(&session, event_cb, &st);
	if(dualsense)
	{
		ChiakiAudioSink haptics_sink = { .user = &st, .frame_cb = haptics_frame_cb };
		chiaki_session_set_haptics_sink(&session, &haptics_sink);
		session.haptics_pad_cb = haptics_pad_frame_cb;
	}
	chiaki_session_set_video_sample_cb(&session, video_cb, &st);
	ChiakiAudioSink audio_sink = { .user = &st, .header_cb = audio_header_cb, .frame_cb = audio_frame_cb };
	chiaki_session_set_audio_sink(&session, &audio_sink);
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
				fprintf(stderr, "t=%4.1fs fps=%ld total=%ld lost=%ld MB=%.1f rtt=%.1fms audio=%ld gaps>30ms=%ld >60ms=%ld max=%.0fms takion=%u jitter=%.2fms\n", t, f - last_frames, f,
					atomic_load(&st.lost), atomic_load(&st.bytes) / 1e6, session.rtt_us / 1000.0,
					atomic_load(&st.audio_frames), atomic_load(&st.audio_gaps_over_30ms), atomic_load(&st.audio_gaps_over_60ms),
					atomic_load(&st.audio_max_gap_us) / 1000.0,
					(unsigned)session.stream_connection.takion.version, session.stream_connection.takion.ext_rx_jitter_us / 1000.0);
				atomic_store(&st.audio_max_gap_us, 0);
				last_frames = f;
				last = now_s();
			}
			usleep(10000);
		}
	}

	if(connected && rest_after)
	{
		// put the console into rest mode; the ctrl thread sends it, so give it a moment
		ChiakiErrorCode bed = chiaki_session_goto_bed(&session);
		fprintf(stderr, "** rest mode requested: %s\n", chiaki_error_string(bed));
		usleep(800000);
	}
	chiaki_session_stop(&session);
	chiaki_session_join(&session);
	chiaki_session_fini(&session);
	if(st.out)
		fclose(st.out);
	if(dualsense)
		printf("haptic frames=%ld (with signal %ld) trigger events=%ld rumble events=%ld\n",
			atomic_load(&st.haptic_frames), atomic_load(&st.haptic_active_frames),
			atomic_load(&st.trigger_events), atomic_load(&st.rumble_events));
	printf("%s frames=%ld lost=%ld bytes=%ld%s%s\n", connected ? "streamed" : "did not connect",
		atomic_load(&st.frames), atomic_load(&st.lost), atomic_load(&st.bytes),
		st.quit_reason[0] ? " quit=" : "", st.quit_reason);
	return connected && atomic_load(&st.frames) > 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// drive: one long session, commands on stdin (or a FIFO given with --control).
//   press NAME [MS]        tap a button (default 150 ms): cross circle square triangle
//                          up down left right l1 r1 options share touchpad ps
//   hold NAME MS           same as press with an explicit duration
//   wait MS                sleep
//   snap PATH.png          save the current screen as a PNG (needs ffmpeg)
//   quit                   end the session
// Every command prints "ok ..." or "error ..." on stdout, so a caller can
// pipe a script in or drive it line by line through the FIFO.

static uint32_t button_mask(const char *name)
{
	for(size_t b = 0; b < sizeof(kButtons) / sizeof(kButtons[0]); b++)
		if(!strcmp(kButtons[b].name, name)) return kButtons[b].mask;
	return 0;
}

static int cmd_drive(int argc, char **argv)
{
	if(argc < 1) { fprintf(stderr, "drive <ip> [--dualsense] [--control FIFO]\n"); return 1; }
	const char *ip = argv[0];
	bool dualsense = false;
	const char *control = NULL;
	const char *capture = NULL;  // PREFIX: PREFIX.haptics (binary) + PREFIX.events (text)
	for(int i = 1; i < argc; i++)
	{
		if(!strcmp(argv[i], "--dualsense")) dualsense = true;
		else if(!strcmp(argv[i], "--control") && i + 1 < argc) control = argv[++i];
		else if(!strcmp(argv[i], "--capture") && i + 1 < argc) capture = argv[++i];
	}
	char acct[64];
	char *s = keychain_find_any_regist(acct, sizeof(acct));
	Registration r;
	if(!s || !regist_parse(s, &r)) { fprintf(stderr, "no registration in the keychain\n"); return 1; }
	free(s);

	SessionState st = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
	pthread_mutex_init(&st.snap_m, NULL);
	st.hevc = true;
	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	info.host = ip;
	memcpy(info.regist_key, r.regist_key, sizeof(info.regist_key));
	memcpy(info.morning, r.rp_key, sizeof(info.morning));
	chiaki_connect_video_profile_preset(&info.video_profile, CHIAKI_VIDEO_RESOLUTION_PRESET_1080p, CHIAKI_VIDEO_FPS_PRESET_60);
	info.video_profile.codec = CHIAKI_CODEC_H265;
	info.video_profile_auto_downgrade = true;
	info.enable_idr_on_fec_failure = true;
	info.packet_loss_max = 0.05;
	info.enable_dualsense = dualsense;

	ChiakiSession session;
	if(chiaki_session_init(&session, &info, &g_log) != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "session init failed\n"); return 1; }
	chiaki_session_set_event_cb(&session, event_cb, &st);
	chiaki_session_set_video_sample_cb(&session, video_cb, &st);
	ChiakiAudioSink capture_sink = { .user = &st, .frame_cb = haptics_frame_cb };
	// Count game audio frames too (the frames are decoded Opus; only the count matters here).
	ChiakiAudioSink drive_audio_sink = { .user = &st, .frame_cb = audio_frame_cb };
	chiaki_session_set_audio_sink(&session, &drive_audio_sink);
	if(capture)
	{
		char path[600];
		snprintf(path, sizeof(path), "%s.haptics", capture);
		st.haptics_out = fopen(path, "wb");
		snprintf(path, sizeof(path), "%s.events", capture);
		st.events_out = fopen(path, "w");
		chiaki_session_set_haptics_sink(&session, &capture_sink);
	}
	if(chiaki_session_start(&session) != CHIAKI_ERR_SUCCESS) { fprintf(stderr, "session start failed\n"); chiaki_session_fini(&session); return 1; }

	double deadline = now_s() + 20;
	pthread_mutex_lock(&st.m);
	while(!st.connected && !st.quit && now_s() < deadline)
	{
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_sec += 1;
		pthread_cond_timedwait(&st.c, &st.m, &until);
	}
	bool connected = st.connected;
	pthread_mutex_unlock(&st.m);
	if(!connected)
	{
		printf("error did not connect%s%s\n", st.quit_reason[0] ? ": " : "", st.quit_reason);
		chiaki_session_stop(&session); chiaki_session_join(&session); chiaki_session_fini(&session);
		return 1;
	}
	printf("ok connected\n");
	fflush(stdout);

	FILE *in = stdin;
	if(control)
	{
		in = fopen(control, "r+"); // r+ keeps the FIFO open between writers
		if(!in) { perror(control); in = stdin; }
	}
	ChiakiControllerState idle;
	chiaki_controller_state_set_idle(&idle);
	char line[512];
	while(!st.quit && fgets(line, sizeof(line), in))
	{
		line[strcspn(line, "\r\n")] = 0;
		char cmd[32] = {0}, arg[400] = {0};
		int ms = 150;
		int n = sscanf(line, "%31s %399s %d", cmd, arg, &ms);
		if(n < 1) continue;
		if(!strcmp(cmd, "quit")) { printf("ok quit\n"); fflush(stdout); break; }
		else if(!strcmp(cmd, "wait") && n >= 2) { usleep(atoi(arg) * 1000); printf("ok wait\n"); }
		else if((!strcmp(cmd, "press") || !strcmp(cmd, "hold")) && n >= 2)
		{
			uint32_t mask = button_mask(arg);
			if(!mask) { printf("error unknown button %s\n", arg); fflush(stdout); continue; }
			ChiakiControllerState cs = idle;
			cs.buttons = mask;
			chiaki_session_set_controller_state(&session, &cs);
			usleep((ms > 0 ? ms : 150) * 1000);
			chiaki_session_set_controller_state(&session, &idle);
			usleep(120000);
			printf("ok %s %s %d\n", cmd, arg, ms);
		}
		else if(!strcmp(cmd, "join") && n >= 2)
		{
			// join PAD ACCOUNT_ID(decimal): seat another console user on pad PAD (ctrl 0x68)
			unsigned pad = 0; unsigned long long account = 0;
			sscanf(line, "%*s %u %llu", &pad, &account);
			ChiakiErrorCode e = chiaki_session_join_user(&session, (uint8_t)pad, (uint64_t)account);
			printf("ok join pad %u err %d\n", pad, (int)e);
		}
		else if(!strcmp(cmd, "passcode") && n >= 2)
		{
			// passcode PAD 1234
			unsigned pad = 0; char code[8] = {0};
			sscanf(line, "%*s %u %7s", &pad, code);
			ChiakiErrorCode e = chiaki_session_answer_user_passcode(&session, (uint8_t)pad, code);
			printf("ok passcode pad %u err %d\n", pad, (int)e);
		}
		else if(!strcmp(cmd, "leave") && n >= 2)
		{
			ChiakiErrorCode e = chiaki_session_leave_pad(&session, (uint8_t)atoi(arg));
			printf("ok leave pad %d err %d\n", atoi(arg), (int)e);
		}
		else if(!strcmp(cmd, "padpress") && n >= 2)
		{
			// padpress PAD BUTTON [MS]: tap a button on another player's pad
			unsigned pad = 0; char name[32] = {0}; int hold = 150;
			sscanf(line, "%*s %u %31s %d", &pad, name, &hold);
			uint32_t mask = button_mask(name);
			if(!mask) { printf("error unknown button %s\n", name); fflush(stdout); continue; }
			ChiakiControllerState cs = idle;
			cs.buttons = mask;
			chiaki_session_set_controller_state_pad(&session, (uint8_t)pad, &cs);
			usleep((hold > 0 ? hold : 150) * 1000);
			chiaki_session_set_controller_state_pad(&session, (uint8_t)pad, &idle);
			usleep(120000);
			printf("ok padpress %u %s %d\n", pad, name, hold);
		}
		else if(!strcmp(cmd, "mic") && n >= 2)
		{
			// The console's view of a live chat mic: connect it, then unmute/mute.
			// (libchiaki's toggle argument: true = live.) No audio is sent.
			static bool mic_connected = false;
			if(!mic_connected) { chiaki_session_connect_microphone(&session); mic_connected = true; usleep(200000); }
			bool live = !strcmp(arg, "on");
			chiaki_session_toggle_microphone(&session, live);
			if(st.events_out) { fprintf(st.events_out, "%.6f mic %s\n", now_s(), live ? "on" : "off"); fflush(st.events_out); }
			printf("ok mic %s\n", live ? "on" : "off");
		}
		else if(!strcmp(cmd, "ctrl") && n >= 2)
		{
			// ctrl TYPEHEX PAYLOADHEX: send a raw ctrl message (research)
			char hex[400] = {0};
			sscanf(line, "%*s %*s %399s", hex);
			unsigned type = (unsigned)strtoul(arg, NULL, 16);
			uint8_t payload[200];
			size_t len = 0;
			for(; len < sizeof(payload) && hex[2 * len] && hex[2 * len + 1]; len++)
			{
				unsigned v; sscanf(hex + 2 * len, "%2x", &v); payload[len] = (uint8_t)v;
			}
			ChiakiErrorCode e = chiaki_shimmer_ctrl_send(&session, (uint16_t)type, payload, len);
			if(st.events_out) { fprintf(st.events_out, "%.6f ctrl %x %s\n", now_s(), type, hex); fflush(st.events_out); }
			printf("ok ctrl %x len %zu err %d\n", type, len, (int)e);
		}
		else if(!strcmp(cmd, "mark") && n >= 2)
		{
			if(st.events_out) { fprintf(st.events_out, "%.6f mark %s\n", now_s(), arg); fflush(st.events_out); }
			printf("ok mark %s\n", arg);
		}
		else if(!strcmp(cmd, "stick") && n >= 2)
		{
			// stick DIR MS: left stick fully up/down/left/right for MS
			ChiakiControllerState cs = idle;
			if(!strcmp(arg, "up")) cs.left_y = -32767;
			else if(!strcmp(arg, "down")) cs.left_y = 32767;
			else if(!strcmp(arg, "left")) cs.left_x = -32767;
			else if(!strcmp(arg, "right")) cs.left_x = 32767;
			chiaki_session_set_controller_state(&session, &cs);
			usleep((ms > 0 ? ms : 150) * 1000);
			chiaki_session_set_controller_state(&session, &idle);
			printf("ok stick %s %d\n", arg, ms);
		}
		else if(!strcmp(cmd, "r2") || !strcmp(cmd, "l2"))
		{
			// r2 VALUE MS: hold the trigger at VALUE (0-255) for MS
			ChiakiControllerState cs = idle;
			int v = atoi(arg);
			if(!strcmp(cmd, "r2")) { cs.r2_state = (uint8_t)v; if(v) cs.buttons |= CHIAKI_CONTROLLER_ANALOG_BUTTON_R2; }
			else { cs.l2_state = (uint8_t)v; if(v) cs.buttons |= CHIAKI_CONTROLLER_ANALOG_BUTTON_L2; }
			chiaki_session_set_controller_state(&session, &cs);
			usleep((ms > 0 ? ms : 150) * 1000);
			chiaki_session_set_controller_state(&session, &idle);
			printf("ok %s %d %d\n", cmd, v, ms);
		}
		else if(!strcmp(cmd, "snap") && n >= 2)
		{
			char clip[600];
			snprintf(clip, sizeof(clip), "%s.h265", arg);
			pthread_mutex_lock(&st.snap_m);
			st.snap_out = fopen(clip, "wb");
			st.snap_frames_left = 8;
			st.snap_waiting_idr = true;
			pthread_mutex_unlock(&st.snap_m);
			chiaki_session_request_idr(&session);
			bool done = false;
			for(int i = 0; i < 600 && !done; i++)
			{
				usleep(10000);
				if(i % 70 == 69) chiaki_session_request_idr(&session); // re-ask every 0.7 s
				pthread_mutex_lock(&st.snap_m);
				done = st.snap_out == NULL;
				pthread_mutex_unlock(&st.snap_m);
			}
			if(!done)
			{
				pthread_mutex_lock(&st.snap_m);
				if(st.snap_out) { fclose(st.snap_out); st.snap_out = NULL; }
				pthread_mutex_unlock(&st.snap_m);
				printf("error no keyframe within 6 s\n");
			}
			else
			{
				char ff[1400];
				snprintf(ff, sizeof(ff), "ffmpeg -v error -y -f hevc -i '%s' -update 1 -vf scale=1280:-1 '%s' && rm -f '%s'", clip, arg, clip);
				printf(system(ff) == 0 ? "ok snap %s\n" : "error ffmpeg failed for %s\n", arg);
			}
		}
		else printf("error unknown command: %s\n", line);
		fflush(stdout);
	}
	// Summary of the session, before teardown: what arrived, on which Takion version.
	fprintf(stderr, "** summary takion=%u jitter=%.2fms frames=%ld lost=%ld MB=%.1f audio=%ld audio_gaps>30ms=%ld haptic=%ld haptic_active=%ld triggers=%ld rumble=%ld\n",
		(unsigned)session.stream_connection.takion.version, session.stream_connection.takion.ext_rx_jitter_us / 1000.0,
		atomic_load(&st.frames), atomic_load(&st.lost), atomic_load(&st.bytes) / 1e6,
		atomic_load(&st.audio_frames), atomic_load(&st.audio_gaps_over_30ms),
		atomic_load(&st.haptic_frames), atomic_load(&st.haptic_active_frames),
		atomic_load(&st.trigger_events), atomic_load(&st.rumble_events));
	chiaki_session_stop(&session);
	chiaki_session_join(&session);
	chiaki_session_fini(&session);
	if(st.haptics_out) fclose(st.haptics_out);
	if(st.events_out) fclose(st.events_out);
	if(in != stdin) fclose(in);
	return 0;
}

// A crash prints its stack: lldb can't attach here and no report is written for a CLI tool.
static void crash_handler(int sig)
{
	void *frames[64];
	int n = backtrace(frames, 64);
	fprintf(stderr, "** crashed with signal %d\n", sig);
	backtrace_symbols_fd(frames, n, 2);
	signal(sig, SIG_DFL);
	raise(sig);
}

int main(int argc, char **argv)
{
	static uint8_t alt_stack[256 * 1024];
	stack_t ss = { .ss_sp = alt_stack, .ss_size = sizeof(alt_stack), .ss_flags = 0 };
	sigaltstack(&ss, NULL);
	struct sigaction sa = { 0 };
	sa.sa_handler = crash_handler;
	sa.sa_flags = SA_ONSTACK;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
	if(getenv("PS5CTL_VERBOSE"))
		g_verbose = true;
	if(getenv("PS5CTL_REORDER_US"))
		chiaki_shimmer_reorder_timeout_us = atoi(getenv("PS5CTL_REORDER_US"));
	if(getenv("PS5CTL_TAKION"))
		chiaki_shimmer_takion_version = atoi(getenv("PS5CTL_TAKION"));
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
	if(!strcmp(cmd, "drive")) return cmd_drive(argc - 2, argv + 2);
	fprintf(stderr, "unknown command %s\n", cmd);
	return 1;
}
