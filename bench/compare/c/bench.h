// Shared measurement for the C and C++ harnesses. Every harness in bench/compare follows the same
// rule (see run.sh):
//   warm up for at least 1 s (at least one run), then time single runs until at least `min_samples`
//   were taken and at least 60% of them lie within ±10% of their median ("converged"), or 10 s of
//   measuring or 1000 samples have passed. The median sample is reported.
// Also the key-lookup driver used by lookup.sh.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define BENCH_WARMUP_NS 1e9
#define BENCH_MAX_NS 10e9
#define BENCH_MAX_SAMPLES 1000
#define BENCH_WINDOW 0.10
#define BENCH_MAJORITY 0.6

static double bench_now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e9 + ts.tv_nsec;
}

static int bench_cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

typedef struct
{
	double median_ns;
	int samples;
	bool converged;
} measurement_t;

typedef void (*bench_op)(void *ctx);

static measurement_t measure(bench_op op, void *ctx, int min_samples)
{
	double warm = bench_now_ns();
	do
		op(ctx);
	while (bench_now_ns() - warm < BENCH_WARMUP_NS);

	static double samples[BENCH_MAX_SAMPLES], sorted[BENCH_MAX_SAMPLES];
	measurement_t m = {0};
	double start = bench_now_ns();
	int n = 0;
	while (n < BENCH_MAX_SAMPLES)
	{
		double t0 = bench_now_ns();
		op(ctx);
		samples[n++] = bench_now_ns() - t0;
		memcpy(sorted, samples, sizeof(double) * n);
		qsort(sorted, n, sizeof(double), bench_cmp);
		double median = (n % 2) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
		m.median_ns = median;
		m.samples = n;
		if (n >= min_samples)
		{
			int within = 0;
			for (int i = 0; i < n; i++)
				within += samples[i] >= median * (1 - BENCH_WINDOW) && samples[i] <= median * (1 + BENCH_WINDOW);
			if (within >= BENCH_MAJORITY * n)
			{
				m.converged = true;
				break;
			}
		}
		if (bench_now_ns() - start >= BENCH_MAX_NS)
			break;
	}
	return m;
}

// Parse-mode result line: "<ms> ms/op <MB/s> MB/s (n=<samples>, converged|capped)"
static void print_parse(measurement_t m, long bytes)
{
	double ms = m.median_ns / 1e6;
	printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, bytes / 1048576.0 / (ms / 1000.0), m.samples,
		m.converged ? "converged" : "capped");
}

// ---- Key lookups (lookup.sh) ----

typedef struct
{
	int count;
	char **tables;
	char **keys;
	char *text;
} lookups_t;

// Reads `table key` lines; the returned strings point into one NUL-separated buffer
static lookups_t read_lookups(const char *path)
{
	lookups_t l = {0};
	FILE *fp = fopen(path, "rb");
	if (!fp) { perror(path); exit(2); }
	fseek(fp, 0, SEEK_END);
	long len = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	l.text = (char *)malloc(len + 1);
	if (fread(l.text, 1, len, fp) != (size_t)len) { perror("read"); exit(2); }
	l.text[len] = 0;
	fclose(fp);
	int lines = 0;
	for (long i = 0; i < len; i++)
		lines += l.text[i] == '\n';
	l.tables = (char **)malloc(sizeof(char *) * lines);
	l.keys = (char **)malloc(sizeof(char *) * lines);
	char *p = l.text;
	while (*p)
	{
		char *space = strchr(p, ' ');
		char *end = strchr(p, '\n');
		*space = 0;
		*end = 0;
		l.tables[l.count] = p;
		l.keys[l.count] = space + 1;
		l.count++;
		p = end + 1;
	}
	return l;
}

// lookup returns true and sets *value if root[table][key] is an integer
typedef bool (*lookup_fn)(void *ctx, const char *table, const char *key, int64_t *value);

typedef struct
{
	const lookups_t *lookups;
	lookup_fn lookup;
	void *ctx;
	int64_t sum;
	int missing;
} lookup_pass_t;

// One sample: a pass over all lookups
static void lookup_pass(void *arg)
{
	lookup_pass_t *p = (lookup_pass_t *)arg;
	p->sum = 0;
	p->missing = 0;
	for (int i = 0; i < p->lookups->count; i++)
	{
		int64_t v;
		if (p->lookup(p->ctx, p->lookups->tables[i], p->lookups->keys[i], &v))
			p->sum += v;
		else
			p->missing++;
	}
}

// Prints "<ns> ns/lookup, <n> lookups, sum <sum>, missing <m> (n=<samples>, converged|capped)"
static void run_lookups(const lookups_t *l, int min_samples, lookup_fn lookup, void *ctx)
{
	lookup_pass_t pass = {l, lookup, ctx, 0, 0};
	measurement_t m = measure(lookup_pass, &pass, min_samples);
	printf("%.1f ns/lookup, %d lookups, sum %lld, missing %d (n=%d, %s)\n", m.median_ns / l->count, l->count,
		(long long)pass.sum, pass.missing, m.samples, m.converged ? "converged" : "capped");
}
