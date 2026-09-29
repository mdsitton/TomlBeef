// toml11 benchmark: bench <file> <min-samples> [lookups]
// Parse mode times single parses under the shared rule in ../c/bench.h. toml::parse_str takes the
// text by value, so each parse includes one copy of the input. With a lookups file, parses once
// and times key lookups instead (lookup.sh).
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <toml.hpp>
#include "../c/bench.h"

int main(int argc, char** argv)
{
	if (argc < 3) { std::fprintf(stderr, "usage: bench <file> <min-samples> [lookups]\n"); return 2; }
	std::ifstream in(argv[1], std::ios::binary);
	std::stringstream ss;
	ss << in.rdbuf();
	const std::string text = ss.str();
	const int min_samples = std::atoi(argv[2]);

	auto first = toml::try_parse_str(text);
	if (first.is_err()) { std::fprintf(stderr, "parse error\n"); return 1; }
	if (argc >= 4)
	{
		lookups_t l = read_lookups(argv[3]);
		run_lookups(&l, min_samples, [](void* ctx, const char* table, const char* key, int64_t* value) {
			const auto& root = static_cast<const toml::value*>(ctx)->as_table();
			auto t = root.find(table);
			if (t == root.end() || !t->second.is_table())
				return false;
			auto v = t->second.as_table().find(key);
			if (v == t->second.as_table().end() || !v->second.is_integer())
				return false;
			*value = v->second.as_integer();
			return true;
		}, &first.unwrap());
		return 0;
	}

	print_parse(measure([](void* ctx) {
		auto v = toml::parse_str(*static_cast<const std::string*>(ctx));
		(void)v;
	}, (void*)&text, min_samples), (long)text.size());
	return 0;
}
