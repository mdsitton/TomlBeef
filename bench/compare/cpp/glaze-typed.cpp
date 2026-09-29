// glaze typed serialization of typed.toml (../typed.sh): glaze-typed <read|write> <file> <min-samples>
// glaze maps aggregates to TOML through compile-time reflection (no annotations): glz::read_toml
// into a new TypedRoot (MB/s of input), glz::write_toml of the model read once (MB/s of output).
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include "glaze/toml.hpp"
#include "../c/bench.h"

struct TypedLimits
{
	int32_t max_connections{};
	int32_t timeout_ms{};
};

struct TypedServer
{
	std::string name;
	std::string host;
	int32_t port{};
	bool enabled{};
	double weight{};
	std::vector<std::string> tags;
	TypedLimits limits;
};

struct TypedRoot
{
	std::string title;
	int32_t version{};
	bool debug{};
	std::vector<TypedServer> servers;
};

// "servers ports max_connections tags enabled", the same line every typed harness prints
static void print_check(const char* prefix, const TypedRoot& root)
{
	long long ports = 0, connections = 0, tags = 0, enabled = 0;
	for (const auto& s : root.servers)
	{
		ports += s.port;
		connections += s.limits.max_connections;
		tags += (long long)s.tags.size();
		enabled += s.enabled ? 1 : 0;
	}
	std::printf("%scheck: %zu %lld %lld %lld %lld\n", prefix, root.servers.size(), ports, connections, tags, enabled);
}

static bool read_model(TypedRoot& root, const std::string& text)
{
	if (auto ec = glz::read_toml(root, text))
	{
		std::fprintf(stderr, "read error: %s\n", glz::format_error(ec, text).c_str());
		return false;
	}
	return true;
}

struct Ctx
{
	const std::string* text;
	const TypedRoot* model;
	std::string output;
};

int main(int argc, char** argv)
{
	if (argc < 4) { std::fprintf(stderr, "usage: glaze-typed <read|write> <file> <min-samples>\n"); return 2; }
	const std::string mode = argv[1];
	std::ifstream in(argv[2], std::ios::binary);
	std::stringstream ss;
	ss << in.rdbuf();
	const std::string text = ss.str();
	const int min_samples = std::atoi(argv[3]);

	TypedRoot model;
	if (!read_model(model, text))
		return 1;
	print_check("", model);

	Ctx ctx{&text, &model, {}};
	if (mode == "read")
	{
		print_parse(measure([](void* p) {
			TypedRoot root;
			auto ec = glz::read_toml(root, *static_cast<Ctx*>(p)->text);
			(void)ec;
		}, &ctx, min_samples), (long)text.size());
		return 0;
	}
	measurement_t m = measure([](void* p) {
		auto* c = static_cast<Ctx*>(p);
		c->output.clear();
		auto ec = glz::write_toml(*c->model, c->output);
		(void)ec;
	}, &ctx, min_samples);
	TypedRoot back;
	if (!read_model(back, ctx.output))
		return 1;
	print_check("re-read ", back);
	print_parse(m, (long)ctx.output.size());
	return 0;
}
