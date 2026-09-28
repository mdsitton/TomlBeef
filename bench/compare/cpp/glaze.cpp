// glaze benchmark: bench <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses (3 s budget)
// into glz::generic_i64's object type, glaze's schema-less table (integers kept exact). glaze is built
// around reading into known C++ types; its generic value is JSON-shaped, so date/time values are
// not kept as dates.
//
// The document is read as the object type rather than as glz::generic_i64 itself: reading into
// the generic value picks its type from the first byte, so a document starting with a [table]
// header is taken for an array and fails (glaze v9.0.0).
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include "glaze/json/generic.hpp"
#include "glaze/toml.hpp"

using Table = glz::generic_i64::object_t;

int main(int argc, char** argv)
{
	if (argc < 3) { std::fprintf(stderr, "usage: bench <file> <iterations>\n"); return 2; }
	std::ifstream in(argv[1], std::ios::binary);
	std::stringstream ss;
	ss << in.rdbuf();
	const std::string text = ss.str();
	const int iterations = std::atoi(argv[2]);

	{
		Table warm;
		if (auto ec = glz::read_toml(warm, text))
		{
			std::fprintf(stderr, "parse error: %s\n", glz::format_error(ec, text).c_str());
			return 1;
		}
	}

	// Stop after <iterations> parses or 3 s, whichever comes first (at least one)
	using clock = std::chrono::steady_clock;
	int done = 0;
	auto start = clock::now();
	while (done < iterations && (done == 0 || clock::now() - start < std::chrono::seconds(3)))
	{
		Table value;
		auto ec = glz::read_toml(value, text);
		(void)ec;
		done++;
	}
	double ms = std::chrono::duration<double, std::milli>(clock::now() - start).count() / done;
	std::printf("%.3f ms/op %.1f MB/s\n", ms, text.size() / 1048576.0 / (ms / 1000.0));
	return 0;
}
