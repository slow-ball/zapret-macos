#pragma once

// The ladder (zapret-macos): one strategy that finds its own way for every site.
//
// Profiles marked --ladder=K are its rungs, each with its own trick. A site starts on rung 0; when the
// provider still breaks it there, it climbs to the next rung, and the rung that works stays its own. Rungs
// of sites live in the file of --ladder-state, read at start and written on every climb, so they survive
// restarts. A site above the last rung starts over from the bottom: the provider may have changed.
//
// Three ladders, each with tricks of its own kind: TCP (--ladder=K: HTTPS and HTTP, a failure is a reset,
// a block page or silence), QUIC (--ladder=quic:K: a handshake that never completes) and Discord voice
// (--ladder=voice:K: an address discovery nobody answers; one rung for all voice servers).

#include <stdbool.h>
#include <stddef.h>

#define LADDER_MAX 32

enum { LADDER_TCP, LADDER_QUIC, LADDER_VOICE, LADDER_GROUPS };

// "7", "quic:3", "voice:1" into a ladder and a rung; false for anything else
bool ladder_parse(const char *s, int *group, int *rung);
// the key of a site in a ladder: TCP — its last two labels (rr3---sn-x.googlevideo.com → googlevideo.com,
// YouTube serves from thousands of hosts and they share one rung; one label more under co.uk-type zones
// and shared hosting), QUIC — the same with "quic:" before it, voice — "voice" for every server
void ladder_key(int group, const char *host, char *out, size_t size);
// loads the rungs of sites from the file, if there is one. sizes: how many rungs each ladder has (0: none)
bool ladder_init(const char *state_file, const int sizes[LADDER_GROUPS]);
// the rung of a site, 0 for a site the ladder hasn't met yet
int ladder_rung(int group, const char *host);
// the next rung for a site that failed on its own; saved at once. returns the new rung
int ladder_climb(int group, const char *host);
// how many rungs a ladder has: 0 while there is none
int ladder_size(int group);
void ladder_destroy(void);

// the live choice of the TCP ladder: the engine measures how fast each site really downloads on each trick
// (the client's acknowledgements: no test requests), tries another trick on a share of new connections while
// a site is slow, and moves the site to a trick that is clearly faster
#define LADDER_SAMPLE (512 * 1024)	// a measurement: this much received
#define LADDER_FAST (4.0 * 1024 * 1024)	// bytes/s: 4K plays at double speed; slower — look for better
// a measurement of a site on a rung: bytes received in ms of transfer (pauses left out). a failure on a rung
// the site doesn't stay on is a measurement of 0. returns the rung the site moved to, or -1
int ladder_sample(const char *host, int rung, unsigned long bytes, unsigned long ms);
// the rung for a new connection to a site: its own, now and then another one to measure
int ladder_pick(const char *host);
// bytes/s of a site on its own rung (0: not measured yet), for the journal
double ladder_speed(const char *host);

// how each rung of the TCP ladder does over all sites — measurements, failures (a measurement of 0), the average
// speed — kept in a file (--ladder-stats) with the sites seen: the watchdog replaces the rungs that do badly
// with new tricks made from the best (the generator)
bool ladder_stats_init(const char *file);

// the sites the TCP ladder handles, how many connections each, kept in a file (--ladder-seen) once a minute
// at most: the watchdog checks the ones used most whether they really open (a stall the engine can't see)
bool ladder_seen_init(const char *file);
void ladder_seen(const char *host);
// what the engine learned, to the files right away: before it stops
void ladder_flush(void);
