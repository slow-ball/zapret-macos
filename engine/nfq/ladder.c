// The ladder (zapret-macos): see ladder.h

#include "ladder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "uthash.h"

typedef struct ladder_site {
	char *key;		/* key: ladder_key */
	int rung;
	UT_hash_handle hh;
} ladder_site;

static ladder_site *sites;
static char *state;
static int sizes[LADDER_GROUPS];

// the script edits the files too (the generator, the daily tune, the ladder's search), then restarts the
// engine: a file changed since the engine last read or wrote it is the script's, and the engine leaves it
// alone (it reads it on start). the time it was changed, 0 for a file that wasn't there
static void stamp(const char *file, struct timespec *t)
{
	struct stat st;
	if (stat(file, &st)) t->tv_sec = t->tv_nsec = 0;
#ifdef __APPLE__
	else *t = st.st_mtimespec;
#else
	else *t = st.st_mtim;
#endif
}

static bool untouched(const char *file, const struct timespec *t)
{
	struct timespec now;
	stamp(file, &now);
	return now.tv_sec == t->tv_sec && now.tv_nsec == t->tv_nsec;
}

static struct timespec state_t;

static const char *prefix[LADDER_GROUPS] = { "", "quic:", "voice" };

static void speeds_free(void);

bool ladder_parse(const char *s, int *group, int *rung)
{
	char *end;
	long r;
	*group = LADDER_TCP;
	if (!strncmp(s, "quic:", 5)) { *group = LADDER_QUIC; s += 5; }
	else if (!strncmp(s, "voice:", 6)) { *group = LADDER_VOICE; s += 6; }
	r = strtol(s, &end, 10);
	if (end == s || *end || r < 0 || r >= LADDER_MAX) return false;
	*rung = (int)r;
	return true;
}

// suffixes under which every name is a site of its own: country zones of the kind co.uk, and shared
// hosting where unrelated sites live side by side
static const char *shared[] = {
	"github.io", "githubusercontent.com", "cloudfront.net", "amazonaws.com", "appspot.com", "herokuapp.com",
	"pages.dev", "workers.dev", "vercel.app", "netlify.app", "blogspot.com", "azurewebsites.net",
	"firebaseapp.com", "web.app", "fastly.net", "akamaized.net", NULL
};

static bool is_shared(const char *suffix, size_t len)
{
	static const char *generic[] = { "co", "com", "net", "org", "gov", "edu", "ac", NULL };
	const char **s;
	const char *tld = memchr(suffix, '.', len);
	// a two-letter country after a generic label: co.uk, com.tr, net.ua, org.kz, gov.ru…
	if (tld && len - (size_t)(tld + 1 - suffix) == 2)
		for (s = generic; *s; s++)
			if (strlen(*s) == (size_t)(tld - suffix) && !strncmp(*s, suffix, tld - suffix)) return true;
	for (s = shared; *s; s++)
		if (strlen(*s) == len && !strncmp(*s, suffix, len)) return true;
	return false;
}

static void site_of(const char *host, char *out, size_t size)
{
	const char *p, *end, *dots[3] = { NULL, NULL, NULL };
	size_t len = strlen(host);
	end = host + len;
	// an address: digits and dots, or a colon of IPv6
	if (strchr(host, ':') || strspn(host, "0123456789.") == len)
		p = host;
	else
	{
		// the last three dots, the nearest first
		for (p = host; *p; p++)
			if (*p == '.') { dots[2] = dots[1]; dots[1] = dots[0]; dots[0] = p; }
		p = dots[1] ? dots[1] + 1 : host;
		// x.co.uk, site.github.io: one label more
		if (dots[1] && is_shared(p, (size_t)(end - p)))
			p = dots[2] ? dots[2] + 1 : host;
	}
	snprintf(out, size, "%s", p);
}

// a video server of YouTube, rr3---sn-4g5e6nsz.googlevideo.com: its group, sn-4g5e6nsz.googlevideo.com. some
// groups stand at the provider (a cache of Google) and are never slowed, others far away are: each learns its
// own trick. NULL for any other host
static const char *video_group(const char *host)
{
	const char *sn;
	size_t len;
	// Discord voice has no host
	if (!host) return NULL;
	sn = strstr(host, "---sn-");
	len = strlen(host);
	if (!sn || len < 16 || strcmp(host + len - 16, ".googlevideo.com")) return NULL;
	return sn + 3;
}

