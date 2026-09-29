// toml-c benchmark: bench <file> <min-samples> [lookups]
// Parse mode times single parses (parse + free) under the shared rule in bench.h. With a lookups
// file, parses once and times key lookups instead (lookup.sh).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "toml.h"
#include "bench.h"

typedef struct
{
	char *buf;
	char errbuf[256];
} parse_ctx;

static void parse_once(void *arg)
{
	parse_ctx *p = (parse_ctx *)arg;
	toml_free(toml_parse(p->buf, p->errbuf, sizeof p->errbuf));
}

static bool lookup(void *ctx, const char *table, const char *key, int64_t *value)
{
	toml_table_t *t = toml_table_table((toml_table_t *)ctx, table);
	if (!t)
		return false;
	toml_value_t v = toml_table_int(t, key);
	if (!v.ok)
		return false;
	*value = v.u.i;
	return true;
}

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: bench <file> <min-samples> [lookups]\n"); return 2; }
	FILE *fp = fopen(argv[1], "rb");
	if (!fp) { perror(argv[1]); return 2; }
	fseek(fp, 0, SEEK_END);
	long len = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	char *buf = malloc(len + 1);
	if (fread(buf, 1, len, fp) != (size_t)len) { perror("read"); return 2; }
	buf[len] = 0;
	fclose(fp);
	int min_samples = atoi(argv[2]);

	// toml_parse takes a non-const buffer: make sure it leaves the input intact, so every timed
	// parse sees the same text
	char *copy = malloc(len + 1);
	memcpy(copy, buf, len + 1);
	char errbuf[256];
	toml_table_t *first = toml_parse(buf, errbuf, sizeof errbuf);
	if (!first) { fprintf(stderr, "parse error: %s\n", errbuf); return 1; }
	if (memcmp(copy, buf, len + 1) != 0) { fprintf(stderr, "toml_parse modified its input\n"); return 1; }
	free(copy);
	if (argc >= 4)
	{
		lookups_t l = read_lookups(argv[3]);
		run_lookups(&l, min_samples, lookup, first);
		return 0;
	}
	toml_free(first);

	parse_ctx ctx = {buf, {0}};
	print_parse(measure(parse_once, &ctx, min_samples), len);
	free(buf);
	return 0;
}
