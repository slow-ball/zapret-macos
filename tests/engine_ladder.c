// The ladder of the engine (engine/nfq/ladder.c): keys of sites, climbing, the file that keeps the rungs.
//   xcrun clang -I engine/nfq -o lt tests/engine_ladder.c engine/nfq/ladder.c && ./lt

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ladder.h"

static int passed, failed;

static void check(const char *what, int ok)
{
	if (ok) passed++;
	else { failed++; printf("FAIL: %s\n", what); }
}

static int key_is(const char *host, const char *want)
{
	char k[270];
	ladder_key(LADDER_TCP, host, k, sizeof(k));
	return !strcmp(k, want);
}

static int key_in(int group, const char *host, const char *want)
{
	char k[270];
	ladder_key(group, host, k, sizeof(k));
	return !strcmp(k, want);
}

int main(void)
{
	char state[] = "/tmp/ladder-test-XXXXXX";
	int fd = mkstemp(state);
	FILE *f;
	char line[100];

	check("ключ: сервер видео YouTube — его группа", key_is("rr3---sn-4g5e6nsz.googlevideo.com", "sn-4g5e6nsz.googlevideo.com"));
	check("ключ: другой сервер той же группы", key_is("rr12---sn-4g5e6nsz.googlevideo.com", "sn-4g5e6nsz.googlevideo.com"));
	check("ключ: googlevideo без группы", key_is("redirector.googlevideo.com", "googlevideo.com"));
	check("ключ: QUIC группы видео", key_in(LADDER_QUIC, "rr1---sn-ab.googlevideo.com", "quic:sn-ab.googlevideo.com"));
	check("ключ: сайт как есть", key_is("youtube.com", "youtube.com"));
	check("ключ: одно слово", key_is("localhost", "localhost"));
	check("ключ: адрес IPv4", key_is("203.0.113.7", "203.0.113.7"));
	check("ключ: адрес IPv6", key_is("2001:db8::1", "2001:db8::1"));
	check("ключ: зона co.uk", key_is("www.bbc.co.uk", "bbc.co.uk"));
	check("ключ: зона com.tr", key_is("a.b.example.com.tr", "example.com.tr"));
	check("ключ: общий хостинг", key_is("user.github.io", "user.github.io"));
	check("ключ: CDN", key_is("d111.cloudfront.net", "d111.cloudfront.net"));
	check("ключ: сама зона", key_is("co.uk", "co.uk"));
	check("ключ: короткий домен не путается с зоной", key_is("www.vk.com", "vk.com"));
	check("ключ: короткий домен в зоне страны", key_is("m.ok.ru", "ok.ru"));

	int g, r;
	check("разбор: TCP", ladder_parse("7", &g, &r) && g == LADDER_TCP && r == 7);
	check("разбор: QUIC", ladder_parse("quic:3", &g, &r) && g == LADDER_QUIC && r == 3);
	check("разбор: голос", ladder_parse("voice:0", &g, &r) && g == LADDER_VOICE && r == 0);
	check("разбор: мусор", !ladder_parse("x", &g, &r) && !ladder_parse("quic:", &g, &r) && !ladder_parse("40", &g, &r) && !ladder_parse("3x", &g, &r));
	check("ключ QUIC", key_in(LADDER_QUIC, "rr1.googlevideo.com", "quic:googlevideo.com"));
	check("ключ голоса один на всех", key_in(LADDER_VOICE, "1.2.3.4", "voice") && key_in(LADDER_VOICE, NULL, "voice"));

	int three[LADDER_GROUPS] = { 3, 2, 2 }, none[LADDER_GROUPS] = { 0, 0, 0 };
	check("без лестницы — ступень 0", ladder_rung(LADDER_TCP, "youtube.com") == 0 && ladder_size(LADDER_TCP) == 0);
	check("лестницы 3, 2, 2", ladder_init(state, three) && ladder_size(LADDER_TCP) == 3 && ladder_size(LADDER_QUIC) == 2);
	check("новый сайт — внизу", ladder_rung(LADDER_TCP, "youtube.com") == 0);
	check("без имени — внизу", ladder_rung(LADDER_TCP, NULL) == 0);
	check("подъём на 1", ladder_climb(LADDER_TCP, "www.youtube.com") == 1);
	check("ступень общая для хостов сайта", ladder_rung(LADDER_TCP, "m.youtube.com") == 1);
	ladder_climb(LADDER_TCP, "googlevideo.com");
	check("новая группа видео — с приёма googlevideo.com", ladder_rung(LADDER_TCP, "rr1---sn-new.googlevideo.com") == 1);
	ladder_climb(LADDER_TCP, "rr1---sn-new.googlevideo.com");
	check("группа видео учится сама", ladder_rung(LADDER_TCP, "rr5---sn-new.googlevideo.com") == 2 && ladder_rung(LADDER_TCP, "rr1---sn-other.googlevideo.com") == 1);
	check("другой сайт не задет", ladder_rung(LADDER_TCP, "discord.com") == 0);
	check("QUIC того же сайта не задет", ladder_rung(LADDER_QUIC, "youtube.com") == 0);
	check("QUIC: подъём", ladder_climb(LADDER_QUIC, "rr1.youtube.com") == 1 && ladder_rung(LADDER_QUIC, "youtube.com") == 1);
	check("QUIC: выше вершины — вниз", ladder_climb(LADDER_QUIC, "youtube.com") == 0);
	check("голос: подъём для всех серверов", ladder_climb(LADDER_VOICE, "5.6.7.8") == 1 && ladder_rung(LADDER_VOICE, "9.9.9.9") == 1);
	check("подъём на 2", ladder_climb(LADDER_TCP, "youtube.com") == 2);
	check("выше вершины — снова вниз", ladder_climb(LADDER_TCP, "youtube.com") == 0);
	ladder_climb(LADDER_TCP, "discord.com");
	ladder_climb(LADDER_TCP, "discord.com");

	// the file: sites above the bottom only
	f = fopen(state, "r");
	int lines = 0, has = 0;
	while (f && fgets(line, sizeof(line), f)) { lines++; if (!strcmp(line, "discord.com 2\n")) has = 1; }
	if (f) fclose(f);
	check("в файле только сайты не внизу", lines == 4 && has);

	ladder_destroy();
	check("после перезапуска ступени на месте", ladder_init(state, three) && ladder_rung(LADDER_TCP, "cdn.discord.com") == 2 && ladder_rung(LADDER_VOICE, NULL) == 1);
	ladder_destroy();
	int two[LADDER_GROUPS] = { 2, 2, 2 };
	check("лестница короче — сайт внизу", ladder_init(state, two) && ladder_rung(LADDER_TCP, "discord.com") == 0);
	ladder_destroy();
	int big[LADDER_GROUPS] = { LADDER_MAX + 1, 0, 0 };
	check("неверный размер не принимается", !ladder_init(state, none) && !ladder_init(state, big));
	check("без файла — тоже работает", ladder_init(NULL, two) && ladder_climb(LADDER_TCP, "a.b") == 1 && ladder_rung(LADDER_TCP, "a.b") == 1);
	ladder_destroy();

	// the live choice
	int four[LADDER_GROUPS] = { 4, 0, 0 }, i, picks[4] = { 0 }, moved = -1;
	check("живой выбор: лестница", ladder_init(NULL, four));
	check("живой выбор: сначала свой приём", ladder_pick("v.example.com") == 0);
	for (i = 0; i < 3; i++) ladder_sample("v.example.com", 0, 1024 * 1024, 1000); // 1 MB/s: slow
	for (i = 0; i < 80; i++) picks[ladder_pick("v.example.com")]++;
	check("живой выбор: медленный сайт пробует другие (каждое 8-е)", picks[0] == 70 && picks[1] + picks[2] + picks[3] == 10);
	check("живой выбор: сначала неизмеренные", picks[1] > 0 && picks[2] > 0);
	check("живой выбор: короткий замер не в счёт", ladder_sample("v.example.com", 2, 1000, 50) == -1);
	for (i = 0; i < 3 && moved < 0; i++) moved = ladder_sample("v.example.com", 2, 8 * 1024 * 1024, 1000); // 8 MB/s
	check("живой выбор: заметно быстрее — переход", moved == 2 && ladder_rung(LADDER_TCP, "v.example.com") == 2);
	check("живой выбор: скорость своего приёма", ladder_speed("x.v.example.com") > 7.0 * 1024 * 1024);
	for (i = 0; i < 3; i++) check("живой выбор: чуть быстрее — не переход", ladder_sample("v.example.com", 3, 9 * 1024 * 1024, 1000) == -1);
	for (i = 0; i < 100; i++) picks[ladder_pick("v.example.com")]++;
	check("живой выбор: быстрый сайт пробует редко", ladder_pick("v.example.com") >= 0);
	ladder_sample("v.example.com", 1, 0, 1000);
	check("живой выбор: сбой — замер ноль", ladder_sample("v.example.com", 1, 0, 1000) == -1);
	ladder_destroy();

	{
		// voice has no host: its rung before any climb, with no line in the file
		int nv[LADDER_GROUPS] = { 4, 2, 3 };
		ladder_init(NULL, nv);
		check("голос без имени: нижняя ступень", ladder_rung(LADDER_VOICE, NULL) == 0);
		check("голос без имени: подъём", ladder_climb(LADDER_VOICE, NULL) == 1 && ladder_rung(LADDER_VOICE, NULL) == 1);
		check("QUIC без имени: ничего", ladder_rung(LADDER_QUIC, NULL) == 0 && ladder_pick(NULL) == 0);
		ladder_destroy();
	}

	{
		// the script's edit of a file wins over what the engine has in memory
		char stats[] = "/tmp/ladder-stats-XXXXXX", line[100] = "";
		int sfd = mkstemp(stats), n4[LADDER_GROUPS] = { 4, 0, 0 };
		FILE *f;
		ladder_init(NULL, n4);
		ladder_stats_init(stats);
		for (i = 0; i < 3; i++) ladder_sample("s.example.com", 1, 1024 * 1024, 1000);
		ladder_flush();
		f = fopen(stats, "r");
		while (f && fgets(line, sizeof(line), f) && strncmp(line, "1 ", 2)) {}
		if (f) fclose(f);
		check("статистика: движок пишет свои замеры", !strncmp(line, "1 3 0 ", 6));
		f = fopen(stats, "w");
		if (f) fputs("1 0 0 0\n", f), fclose(f);
		ladder_sample("s.example.com", 1, 1024 * 1024, 1000);
		ladder_flush();
		f = fopen(stats, "r");
		line[0] = 0;
		if (f) fgets(line, sizeof(line), f), fclose(f);
		check("статистика: правку скрипта движок не затирает", !strcmp(line, "1 0 0 0\n"));
		ladder_stats_init(NULL);
		ladder_destroy();
		close(sfd);
		unlink(stats);
	}

	close(fd);
	unlink(state);
	printf("ladder: %d прошло, %d не прошло\n", passed, failed);
	return failed != 0;
}