void ladder_key(int group, const char *host, char *out, size_t size)
{
	char site[256];
	const char *vg;
	if (!size) return;
	*out = '\0';
	if (group < 0 || group >= LADDER_GROUPS) return;
	if (group == LADDER_VOICE)
	{
		snprintf(out, size, "%s", prefix[group]);
		return;
	}
	if (!host) return;
	if ((vg = video_group(host)))
	{
		snprintf(out, size, "%s%s", prefix[group], vg);
		return;
	}
	site_of(host, site, sizeof(site));
	snprintf(out, size, "%s%s", prefix[group], site);
}

static int group_of(const char *key)
{
	if (!strncmp(key, "quic:", 5)) return LADDER_QUIC;
	if (!strcmp(key, "voice")) return LADDER_VOICE;
	return LADDER_TCP;
}

static ladder_site *find(const char *key)
{
	ladder_site *s;
	HASH_FIND_STR(sites, key, s);
	return s;
}

static ladder_site *put(const char *key, int rung)
{
	ladder_site *s = find(key);
	if (!s)
	{
		if (!(s = calloc(1, sizeof(*s))) || !(s->key = strdup(key)))
		{
			free(s);
			return NULL;
		}
		HASH_ADD_KEYPTR(hh, sites, s->key, strlen(s->key), s);
	}
	s->rung = rung;
	return s;
}

// the whole file anew: a line per site, "key rung". written in place: after the engine drops root
// it may write the file (chowned at start) but not the folder it is in
static void save(void)
{
	FILE *f;
	ladder_site *s, *tmp;
	if (!state || !untouched(state, &state_t) || !(f = fopen(state, "w"))) return;
	HASH_ITER(hh, sites, s, tmp)
		if (s->rung) fprintf(f, "%s %d\n", s->key, s->rung);
	fclose(f);
	stamp(state, &state_t);
}

bool ladder_init(const char *state_file, const int n[LADDER_GROUPS])
{
	FILE *f;
	char line[300], key[270];
	int rung, g, any = 0;

	ladder_destroy();
	for (g = 0; g < LADDER_GROUPS; g++)
	{
		if (n[g] < 0 || n[g] > LADDER_MAX) return false;
		sizes[g] = n[g];
		any |= n[g];
	}
	if (!any) return false;
	if (!state_file || !*state_file) return true;
	if (!(state = strdup(state_file))) return false;
	if ((f = fopen(state, "r")))
	{
		while (fgets(line, sizeof(line), f))
			// a rung the ladder no longer has (it got shorter) means the bottom again
			if (sscanf(line, "%269s %d", key, &rung) == 2 && rung > 0 && rung < sizes[group_of(key)])
				put(key, rung);
		fclose(f);
	}
	stamp(state, &state_t);
	return true;
}

int ladder_rung(int group, const char *host)
{
	ladder_site *s;
	char key[270];
	if (group < 0 || group >= LADDER_GROUPS || !sizes[group]) return 0;
	ladder_key(group, host, key, sizeof(key));
	if (!*key) return 0;
	if ((s = find(key))) return s->rung;
	// a group of video servers not met yet starts where the video of YouTube as a whole is
	if (video_group(host))
	{
		snprintf(key, sizeof(key), "%sgooglevideo.com", prefix[group]);
		if ((s = find(key))) return s->rung;
	}
	return 0;
}

int ladder_climb(int group, const char *host)
{
	int rung;
	char key[270];
	if (group < 0 || group >= LADDER_GROUPS || !sizes[group]) return 0;
	ladder_key(group, host, key, sizeof(key));
	if (!*key) return 0;
	rung = (ladder_rung(group, host) + 1) % sizes[group];
	if (!put(key, rung)) return ladder_rung(group, host);
	save();
	return rung;
}

int ladder_size(int group)
{
	return group >= 0 && group < LADDER_GROUPS ? sizes[group] : 0;
}

void ladder_destroy(void)
{
	ladder_site *s, *tmp;
	int g;
	HASH_ITER(hh, sites, s, tmp)
	{
		HASH_DEL(sites, s);
		free(s->key);
		free(s);
	}
	free(state);
	state = NULL;
	for (g = 0; g < LADDER_GROUPS; g++) sizes[g] = 0;
	speeds_free();
}

// the live choice (ladder.h): per site and rung, the speed (an average that follows the latest) and how
// many measurements it has
typedef struct speed_site {
	char *key;
	double bps[LADDER_MAX];
	unsigned n[LADDER_MAX];
	unsigned tried[LADDER_MAX];	// connections sent to measure it
	unsigned picks;
	UT_hash_handle hh;
} speed_site;

static speed_site *speeds;

