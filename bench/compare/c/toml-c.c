// toml-c benchmark: bench <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses (parse +
// free) within a 3 s budget.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "toml.h"

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: bench <file> <iterations>\n"); return 2; }
	FILE *fp = fopen(argv[1], "rb");
	if (!fp) { perror(argv[1]); return 2; }
	fseek(fp, 0, SEEK_END);
	long len = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	char *buf = malloc(len + 1);
	if (fread(buf, 1, len, fp) != (size_t)len) { perror("read"); return 2; }
	buf[len] = 0;
	fclose(fp);
	int iterations = atoi(argv[2]);

	// toml_parse takes a non-const buffer: make sure it leaves the input intact, so every timed
	// parse sees the same text
	char *copy = malloc(len + 1);
	memcpy(copy, buf, len + 1);
	char errbuf[256];
	toml_table_t *warm = toml_parse(buf, errbuf, sizeof errbuf);
	if (!warm) { fprintf(stderr, "parse error: %s\n", errbuf); return 1; }
	toml_free(warm);
	if (memcmp(copy, buf, len + 1) != 0) { fprintf(stderr, "toml_parse modified its input\n"); return 1; }
	free(copy);

	// Stop after <iterations> parses or 3 s, whichever comes first (at least one)
	int done = 0;
	double start = now_ms();
	while (done < iterations && (done == 0 || now_ms() - start < 3000))
	{
		toml_free(toml_parse(buf, errbuf, sizeof errbuf));
		done++;
	}
	double ms = (now_ms() - start) / done;
	printf("%.3f ms/op %.1f MB/s\n", ms, len / 1048576.0 / (ms / 1000.0));
	free(buf);
	return 0;
}
