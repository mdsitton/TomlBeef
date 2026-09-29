// glaze benchmark: bench <file> <min-samples> [lookups]
// Parse mode times single parses into glz::generic_i64's object type (glaze's schema-less table,
// integers kept exact) under the shared rule in ../c/bench.h. glaze is built around reading into
// known C++ types; its generic value is JSON-shaped, so date/time values are not kept as dates.
//
// The document is read as the object type rather than as glz::generic_i64 itself: reading into
// the generic value picks its type from the first byte, so a document starting with a [table]
// header is taken for an array and fails (glaze v9.0.0). With a lookups file, parses once and
// times key lookups instead (lookup.sh).
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include "glaze/json/generic.hpp"
#include "glaze/toml.hpp"
#include "../c/bench.h"

using Table = glz::generic_i64::object_t;

int main(int argc, char** argv)
{
	if (argc < 3) { std::fprintf(stderr, "usage: bench <file> <min-samples> [lookups]\n"); return 2; }
	std::ifstream in(argv[1], std::ios::binary);
	std::stringstream ss;
	ss << in.rdbuf();
	const std::string text = ss.str();
	const int min_samples = std::atoi(argv[2]);

	Table first;
	if (auto ec = glz::read_toml(first, text))
	{
		std::fprintf(stderr, "parse error: %s\n", glz::format_error(ec, text).c_str());
		return 1;
	}
	if (argc >= 4)
	{
		lookups_t l = read_lookups(argv[3]);
		run_lookups(&l, min_samples, [](void* ctx, const char* table, const char* key, int64_t* value) {
			auto& root = *static_cast<Table*>(ctx);
			auto t = root.find(table);
			if (t == root.end())
				return false;
			auto* inner = std::get_if<Table>(&t->second.data);
			if (!inner)
				return false;
			auto v = inner->find(key);
			if (v == inner->end())
				return false;
			auto* number = std::get_if<int64_t>(&v->second.data);
			if (!number)
				return false;
			*value = *number;
			return true;
		}, &first);
		return 0;
	}

	print_parse(measure([](void* ctx) {
		Table value;
		auto ec = glz::read_toml(value, *static_cast<const std::string*>(ctx));
		(void)ec;
	}, (void*)&text, min_samples), (long)text.size());
	return 0;
}