static void speeds_free(void)
{
	speed_site *s, *tmp;
	HASH_ITER(hh, speeds, s, tmp)
	{
		HASH_DEL(speeds, s);
		free(s->key);
		free(s);
	}
}

static speed_site *speed_of(const char *key, bool add)
{
	speed_site *s;
	HASH_FIND_STR(speeds, key, s);
	if (s || !add) return s;
	if (!(s = calloc(1, sizeof(*s))) || !(s->key = strdup(key)))
	{
		free(s);
		return NULL;
	}
	HASH_ADD_KEYPTR(hh, speeds, s->key, strlen(s->key), s);
	return s;
}

// over all sites, per rung of the TCP ladder: measurements, of them failures, the sum of the speeds
static unsigned long stat_n[LADDER_MAX], stat_zero[LADDER_MAX];
static double stat_sum[LADDER_MAX];
static char *stats_file;
static struct timespec stats_t;

bool ladder_stats_init(const char *file)
{
	FILE *f;
	int r;
	unsigned long n, z;
	double avg;
	free(stats_file);
	stats_file = NULL;
	memset(stat_n, 0, sizeof(stat_n));
	memset(stat_zero, 0, sizeof(stat_zero));
	memset(stat_sum, 0, sizeof(stat_sum));
	if (!file || !*file) return true;
	if (!(stats_file = strdup(file))) return false;
	// "rung measurements failures average-kbps" a line; a rung the script replaced starts from nothing (it
	// empties its line)
	if ((f = fopen(stats_file, "r")))
	{
		char line[100];
		while (fgets(line, sizeof(line), f))
			if (sscanf(line, "%d %lu %lu %lf", &r, &n, &z, &avg) == 4 && r >= 0 && r < LADDER_MAX && z <= n)
			{
				stat_n[r] = n;
				stat_zero[r] = z;
				stat_sum[r] = avg * 1024 * (double)(n - z);
			}
		fclose(f);
	}
	stamp(stats_file, &stats_t);
	return true;
}

static void stats_save(void)
{
	FILE *f;
	int r;
	if (!stats_file || !untouched(stats_file, &stats_t) || !(f = fopen(stats_file, "w"))) return;
	for (r = 0; r < sizes[LADDER_TCP]; r++)
		fprintf(f, "%d %lu %lu %.0f\n", r, stat_n[r], stat_zero[r], stat_n[r] > stat_zero[r] ? stat_sum[r] / (stat_n[r] - stat_zero[r]) / 1024 : 0);
	fclose(f);
	stamp(stats_file, &stats_t);
}

int ladder_sample(const char *host, int rung, unsigned long bytes, unsigned long ms)
{
	char key[270];
	speed_site *s;
	double v;
	int cur;
	if (!sizes[LADDER_TCP] || rung < 0 || rung >= sizes[LADDER_TCP]) return -1;
	ladder_key(LADDER_TCP, host, key, sizeof(key));
	if (!*key || !(s = speed_of(key, true))) return -1;
	// too short to tell (a cached answer, one packet)
	if (bytes && ms < 200) return -1;
	v = ms ? (double)bytes * 1000 / ms : 0;
	stat_n[rung]++;
	if (v > 0) stat_sum[rung] += v; else stat_zero[rung]++;
	s->bps[rung] = s->n[rung] ? s->bps[rung] * 0.7 + v * 0.3 : v;
	if (s->n[rung] < 1000) s->n[rung]++;
	cur = ladder_rung(LADDER_TCP, host);
	// a trick measured three times and clearly faster than the site's own, measured three times too
	if (rung != cur && s->n[rung] >= 3 && s->n[cur] >= 3 && s->bps[rung] > s->bps[cur] * 1.5)
	{
		if (!put(key, rung)) return -1;
		save();
		return rung;
	}
	return -1;
}

int ladder_pick(const char *host)
{
	char key[270];
	speed_site *s;
	int cur, r, i, best = -1;
	unsigned least = ~0u;
	cur = ladder_rung(LADDER_TCP, host);
	if (sizes[LADDER_TCP] < 2) return cur;
	ladder_key(LADDER_TCP, host, key, sizeof(key));
	// the site's own trick is measured first (a site with no measurement has no record: nothing grows for
	// hosts that never download much)
	if (!*key || !(s = speed_of(key, false)) || s->n[cur] < 3) return cur;
	// slow: one connection in eight measures another trick; fast enough: one in fifty, in case
	if (++s->picks % (s->bps[cur] < LADDER_FAST ? 8 : 50)) return cur;
	// the trick tried least among those not measured yet, after the site's own in the ladder's order;
	// all measured — the fastest other one, to keep its measurement fresh
	for (i = 1; i < sizes[LADDER_TCP]; i++)
	{
		r = (cur + i) % sizes[LADDER_TCP];
		if (s->n[r] < 3 && s->tried[r] < least) { least = s->tried[r]; best = r; }
	}
	if (best < 0)
		for (i = 1; i < sizes[LADDER_TCP]; i++)
		{
			r = (cur + i) % sizes[LADDER_TCP];
			if (best < 0 || s->bps[r] > s->bps[best]) best = r;
		}
	if (s->tried[best] < ~0u) s->tried[best]++;
	return best;
}

