using System;
using System.Collections;
using TomlBeef;

namespace Fixtures;

// Each fixture is built alone by test-codegen.sh, with -define=FIXTURE_<name>. A line
// `// FIXTURE <name>: <text>` gives the text the build error must contain, or OK for a mapping that must
// build (a positive control: the checks must not reject it).

class Program
{
	public static int Main()
	{
		return 0;
	}
}

struct Temperature
{
	public double mCelsius;
}

// FIXTURE OkBaseline: OK
#if FIXTURE_OkBaseline
[TomlObject(Naming = .SnakeCase)]
class Item
{
	public String Title ~ delete _;
	public int32 Count;
	public uint64 Big;
	public List<int32> Counts ~ delete _;
	public Dictionary<String, int32> Totals ~ DeleteDictionaryAndKeys!(_);
}
#endif

// FIXTURE OkRegisteredConverter: OK
#if FIXTURE_OkRegisteredConverter
// A converter registered in this project, with a second project (Other) depending on TomlBeef too: the
// old generator looked registrations up from ApplyToType, where the user's declarations are only visible
// while their project is TomlBeef's only dependent, and stopped with "does not support fields of type"
[TomlConverter(typeof(Temperature))]
struct TemperatureToml : ITomlConverter<Temperature>
{
	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref Temperature target)
	{
		if (!value.TryGetFloat(let celsius))
			return .Err(context.MakeError("expected a float"));
		target.mCelsius = celsius;
		return .Ok;
	}

	public static Result<void, TomlParseError> Write(Temperature value, TomlConvertContext context)
	{
		context.Set(value.mCelsius);
		return .Ok;
	}
}

[TomlObject]
class Station
{
	public Temperature Outside;
	public List<Temperature> Readings ~ delete _;
}
#endif

// FIXTURE OkSelfReference: OK
#if FIXTURE_OkSelfReference
[TomlObject]
class Node
{
	public String Name ~ delete _;
	public List<Node> Children ~ DeleteContainerAndItems!(_);
}
#endif

// FIXTURE OkGeneric: OK
#if FIXTURE_OkGeneric
[TomlObject]
class Holder<T>
{
	public T Value;
}

static class UseHolder
{
	public static void Use()
	{
		let holder = scope Holder<int32>();
		let table = scope TomlDocument();
		holder.TomlWrite(table.RootTable).IgnoreError();
	}
}
#endif

// FIXTURE OkInheritance: OK
#if FIXTURE_OkInheritance
[TomlObject]
class Base
{
	public int32 Id;
}

[TomlObject]
class Derived : Base
{
	public String Label ~ delete _;
}
#endif

// FIXTURE Unsupported: TOML serialization does not support fields of type char8
#if FIXTURE_Unsupported
[TomlObject]
class Bad
{
	public char8 c;
}
#endif

// FIXTURE ListOfLists: TOML serialization does not support fields of type System.Collections.List<System.Collections.List<int32>>
#if FIXTURE_ListOfLists
[TomlObject]
class Bad
{
	public List<List<int32>> grid;
}
#endif

// FIXTURE IntegerKeys: TOML serialization does not support fields of type System.Collections.Dictionary<int32, int32>
#if FIXTURE_IntegerKeys
[TomlObject]
class Bad
{
	public Dictionary<int32, int32> map;
}
#endif

// FIXTURE ControlCharacterInName: contains a control character
#if FIXTURE_ControlCharacterInName
[TomlObject]
class Bad
{
	[TomlName("a\tb")] public int32 x;
}
#endif

// FIXTURE TwoConverters: [TomlConverter] Both
#if FIXTURE_TwoConverters
[TomlConverter(typeof(Temperature))]
struct FirstToml : ITomlConverter<Temperature>
{
	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref Temperature target) => .Ok;
	public static Result<void, TomlParseError> Write(Temperature value, TomlConvertContext context) => .Ok;
}

[TomlConverter(typeof(Temperature))]
struct SecondToml : ITomlConverter<Temperature>
{
	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref Temperature target) => .Ok;
	public static Result<void, TomlParseError> Write(Temperature value, TomlConvertContext context) => .Ok;
}

[TomlObject]
class Station
{
	public Temperature Outside;
}
#endif
