// toml++ benchmark: bench <file> <min-samples> [lookups]
// Parse mode times single parses into toml::table under the shared rule in ../c/bench.h. Built with
// exceptions disabled, so toml::parse returns a toml::parse_result. With a lookups file, parses once
// and times key lookups instead (lookup.sh).
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <toml++/toml.hpp>
#include "../c/bench.h"

int main(int argc, char** argv)
{
	if (argc < 3) { std::fprintf(stderr, "usage: bench <file> <min-samples> [lookups]\n"); return 2; }
	std::ifstream in(argv[1], std::ios::binary);
	std::stringstream ss;
	ss << in.rdbuf();
	const std::string text = ss.str();
	const int min_samples = std::atoi(argv[2]);

	auto first = toml::parse(text);
	if (!first)
	{
		std::fprintf(stderr, "parse error: %.*s\n", (int)first.error().description().size(), first.error().description().data());
		return 1;
	}
	if (argc >= 4)
	{
		lookups_t l = read_lookups(argv[3]);
		run_lookups(&l, min_samples, [](void* ctx, const char* table, const char* key, int64_t* value) {
			const auto* t = static_cast<const toml::table*>(ctx)->get_as<toml::table>(table);
			if (!t)
				return false;
			const auto* v = t->get_as<int64_t>(key);
			if (!v)
				return false;
			*value = v->get();
			return true;
		}, &first.table());
		return 0;
	}

	print_parse(measure([](void* ctx) {
		auto result = toml::parse(*static_cast<const std::string*>(ctx));
		(void)result;
	}, (void*)&text, min_samples), (long)text.size());
	return 0;
}