double ladder_speed(const char *host)
{
	char key[270];
	speed_site *s;
	ladder_key(LADDER_TCP, host, key, sizeof(key));
	s = *key ? speed_of(key, false) : NULL;
	return s ? s->bps[ladder_rung(LADDER_TCP, host)] : 0;
}

// the sites the ladder handles (ladder.h): "site connections last-seen rung kbps" a line
typedef struct seen_site {
	char *key;
	unsigned long count;
	time_t last;
	UT_hash_handle hh;
} seen_site;

static seen_site *seen;

static seen_site *find_seen(const char *key)
{
	seen_site *s;
	HASH_FIND_STR(seen, key, s);
	return s;
}
static char *seen_file;
static time_t seen_saved;
static struct timespec seen_t;

bool ladder_seen_init(const char *file)
{
	FILE *f;
	char line[300], key[270];
	unsigned long count;
	long long last;
	seen_site *s;
	free(seen_file);
	seen_file = NULL;
	if (!file || !*file) return true;
	if (!(seen_file = strdup(file))) return false;
	if ((f = fopen(seen_file, "r")))
	{
		while (fgets(line, sizeof(line), f))
			if (sscanf(line, "%269s %lu %lld", key, &count, &last) == 3 && !find_seen(key) &&
				(s = calloc(1, sizeof(*s))) && (s->key = strdup(key)))
			{
				s->count = count;
				s->last = (time_t)last;
				HASH_ADD_KEYPTR(hh, seen, s->key, strlen(s->key), s);
			}
		fclose(f);
	}
	seen_saved = time(NULL);
	stamp(seen_file, &seen_t);
	return true;
}

// rung and speed of a key as it is (a key of a group of video servers stays that group's)
static int rung_of_key(const char *key)
{
	ladder_site *l = find(key);
	return l ? l->rung : 0;
}

static double speed_of_key(const char *key)
{
	speed_site *v = speed_of(key, false);
	return v ? v->bps[rung_of_key(key)] : 0;
}

// the file anew; sites not seen for a week go, and at most 2000 stay (the least recent go first)
static void seen_save(void)
{
	FILE *f;
	seen_site *s, *t;
	time_t now = time(NULL);
	HASH_ITER(hh, seen, s, t)
		if (now - s->last > 7 * 86400)
		{
			HASH_DEL(seen, s);
			free(s->key);
			free(s);
		}
	while (HASH_COUNT(seen) > 2000)
	{
		seen_site *oldest = NULL;
		HASH_ITER(hh, seen, s, t) if (!oldest || s->last < oldest->last) oldest = s;
		HASH_DEL(seen, oldest);
		free(oldest->key);
		free(oldest);
	}
	if (!seen_file || !untouched(seen_file, &seen_t) || !(f = fopen(seen_file, "w"))) return;
	HASH_ITER(hh, seen, s, t)
		fprintf(f, "%s %lu %lld %d %.0f\n", s->key, s->count, (long long)s->last, rung_of_key(s->key), speed_of_key(s->key) / 1024);
	fclose(f);
	stamp(seen_file, &seen_t);
}

void ladder_seen(const char *host)
{
	seen_site *s;
	char key[270];
	time_t now;
	if (!seen_file || !host) return;
	ladder_key(LADDER_TCP, host, key, sizeof(key));
	if (!*key) return;
	now = time(NULL);
	if (!(s = find_seen(key)))
	{
		if (!(s = calloc(1, sizeof(*s))) || !(s->key = strdup(key)))
		{
			free(s);
			return;
		}
		HASH_ADD_KEYPTR(hh, seen, s->key, strlen(s->key), s);
	}
	s->count++;
	s->last = now;
	if (now - seen_saved < 60) return;
	seen_saved = now;
	stats_save();
	seen_save();
}

void ladder_flush(void)
{
	stats_save();
	seen_save();
}
