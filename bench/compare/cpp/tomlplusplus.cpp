// toml++ benchmark: bench <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses into
// toml::table within a 3 s budget.
// Built with exceptions disabled, so toml::parse returns a toml::parse_result.
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <toml++/toml.hpp>

int main(int argc, char** argv)
{
	if (argc < 3) { std::fprintf(stderr, "usage: bench <file> <iterations>\n"); return 2; }
	std::ifstream in(argv[1], std::ios::binary);
	std::stringstream ss;
	ss << in.rdbuf();
	const std::string text = ss.str();
	const int iterations = std::atoi(argv[2]);

	auto warm = toml::parse(text);
	if (!warm)
	{
		std::fprintf(stderr, "parse error: %.*s\n", (int)warm.error().description().size(), warm.error().description().data());
		return 1;
	}

	// Stop after <iterations> parses or 3 s, whichever comes first (at least one)
	using clock = std::chrono::steady_clock;
	int done = 0;
	auto start = clock::now();
	while (done < iterations && (done == 0 || clock::now() - start < std::chrono::seconds(3)))
	{
		auto result = toml::parse(text);
		(void)result;
		done++;
	}
	double ms = std::chrono::duration<double, std::milli>(clock::now() - start).count() / done;
	std::printf("%.3f ms/op %.1f MB/s\n", ms, text.size() / 1048576.0 / (ms / 1000.0));
	return 0;
}
