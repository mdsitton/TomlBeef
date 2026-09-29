// tomlc17 benchmark: bench <file> <min-samples> [lookups]
// Parse mode times single parses (parse + free) under the shared rule in bench.h. With a lookups
// file, parses once and times key lookups instead (lookup.sh).
#include <stdio.h>
#include <stdlib.h>
#include "tomlc17.h"
#include "bench.h"

typedef struct
{
	const char *buf;
	int len;
} parse_ctx;

static void parse_once(void *arg)
{
	parse_ctx *p = (parse_ctx *)arg;
	toml_free(toml_parse(p->buf, p->len));
}

static bool lookup(void *ctx, const char *table, const char *key, int64_t *value)
{
	toml_datum_t t = toml_get(*(toml_datum_t *)ctx, table);
	if (t.type != TOML_TABLE)
		return false;
	toml_datum_t v = toml_get(t, key);
	if (v.type != TOML_INT64)
		return false;
	*value = v.u.int64;
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

	toml_result_t first = toml_parse(buf, (int)len);
	if (!first.ok) { fprintf(stderr, "parse error: %s\n", first.errmsg); return 1; }
	if (argc >= 4)
	{
		lookups_t l = read_lookups(argv[3]);
		run_lookups(&l, min_samples, lookup, &first.toptab);
		return 0;
	}
	toml_free(first);

	parse_ctx ctx = {buf, (int)len};
	print_parse(measure(parse_once, &ctx, min_samples), len);
	free(buf);
	return 0;
}
